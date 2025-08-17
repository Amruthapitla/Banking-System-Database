# Generate a complete MySQL SQL script for a Banking System Database and save it for download
sql = r"""
-- =====================================================================
-- Banking System Database - Complete SQL (MySQL 8.0+)
-- Author: ChatGPT
-- Target: MySQL 8.0+
-- =====================================================================

-- Safety first
SET FOREIGN_KEY_CHECKS = 0;

DROP DATABASE IF EXISTS banking_system;
CREATE DATABASE banking_system CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE banking_system;

-- =====================================================================
-- 1) Reference & Master Tables
-- =====================================================================

CREATE TABLE branches (
    branch_id      BIGINT PRIMARY KEY AUTO_INCREMENT,
    branch_code    VARCHAR(10) NOT NULL UNIQUE,
    branch_name    VARCHAR(100) NOT NULL,
    city           VARCHAR(80) NOT NULL,
    state          VARCHAR(80) NOT NULL,
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE customers (
    customer_id    BIGINT PRIMARY KEY AUTO_INCREMENT,
    first_name     VARCHAR(60) NOT NULL,
    last_name      VARCHAR(60) NOT NULL,
    email          VARCHAR(120) UNIQUE,
    phone          VARCHAR(20) UNIQUE,
    address_line1  VARCHAR(120),
    address_line2  VARCHAR(120),
    city           VARCHAR(80),
    state          VARCHAR(80),
    postal_code    VARCHAR(12),
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Account types reference (savings, current, salary, etc.)
CREATE TABLE account_types (
    account_type_id  SMALLINT PRIMARY KEY AUTO_INCREMENT,
    code             VARCHAR(20) NOT NULL UNIQUE,
    description      VARCHAR(120) NOT NULL
);

-- =====================================================================
-- 2) Accounts & Transactions
-- =====================================================================

CREATE TABLE accounts (
    account_id       BIGINT PRIMARY KEY AUTO_INCREMENT,
    account_no       VARCHAR(20) NOT NULL UNIQUE,
    customer_id      BIGINT NOT NULL,
    branch_id        BIGINT NOT NULL,
    account_type_id  SMALLINT NOT NULL,
    balance_cents    BIGINT NOT NULL DEFAULT 0, -- store money as integer (cents)
    status           ENUM('ACTIVE','FROZEN','CLOSED') NOT NULL DEFAULT 'ACTIVE',
    opened_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at        TIMESTAMP NULL,
    CONSTRAINT fk_acc_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT fk_acc_branch   FOREIGN KEY (branch_id) REFERENCES branches(branch_id),
    CONSTRAINT fk_acc_type     FOREIGN KEY (account_type_id) REFERENCES account_types(account_type_id),
    CONSTRAINT chk_balance_nonneg CHECK (balance_cents >= 0)
);

-- Transactions: immutable append-only ledger
CREATE TABLE account_transactions (
    txn_id           BIGINT PRIMARY KEY AUTO_INCREMENT,
    account_id       BIGINT NOT NULL,
    txn_time         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    txn_type         ENUM('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT','INTEREST','FEE') NOT NULL,
    amount_cents     BIGINT NOT NULL, -- always positive
    related_account  BIGINT NULL,     -- for transfers, other side account
    reference        VARCHAR(120) NULL,
    created_by       VARCHAR(60) DEFAULT 'SYSTEM',
    CONSTRAINT fk_txn_account FOREIGN KEY (account_id) REFERENCES accounts(account_id),
    CONSTRAINT chk_amount_positive CHECK (amount_cents > 0)
);

CREATE INDEX idx_txn_account_time ON account_transactions(account_id, txn_time);

-- Audit log (captures DML events)
CREATE TABLE audit_log (
    audit_id     BIGINT PRIMARY KEY AUTO_INCREMENT,
    event_time   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    actor        VARCHAR(60) NOT NULL,
    action       VARCHAR(40) NOT NULL,
    entity       VARCHAR(40) NOT NULL,
    entity_id    VARCHAR(60) NOT NULL,
    details      JSON NULL
);

-- =====================================================================
-- 3) Loans
-- =====================================================================

CREATE TABLE loan_products (
    product_id     BIGINT PRIMARY KEY AUTO_INCREMENT,
    code           VARCHAR(20) NOT NULL UNIQUE,
    name           VARCHAR(100) NOT NULL,
    annual_rate_bp INT NOT NULL,   -- basis points, e.g., 850 = 8.50%
    term_months    INT NOT NULL,
    description    VARCHAR(200)
);

CREATE TABLE loans (
    loan_id        BIGINT PRIMARY KEY AUTO_INCREMENT,
    customer_id    BIGINT NOT NULL,
    branch_id      BIGINT NOT NULL,
    product_id     BIGINT NOT NULL,
    principal_cents BIGINT NOT NULL CHECK (principal_cents > 0),
    disbursed_cents BIGINT NOT NULL DEFAULT 0,
    outstanding_cents BIGINT NOT NULL DEFAULT 0,
    status         ENUM('PENDING','ACTIVE','CLOSED','DEFAULTED') NOT NULL DEFAULT 'PENDING',
    opened_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at      TIMESTAMP NULL,
    CONSTRAINT fk_loan_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    CONSTRAINT fk_loan_branch   FOREIGN KEY (branch_id) REFERENCES branches(branch_id),
    CONSTRAINT fk_loan_product  FOREIGN KEY (product_id) REFERENCES loan_products(product_id)
);

CREATE TABLE loan_payments (
    payment_id     BIGINT PRIMARY KEY AUTO_INCREMENT,
    loan_id        BIGINT NOT NULL,
    payment_time   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    amount_cents   BIGINT NOT NULL CHECK (amount_cents > 0),
    method         ENUM('CASH','TRANSFER','CARD','UPI','CHEQUE') NOT NULL DEFAULT 'TRANSFER',
    reference      VARCHAR(120),
    CONSTRAINT fk_payment_loan FOREIGN KEY (loan_id) REFERENCES loans(loan_id)
);

-- =====================================================================
-- 4) Triggers
-- =====================================================================

DELIMITER $$

-- Prevent direct balance edits; enforce via procedures
CREATE TRIGGER trg_accounts_balance_no_direct_update
BEFORE UPDATE ON accounts
FOR EACH ROW
BEGIN
    IF NEW.balance_cents <> OLD.balance_cents THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Direct balance update not allowed';
    END IF;
END$$

-- Mirror txns to audit_log
CREATE TRIGGER trg_txn_audit AFTER INSERT ON account_transactions
FOR EACH ROW
BEGIN
    INSERT INTO audit_log(actor, action, entity, entity_id, details)
    VALUES (NEW.created_by, 'TXN', 'ACCOUNT', NEW.account_id,
            JSON_OBJECT('txn_id', NEW.txn_id, 'type', NEW.txn_type, 'amount_cents', NEW.amount_cents, 'related', NEW.related_account, 'ref', NEW.reference));
END$$

DELIMITER ;

-- =====================================================================
-- 5) Stored Procedures (Accounts)
-- =====================================================================

DELIMITER $$

-- Open an account with optional initial deposit (in rupees)
CREATE PROCEDURE sp_open_account(
    IN p_customer_id BIGINT,
    IN p_branch_id BIGINT,
    IN p_account_type_code VARCHAR(20),
    IN p_initial_deposit_rupees DECIMAL(18,2),
    IN p_actor VARCHAR(60)
)
BEGIN
    DECLARE v_account_type_id SMALLINT;
    DECLARE v_account_id BIGINT;
    DECLARE v_account_no VARCHAR(20);
    DECLARE v_init_cents BIGINT DEFAULT 0;

    SELECT account_type_id INTO v_account_type_id
    FROM account_types WHERE code = p_account_type_code;

    IF v_account_type_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid account type code';
    END IF;

    SET v_account_no = CONCAT('AC', LPAD(FLOOR(RAND()*99999999), 8, '0'));
    SET v_init_cents = ROUND(p_initial_deposit_rupees * 100);

    INSERT INTO accounts(account_no, customer_id, branch_id, account_type_id, balance_cents)
    VALUES (v_account_no, p_customer_id, p_branch_id, v_account_type_id, 0);

    SET v_account_id = LAST_INSERT_ID();

    INSERT INTO audit_log(actor, action, entity, entity_id, details)
    VALUES (p_actor, 'CREATE', 'ACCOUNT', v_account_id, JSON_OBJECT('account_no', v_account_no));

    IF v_init_cents > 0 THEN
        CALL sp_deposit(v_account_id, v_init_cents/100.0, 'Initial Deposit', p_actor);
    END IF;

    SELECT v_account_id AS account_id, v_account_no AS account_no;
END$$

-- Deposit amount in rupees
CREATE PROCEDURE sp_deposit(
    IN p_account_id BIGINT,
    IN p_amount_rupees DECIMAL(18,2),
    IN p_reference VARCHAR(120),
    IN p_actor VARCHAR(60)
)
BEGIN
    DECLARE v_amount_cents BIGINT;
    DECLARE v_status ENUM('ACTIVE','FROZEN','CLOSED');

    SELECT status INTO v_status FROM accounts WHERE account_id = p_account_id FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not active';
    END IF;

    SET v_amount_cents = ROUND(p_amount_rupees * 100);
    IF v_amount_cents <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deposit must be positive';
    END IF;

    START TRANSACTION;
        UPDATE accounts SET balance_cents = balance_cents + v_amount_cents
        WHERE account_id = p_account_id;

        INSERT INTO account_transactions(account_id, txn_type, amount_cents, reference, created_by)
        VALUES (p_account_id, 'DEPOSIT', v_amount_cents, p_reference, p_actor);
    COMMIT;
END$$

-- Withdraw amount in rupees
CREATE PROCEDURE sp_withdraw(
    IN p_account_id BIGINT,
    IN p_amount_rupees DECIMAL(18,2),
    IN p_reference VARCHAR(120),
    IN p_actor VARCHAR(60)
)
BEGIN
    DECLARE v_amount_cents BIGINT;
    DECLARE v_balance BIGINT;
    DECLARE v_status ENUM('ACTIVE','FROZEN','CLOSED');

    SELECT status, balance_cents INTO v_status, v_balance
    FROM accounts WHERE account_id = p_account_id FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not active';
    END IF;

    SET v_amount_cents = ROUND(p_amount_rupees * 100);
    IF v_amount_cents <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Withdrawal must be positive';
    END IF;
    IF v_balance < v_amount_cents THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    START TRANSACTION;
        UPDATE accounts SET balance_cents = balance_cents - v_amount_cents
        WHERE account_id = p_account_id;

        INSERT INTO account_transactions(account_id, txn_type, amount_cents, reference, created_by)
        VALUES (p_account_id, 'WITHDRAWAL', v_amount_cents, p_reference, p_actor);
    COMMIT;
END$$

-- Transfer rupees between two accounts atomically
CREATE PROCEDURE sp_transfer_funds(
    IN p_from_account BIGINT,
    IN p_to_account BIGINT,
    IN p_amount_rupees DECIMAL(18,2),
    IN p_reference VARCHAR(120),
    IN p_actor VARCHAR(60)
)
BEGIN
    DECLARE v_amount_cents BIGINT;
    DECLARE v_from_balance BIGINT;
    DECLARE v_from_status ENUM('ACTIVE','FROZEN','CLOSED');
    DECLARE v_to_status   ENUM('ACTIVE','FROZEN','CLOSED');

    IF p_from_account = p_to_account THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot transfer to same account';
    END IF;

    SET v_amount_cents = ROUND(p_amount_rupees * 100);
    IF v_amount_cents <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfer amount must be positive';
    END IF;

    -- Lock accounts in id order to avoid deadlocks
    IF p_from_account < p_to_account THEN
        SELECT status, balance_cents INTO v_from_status, v_from_balance FROM accounts WHERE account_id = p_from_account FOR UPDATE;
        SELECT status INTO v_to_status FROM accounts WHERE account_id = p_to_account FOR UPDATE;
    ELSE
        SELECT status INTO v_to_status FROM accounts WHERE account_id = p_to_account FOR UPDATE;
        SELECT status, balance_cents INTO v_from_status, v_from_balance FROM accounts WHERE account_id = p_from_account FOR UPDATE;
    END IF;

    IF v_from_status IS NULL OR v_to_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found';
    END IF;
    IF v_from_status <> 'ACTIVE' OR v_to_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Both accounts must be ACTIVE';
    END IF;
    IF v_from_balance < v_amount_cents THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    START TRANSACTION;
        UPDATE accounts SET balance_cents = balance_cents - v_amount_cents WHERE account_id = p_from_account;
        UPDATE accounts SET balance_cents = balance_cents + v_amount_cents WHERE account_id = p_to_account;

        INSERT INTO account_transactions(account_id, txn_type, amount_cents, related_account, reference, created_by)
        VALUES (p_from_account, 'TRANSFER_OUT', v_amount_cents, p_to_account, p_reference, p_actor);

        INSERT INTO account_transactions(account_id, txn_type, amount_cents, related_account, reference, created_by)
        VALUES (p_to_account, 'TRANSFER_IN', v_amount_cents, p_from_account, p_reference, p_actor);
    COMMIT;
END$$

-- Post monthly interest for all ACTIVE savings accounts (code='SAVINGS')
CREATE PROCEDURE sp_post_monthly_interest(
    IN p_account_type_code VARCHAR(20),
    IN p_annual_rate_percent DECIMAL(9,4),
    IN p_actor VARCHAR(60)
)
BEGIN
    DECLARE v_rate_monthly DECIMAL(18,10);
    SET v_rate_monthly = p_annual_rate_percent / 100.0 / 12.0;

    INSERT INTO account_transactions(account_id, txn_type, amount_cents, reference, created_by)
    SELECT a.account_id,
           'INTEREST',
           ROUND(a.balance_cents * v_rate_monthly),
           CONCAT('Monthly interest @', p_annual_rate_percent, '%'),
           p_actor
    FROM accounts a
    JOIN account_types t ON t.account_type_id = a.account_type_id
    WHERE a.status = 'ACTIVE'
      AND t.code = p_account_type_code
      AND a.balance_cents > 0;

    -- Apply to balances
    UPDATE accounts a
    JOIN (
        SELECT account_id, SUM(amount_cents) AS add_cents
        FROM account_transactions
        WHERE txn_type = 'INTEREST' AND DATE(txn_time) = CURRENT_DATE()
        GROUP BY account_id
    ) x ON x.account_id = a.account_id
    SET a.balance_cents = a.balance_cents + x.add_cents;
END$$

-- Fee posting utility
CREATE PROCEDURE sp_post_fee(
    IN p_account_id BIGINT,
    IN p_fee_rupees DECIMAL(18,2),
    IN p_reference VARCHAR(120),
    IN p_actor VARCHAR(60)
)
BEGIN
    DECLARE v_fee_cents BIGINT;
    DECLARE v_status ENUM('ACTIVE','FROZEN','CLOSED');

    SET v_fee_cents = ROUND(p_fee_rupees * 100);
    SELECT status INTO v_status FROM accounts WHERE account_id = p_account_id FOR UPDATE;

    IF v_status IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found'; END IF;
    IF v_status <> 'ACTIVE' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not active'; END IF;

    START TRANSACTION;
        UPDATE accounts SET balance_cents = IF(balance_cents >= v_fee_cents, balance_cents - v_fee_cents, 0)
        WHERE account_id = p_account_id;

        INSERT INTO account_transactions(account_id, txn_type, amount_cents, reference, created_by)
        VALUES (p_account_id, 'FEE', v_fee_cents, p_reference, p_actor);
    COMMIT;
END$$

-- =====================================================================
-- 6) Stored Procedures (Loans)
-- =====================================================================

-- Create a loan record (PENDING) and disburse to an account
CREATE PROCEDURE sp_create_and_disburse_loan(
    IN p_customer_id BIGINT,
    IN p_branch_id BIGINT,
    IN p_product_code VARCHAR(20),
    IN p_principal_rupees DECIMAL(18,2),
    IN p_disburse_account_id BIGINT,
    IN p_actor VARCHAR(60)
)
BEGIN
    DECLARE v_product_id BIGINT;
    DECLARE v_principal_cents BIGINT;
    DECLARE v_loan_id BIGINT;

    SELECT product_id INTO v_product_id FROM loan_products WHERE code = p_product_code;
    IF v_product_id IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid product code'; END IF;

    SET v_principal_cents = ROUND(p_principal_rupees * 100);

    INSERT INTO loans(customer_id, branch_id, product_id, principal_cents, disbursed_cents, outstanding_cents, status)
    VALUES (p_customer_id, p_branch_id, v_product_id, v_principal_cents, 0, v_principal_cents, 'PENDING');
    SET v_loan_id = LAST_INSERT_ID();

    -- Disburse by crediting customer account and marking loan ACTIVE
    CALL sp_deposit(p_disburse_account_id, p_principal_rupees, CONCAT('Loan Disbursement L', v_loan_id), p_actor);
    UPDATE loans SET disbursed_cents = v_principal_cents, status='ACTIVE' WHERE loan_id = v_loan_id;

    INSERT INTO audit_log(actor, action, entity, entity_id, details)
    VALUES (p_actor, 'DISBURSE', 'LOAN', v_loan_id, JSON_OBJECT('principal_cents', v_principal_cents, 'to_account', p_disburse_account_id));

    SELECT v_loan_id AS loan_id;
END$$

-- Record a loan payment (reduces outstanding) and debits a funding account
CREATE PROCEDURE sp_loan_payment(
    IN p_loan_id BIGINT,
    IN p_from_account BIGINT,
    IN p_amount_rupees DECIMAL(18,2),
    IN p_actor VARCHAR(60)
)
BEGIN
    DECLARE v_amount_cents BIGINT;
    DECLARE v_outstanding BIGINT;
    DECLARE v_status ENUM('PENDING','ACTIVE','CLOSED','DEFAULTED');

    SELECT outstanding_cents, status INTO v_outstanding, v_status FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF v_status IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found'; END IF;
    IF v_status <> 'ACTIVE' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not ACTIVE'; END IF;

    SET v_amount_cents = ROUND(p_amount_rupees * 100);
    IF v_amount_cents <= 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment must be positive'; END IF;

    -- collect funds
    CALL sp_withdraw(p_from_account, p_amount_rupees, CONCAT('Loan Payment L', p_loan_id), p_actor);

    INSERT INTO loan_payments(loan_id, amount_cents, method, reference)
    VALUES (p_loan_id, v_amount_cents, 'TRANSFER', CONCAT('From AC ', p_from_account));

    UPDATE loans
    SET outstanding_cents = GREATEST(0, outstanding_cents - v_amount_cents),
        status = IF(outstanding_cents - v_amount_cents <= 0, 'CLOSED', status),
        closed_at = IF(outstanding_cents - v_amount_cents <= 0, CURRENT_TIMESTAMP, closed_at)
    WHERE loan_id = p_loan_id;

    INSERT INTO audit_log(actor, action, entity, entity_id, details)
    VALUES (p_actor, 'PAYMENT', 'LOAN', p_loan_id, JSON_OBJECT('amount_cents', v_amount_cents, 'from_account', p_from_account));
END$$

DELIMITER ;

-- =====================================================================
-- 7) Views & Reporting
-- =====================================================================

CREATE OR REPLACE VIEW v_accounts_balances AS
SELECT a.account_id, a.account_no, c.customer_id,
       CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
       t.code AS account_type, a.status, a.balance_cents/100.0 AS balance_rupees,
       b.branch_code, b.branch_name, a.opened_at, a.closed_at
FROM accounts a
JOIN customers c ON c.customer_id = a.customer_id
JOIN account_types t ON t.account_type_id = a.account_type_id
JOIN branches b ON b.branch_id = a.branch_id;

CREATE OR REPLACE VIEW v_transactions_readable AS
SELECT t.txn_id, t.account_id, a.account_no, t.txn_time, t.txn_type,
       t.amount_cents/100.0 AS amount_rupees, t.related_account, t.reference, t.created_by
FROM account_transactions t
JOIN accounts a ON a.account_id = t.account_id;

-- Sample reports (runnable queries)
-- 1) Daily transactions summary
-- SELECT DATE(txn_time) as day, txn_type, COUNT(*) cnt, SUM(amount_cents)/100.0 total_rupees
-- FROM account_transactions GROUP BY day, txn_type ORDER BY day DESC;

-- 2) Top N customers by balance
-- SELECT customer_id, customer_name, SUM(balance_rupees) total_rupees
-- FROM v_accounts_balances GROUP BY customer_id, customer_name
-- ORDER BY total_rupees DESC LIMIT 10;

-- 3) Overdraw attempts (captured via errors in application/audit; for demo we rely on errors thrown)

-- =====================================================================
-- 8) Seed Data
-- =====================================================================

INSERT INTO branches(branch_code, branch_name, city, state) VALUES
('BLR01','Bengaluru Main','Bengaluru','KA'),
('HYD01','Hyderabad Central','Hyderabad','TS'),
('PUN01','Pune Camp','Pune','MH');

INSERT INTO customers(first_name, last_name, email, phone, city, state, postal_code) VALUES
('Aarav','Sharma','aarav.sharma@example.com','9000000001','Bengaluru','KA','560001'),
('Diya','Kapoor','diya.kapoor@example.com','9000000002','Hyderabad','TS','500001'),
('Rahul','Nair','rahul.nair@example.com','9000000003','Pune','MH','411001');

INSERT INTO account_types(code, description) VALUES
('SAVINGS','Savings Account'),
('CURRENT','Current Account');

-- Open accounts and do some transactions
CALL sp_open_account(1, 1, 'SAVINGS', 5000.00, 'ADMIN'); -- returns account_id, account_no
CALL sp_open_account(2, 2, 'SAVINGS', 10000.00, 'ADMIN');
CALL sp_open_account(3, 3, 'CURRENT', 20000.00, 'ADMIN');

-- Assume created accounts have IDs 1,2,3 (auto-increment, as first run)
CALL sp_deposit(1, 1500.00, 'Salary credit', 'SYSTEM');
CALL sp_withdraw(1, 300.00, 'ATM withdrawal', 'SYSTEM');
CALL sp_transfer_funds(2, 1, 2000.00, 'Gift', 'SYSTEM');

-- Post monthly interest for savings
CALL sp_post_monthly_interest('SAVINGS', 6.0, 'SYSTEM');

-- Loans: define product and disburse
INSERT INTO loan_products(code, name, annual_rate_bp, term_months, description)
VALUES ('PLN', 'Personal Loan', 1200, 24, 'Unsecured personal loan');

-- Create loan for customer 1 and disburse to account 1
CALL sp_create_and_disburse_loan(1, 1, 'PLN', 50000.00, 1, 'LOAN_OFFICER');

-- Make a payment from account 1
CALL sp_loan_payment(1, 1, 5000.00, 'LOAN_OFFICER');

-- =====================================================================
-- 9) Permissions (optional demo)
-- =====================================================================
-- CREATE ROLE banker, teller, auditor;
-- GRANT SELECT, INSERT, UPDATE ON banking_system.* TO banker;
-- GRANT SELECT, INSERT ON banking_system.account_transactions TO teller;
-- GRANT SELECT ON banking_system.* TO auditor;

-- =====================================================================
-- 10) Useful Selects to Verify
-- =====================================================================
-- SELECT * FROM v_accounts_balances;
-- SELECT * FROM v_transactions_readable ORDER BY txn_id DESC LIMIT 50;
-- SELECT * FROM loans;
-- SELECT * FROM loan_payments ORDER BY payment_id DESC;
-- SELECT * FROM audit_log ORDER BY audit_id DESC LIMIT 50;

SET FOREIGN_KEY_CHECKS = 1;
"""
path = "/mnt/data/banking_system_mysql.sql"
with open(path, "w", encoding="utf-8") as f:
    f.write(sql)
path
