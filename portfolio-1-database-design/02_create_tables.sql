-- ==============================================================================
-- Portfolio 1: LendBridge Advanced Relational Database Design
-- Script: 02_create_tables.sql
-- Description: Creates the 8 core relational tables with strict integrity constraints,
--              defensive data types, and immutable ledger foreign key policies.
-- Author: Senior Database Engineer & MIT 8103 Project Contributor
-- Target Engine: PostgreSQL 14+
-- ==============================================================================
--
-- EXECUTION INSTRUCTIONS FOR pgAdmin:
-- 1. Ensure you are connected to 'lendbridge_db' in pgAdmin Query Tool.
-- 2. Execute the entire script (F5).
-- 3. Wrapped in an atomic transaction (BEGIN ... COMMIT).
-- ==============================================================================

BEGIN;

-- ------------------------------------------------------------------------------
-- CLEANUP / IDEMPOTENT TEARDOWN (In reverse dependency order)
-- ------------------------------------------------------------------------------
DROP TABLE IF EXISTS repayment_allocations CASCADE;
DROP TABLE IF EXISTS repayments CASCADE;
DROP TABLE IF EXISTS instalments CASCADE;
DROP TABLE IF EXISTS loans CASCADE;
DROP TABLE IF EXISTS loan_applications CASCADE;
DROP TABLE IF EXISTS loan_products CASCADE;
DROP TABLE IF EXISTS kyc_records CASCADE;
DROP TABLE IF EXISTS borrowers CASCADE;

-- ------------------------------------------------------------------------------
-- 1. TABLE: borrowers
-- Purpose: Authoritative store for verified customer business identities.
-- Business Rules:
--  - Email and phone must be non-null, uniquely indexed, and validated.
--  - Email is strictly normalized to lowercase to prevent casing duplicates.
--  - Preserved against accidental deletion (ON DELETE RESTRICT in referencing FKs).
-- ------------------------------------------------------------------------------
CREATE TABLE borrowers (
    borrower_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    business_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Row-level integrity constraints
    CONSTRAINT uq_borrowers_email UNIQUE (email),
    CONSTRAINT uq_borrowers_phone UNIQUE (phone),
    CONSTRAINT chk_borrowers_email_lowercase CHECK (email = LOWER(email)),
    CONSTRAINT chk_borrowers_email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    CONSTRAINT chk_borrowers_phone_format CHECK (phone ~ '^\+?[0-9]{10,15}$')
);

COMMENT ON TABLE borrowers IS 'Authoritative customer identity records for LendBridge micro and small business borrowers.';
COMMENT ON COLUMN borrowers.borrower_id IS 'Surrogate identity primary key.';
COMMENT ON COLUMN borrowers.business_name IS 'Registered or operational trade name of the borrower business enterprise.';
COMMENT ON COLUMN borrowers.email IS 'Primary contact email; strictly enforced in lowercase.';
COMMENT ON COLUMN borrowers.phone IS 'Primary MSISDN telephone number in E.164 compatible format.';

-- ------------------------------------------------------------------------------
-- 2. TABLE: kyc_records
-- Purpose: Stores Know-Your-Customer identity verification artifacts and decisions.
-- Business Rules:
--  - Status must be PENDING, VERIFIED, or REJECTED.
--  - PENDING submissions must NOT have a decided_at timestamp.
--  - VERIFIED or REJECTED submissions REQUIRE a decided_at timestamp.
--  - Decision timestamp must not precede submission timestamp.
-- ------------------------------------------------------------------------------
CREATE TABLE kyc_records (
    kyc_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    borrower_id BIGINT NOT NULL,
    document_type VARCHAR(50) NOT NULL,
    document_reference VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    decided_at TIMESTAMPTZ,

    -- Foreign Key
    CONSTRAINT fk_kyc_borrower FOREIGN KEY (borrower_id) 
        REFERENCES borrowers (borrower_id) ON DELETE RESTRICT,

    -- Row-level integrity constraints
    CONSTRAINT chk_kyc_status_valid CHECK (status IN ('PENDING', 'VERIFIED', 'REJECTED')),
    CONSTRAINT chk_kyc_decision_lifecycle CHECK (
        (status = 'PENDING' AND decided_at IS NULL) OR
        (status IN ('VERIFIED', 'REJECTED') AND decided_at IS NOT NULL)
    ),
    CONSTRAINT chk_kyc_decision_chronology CHECK (
        decided_at IS NULL OR decided_at >= submitted_at
    )
);

COMMENT ON TABLE kyc_records IS 'Identity verification submissions (BVN, NIN, CAC) supporting borrower credit applications.';
COMMENT ON COLUMN kyc_records.document_reference IS 'Synthetic/external verification reference code.';
COMMENT ON COLUMN kyc_records.decided_at IS 'Timestamp of verification decision; required once decided, forbidden while pending.';

-- ------------------------------------------------------------------------------
-- 3. TABLE: loan_products
-- Purpose: Lending catalog defining commercial boundaries and term profiles.
-- Business Rules:
--  - Minimum amount must be positive.
--  - Maximum amount must be >= minimum amount.
--  - Loan term is bounded between 1 and 12 calendar months.
--  - Flat interest rate must be non-negative (NUMERIC(7,6) e.g., 0.060000 = 6.0%).
-- ------------------------------------------------------------------------------
CREATE TABLE loan_products (
    product_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_name VARCHAR(100) NOT NULL,
    min_amount NUMERIC(19, 2) NOT NULL,
    max_amount NUMERIC(19, 2) NOT NULL,
    term_months INT NOT NULL,
    flat_rate NUMERIC(7, 6) NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,

    -- Constraints
    CONSTRAINT uq_loan_products_name UNIQUE (product_name),
    CONSTRAINT chk_products_min_amount_positive CHECK (min_amount > 0),
    CONSTRAINT chk_products_amount_range CHECK (max_amount >= min_amount),
    CONSTRAINT chk_products_term_bounds CHECK (term_months BETWEEN 1 AND 12),
    CONSTRAINT chk_products_flat_rate_nonnegative CHECK (flat_rate >= 0)
);

COMMENT ON TABLE loan_products IS 'Commercial product catalog defining eligible loan amounts, terms, and fixed flat rates.';
COMMENT ON COLUMN loan_products.flat_rate IS 'Fractional flat interest rate across the full term (e.g. 0.060000 = 6%).';

-- ------------------------------------------------------------------------------
-- 4. TABLE: loan_applications
-- Purpose: Borrower formal requests for loan capital and associated underwriting decisions.
-- Business Rules:
--  - Requested amount must be strictly positive.
--  - Status must be SUBMITTED, APPROVED, or REJECTED.
--  - SUBMITTED applications have no decision fields and no linked approved KYC record.
--  - REJECTED applications require a decision timestamp and reason, but no approved KYC.
--  - APPROVED applications require a decision timestamp, reason, and an approved_kyc_id.
-- ------------------------------------------------------------------------------
CREATE TABLE loan_applications (
    application_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    borrower_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    approved_kyc_id BIGINT,
    requested_amount NUMERIC(19, 2) NOT NULL,
    purpose TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'SUBMITTED',
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    decided_at TIMESTAMPTZ,
    decision_reason TEXT,

    -- Foreign Keys
    CONSTRAINT fk_applications_borrower FOREIGN KEY (borrower_id)
        REFERENCES borrowers (borrower_id) ON DELETE RESTRICT,
    CONSTRAINT fk_applications_product FOREIGN KEY (product_id)
        REFERENCES loan_products (product_id) ON DELETE RESTRICT,
    CONSTRAINT fk_applications_kyc FOREIGN KEY (approved_kyc_id)
        REFERENCES kyc_records (kyc_id) ON DELETE RESTRICT,

    -- Constraints
    CONSTRAINT chk_applications_amount_positive CHECK (requested_amount > 0),
    CONSTRAINT chk_applications_status_valid CHECK (status IN ('SUBMITTED', 'APPROVED', 'REJECTED')),
    CONSTRAINT chk_applications_lifecycle_state CHECK (
        (status = 'SUBMITTED' AND decided_at IS NULL AND decision_reason IS NULL AND approved_kyc_id IS NULL) OR
        (status = 'REJECTED'  AND decided_at IS NOT NULL AND decision_reason IS NOT NULL AND approved_kyc_id IS NULL) OR
        (status = 'APPROVED'  AND decided_at IS NOT NULL AND decision_reason IS NOT NULL AND approved_kyc_id IS NOT NULL)
    ),
    CONSTRAINT chk_applications_chronology CHECK (
        decided_at IS NULL OR decided_at >= submitted_at
    )
);

COMMENT ON TABLE loan_applications IS 'Credit requests submitted by borrowers, underwritten by credit officers.';
COMMENT ON COLUMN loan_applications.approved_kyc_id IS 'Audit trace linking approval decision directly to the verified identity document.';

-- ------------------------------------------------------------------------------
-- 5. TABLE: loans
-- Purpose: Frozen contractual financial agreements resulting from approved applications.
-- Business Rules:
--  - 1-to-1 relationship with approved applications (UNIQUE application_id).
--  - Freezes principal, flat_rate, and term_months as historical snapshots so future
--    product catalog modifications never alter existing legal debt contracts.
--  - Loan reference must be globally unique.
-- ------------------------------------------------------------------------------
CREATE TABLE loans (
    loan_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id BIGINT NOT NULL,
    loan_reference VARCHAR(50) NOT NULL,
    principal NUMERIC(19, 2) NOT NULL,
    flat_rate NUMERIC(7, 6) NOT NULL,
    term_months INT NOT NULL,
    disbursed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Constraints
    CONSTRAINT uq_loans_application_id UNIQUE (application_id),
    CONSTRAINT uq_loans_reference UNIQUE (loan_reference),
    CONSTRAINT fk_loans_application FOREIGN KEY (application_id)
        REFERENCES loan_applications (application_id) ON DELETE RESTRICT,
    CONSTRAINT chk_loans_principal_positive CHECK (principal > 0),
    CONSTRAINT chk_loans_flat_rate_nonnegative CHECK (flat_rate >= 0),
    CONSTRAINT chk_loans_term_months_bounds CHECK (term_months BETWEEN 1 AND 12)
);

COMMENT ON TABLE loans IS 'Disbursed contractual loans with snapshot financial parameters frozen at disbursement.';
COMMENT ON COLUMN loans.principal IS 'Disbursed capital snapshot in NGN.';
COMMENT ON COLUMN loans.flat_rate IS 'Fixed contractual flat interest rate snapshot.';

-- ------------------------------------------------------------------------------
-- 6. TABLE: instalments
-- Purpose: Scheduled repayment calendar obligations for each loan.
-- Business Rules:
--  - instalment_no is positive and unique per loan.
--  - principal_due and interest_due are non-negative.
--  - total_due is automatically calculated as (principal_due + interest_due).
--  - total_due must be strictly positive.
-- ------------------------------------------------------------------------------
CREATE TABLE instalments (
    instalment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id BIGINT NOT NULL,
    instalment_no INT NOT NULL,
    due_date DATE NOT NULL,
    principal_due NUMERIC(19, 2) NOT NULL,
    interest_due NUMERIC(19, 2) NOT NULL,
    total_due NUMERIC(19, 2) GENERATED ALWAYS AS (principal_due + interest_due) STORED,

    -- Foreign Key
    CONSTRAINT fk_instalments_loan FOREIGN KEY (loan_id)
        REFERENCES loans (loan_id) ON DELETE RESTRICT,

    -- Constraints
    CONSTRAINT uq_instalments_loan_no UNIQUE (loan_id, instalment_no),
    CONSTRAINT chk_instalments_no_positive CHECK (instalment_no > 0),
    CONSTRAINT chk_instalments_principal_nonnegative CHECK (principal_due >= 0),
    CONSTRAINT chk_instalments_interest_nonnegative CHECK (interest_due >= 0),
    CONSTRAINT chk_instalments_total_due_positive CHECK ((principal_due + interest_due) > 0)
);

COMMENT ON TABLE instalments IS 'Individual repayment schedule milestones establishing contractual due dates and splits.';
COMMENT ON COLUMN instalments.total_due IS 'Generated stored total obligation (principal_due + interest_due).';

-- ------------------------------------------------------------------------------
-- 7. TABLE: repayments
-- Purpose: Inbound settlement payments received through payment gateways/providers.
-- Business Rules:
--  - Amount must be strictly positive.
--  - provider_reference is unique (ensures external gateway callback uniqueness).
--  - idempotency_key is unique (prevents network retries from double-recording receipts).
--  - Immutable payment ledger; records confirmed cash receipts only.
-- ------------------------------------------------------------------------------
CREATE TABLE repayments (
    repayment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id BIGINT NOT NULL,
    provider_reference VARCHAR(100) NOT NULL,
    idempotency_key VARCHAR(100) NOT NULL,
    amount NUMERIC(19, 2) NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Foreign Key
    CONSTRAINT fk_repayments_loan FOREIGN KEY (loan_id)
        REFERENCES loans (loan_id) ON DELETE RESTRICT,

    -- Constraints
    CONSTRAINT uq_repayments_provider_ref UNIQUE (provider_reference),
    CONSTRAINT uq_repayments_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT chk_repayments_amount_positive CHECK (amount > 0)
);

COMMENT ON TABLE repayments IS 'Confirmed financial cash receipts recorded from simulated payment gateway callbacks.';
COMMENT ON COLUMN repayments.provider_reference IS 'External transaction reference provided by payment processor (e.g. Paystack/Flutterwave).';
COMMENT ON COLUMN repayments.idempotency_key IS 'Unique client request token preventing double-billing on network replay.';

-- ------------------------------------------------------------------------------
-- 8. TABLE: repayment_allocations
-- Purpose: Resolves the Many-to-Many relationship between repayments and instalments.
-- Business Rules:
--  - Composite primary key (repayment_id, instalment_id).
--  - Allocated amount must be strictly positive.
--  - Foreign keys restrict deletions of parent payments and scheduled instalments.
-- ------------------------------------------------------------------------------
CREATE TABLE repayment_allocations (
    repayment_id BIGINT NOT NULL,
    instalment_id BIGINT NOT NULL,
    allocated_amount NUMERIC(19, 2) NOT NULL,
    allocated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Composite Primary Key
    CONSTRAINT pk_repayment_allocations PRIMARY KEY (repayment_id, instalment_id),

    -- Foreign Keys
    CONSTRAINT fk_allocations_repayment FOREIGN KEY (repayment_id)
        REFERENCES repayments (repayment_id) ON DELETE RESTRICT,
    CONSTRAINT fk_allocations_instalment FOREIGN KEY (instalment_id)
        REFERENCES instalments (instalment_id) ON DELETE RESTRICT,

    -- Constraints
    CONSTRAINT chk_allocations_amount_positive CHECK (allocated_amount > 0)
);

COMMENT ON TABLE repayment_allocations IS 'Ledger mapping payment receipts to specific instalment obligations.';
COMMENT ON COLUMN repayment_allocations.allocated_amount IS 'Specific kobo amount from repayment applied to satisfy the instalment balance.';

COMMIT;
