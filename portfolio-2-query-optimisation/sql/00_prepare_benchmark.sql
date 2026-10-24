-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
-- Run once. If lb_bench exists, this fails rather than removing your benchmark.
BEGIN;
CREATE SCHEMA lb_bench;
CREATE TABLE lb_bench.borrowers (
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
CREATE TABLE lb_bench.kyc_records (
    kyc_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    borrower_id BIGINT NOT NULL,
    document_type VARCHAR(50) NOT NULL,
    document_reference VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    decided_at TIMESTAMPTZ,

    -- Foreign Key
    CONSTRAINT fk_kyc_borrower FOREIGN KEY (borrower_id) 
        REFERENCES lb_bench.borrowers (borrower_id) ON DELETE RESTRICT,

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
CREATE TABLE lb_bench.loan_products (
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
CREATE TABLE lb_bench.loan_applications (
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
        REFERENCES lb_bench.borrowers (borrower_id) ON DELETE RESTRICT,
    CONSTRAINT fk_applications_product FOREIGN KEY (product_id)
        REFERENCES lb_bench.loan_products (product_id) ON DELETE RESTRICT,
    CONSTRAINT fk_applications_kyc FOREIGN KEY (approved_kyc_id)
        REFERENCES lb_bench.kyc_records (kyc_id) ON DELETE RESTRICT,

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
CREATE TABLE lb_bench.loans (
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
        REFERENCES lb_bench.loan_applications (application_id) ON DELETE RESTRICT,
    CONSTRAINT chk_loans_principal_positive CHECK (principal > 0),
    CONSTRAINT chk_loans_flat_rate_nonnegative CHECK (flat_rate >= 0),
    CONSTRAINT chk_loans_term_months_bounds CHECK (term_months BETWEEN 1 AND 12)
);
CREATE TABLE lb_bench.instalments (
    instalment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id BIGINT NOT NULL,
    instalment_no INT NOT NULL,
    due_date DATE NOT NULL,
    principal_due NUMERIC(19, 2) NOT NULL,
    interest_due NUMERIC(19, 2) NOT NULL,
    total_due NUMERIC(19, 2) GENERATED ALWAYS AS (principal_due + interest_due) STORED,

    -- Foreign Key
    CONSTRAINT fk_instalments_loan FOREIGN KEY (loan_id)
        REFERENCES lb_bench.loans (loan_id) ON DELETE RESTRICT,

    -- Constraints
    CONSTRAINT uq_instalments_loan_no UNIQUE (loan_id, instalment_no),
    CONSTRAINT chk_instalments_no_positive CHECK (instalment_no > 0),
    CONSTRAINT chk_instalments_principal_nonnegative CHECK (principal_due >= 0),
    CONSTRAINT chk_instalments_interest_nonnegative CHECK (interest_due >= 0),
    CONSTRAINT chk_instalments_total_due_positive CHECK ((principal_due + interest_due) > 0)
);
CREATE TABLE lb_bench.repayments (
    repayment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id BIGINT NOT NULL,
    provider_reference VARCHAR(100) NOT NULL,
    idempotency_key VARCHAR(100) NOT NULL,
    amount NUMERIC(19, 2) NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Foreign Key
    CONSTRAINT fk_repayments_loan FOREIGN KEY (loan_id)
        REFERENCES lb_bench.loans (loan_id) ON DELETE RESTRICT,

    -- Constraints
    CONSTRAINT uq_repayments_provider_ref UNIQUE (provider_reference),
    CONSTRAINT uq_repayments_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT chk_repayments_amount_positive CHECK (amount > 0)
);
CREATE TABLE lb_bench.repayment_allocations (
    repayment_id BIGINT NOT NULL,
    instalment_id BIGINT NOT NULL,
    allocated_amount NUMERIC(19, 2) NOT NULL,
    allocated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Composite Primary Key
    CONSTRAINT pk_repayment_allocations PRIMARY KEY (repayment_id, instalment_id),

    -- Foreign Keys
    CONSTRAINT fk_allocations_repayment FOREIGN KEY (repayment_id)
        REFERENCES lb_bench.repayments (repayment_id) ON DELETE RESTRICT,
    CONSTRAINT fk_allocations_instalment FOREIGN KEY (instalment_id)
        REFERENCES lb_bench.instalments (instalment_id) ON DELETE RESTRICT,

    -- Constraints
    CONSTRAINT chk_allocations_amount_positive CHECK (allocated_amount > 0)
);
-- This is a constrained synthetic performance model. It has the same eight table
-- definitions, but deliberately does not copy Portfolio 1 procedures or triggers.
-- All generated rows below satisfy the demonstrated lending and allocation rules.
INSERT INTO lb_bench.loan_products(product_name,min_amount,max_amount,term_months,flat_rate)
VALUES ('Benchmark 6M',20000,2000000,6,0.12);
INSERT INTO lb_bench.borrowers(first_name,last_name,business_name,email,phone)
SELECT 'Borrower', g::text, 'Synthetic MSME '||g, 'bench'||g||'@example.test',
 '+234'||lpad(g::text,10,'0') FROM generate_series(1,5000) g;
INSERT INTO lb_bench.kyc_records(borrower_id,document_type,document_reference,status,submitted_at,decided_at)
SELECT g,'BVN','SYNTHETIC-'||g,'VERIFIED','2024-01-01 UTC','2024-01-02 UTC'
FROM generate_series(1,5000) g;
INSERT INTO lb_bench.loan_applications(borrower_id,product_id,approved_kyc_id,requested_amount,purpose,status,submitted_at,decided_at,decision_reason)
SELECT (g-1)%5000+1,1,(g-1)%5000+1,300000,'Synthetic working capital',
 'APPROVED','2024-01-03 UTC','2024-01-04 UTC','Synthetic benchmark approval'
FROM generate_series(1,50000) g;
INSERT INTO lb_bench.loans(application_id,loan_reference,principal,flat_rate,term_months,disbursed_at)
SELECT g,'LB-BENCH-'||lpad(g::text,6,'0'),300000,0.12,6,
 timestamptz '2024-01-05 UTC'+((g-1)%365)*interval '1 day'
FROM generate_series(1,50000) g;
INSERT INTO lb_bench.instalments(loan_id,instalment_no,due_date,principal_due,interest_due)
SELECT l.loan_id,n,(l.disbursed_at AT TIME ZONE 'UTC')::date+ n*30,50000,6000
FROM lb_bench.loans l CROSS JOIN generate_series(1,6) n;
-- Four receipts per loan, each pays two half-instalments (28,000 + 28,000).
-- The first four instalments receive 56,000 each; last two remain unpaid.
INSERT INTO lb_bench.repayments(loan_id,provider_reference,idempotency_key,amount,received_at)
SELECT l.loan_id,'PROV-'||l.loan_id||'-'||n,'IDEM-'||l.loan_id||'-'||n,56000,
 l.disbursed_at+n*interval '30 days'
FROM lb_bench.loans l CROSS JOIN generate_series(1,4) n;
INSERT INTO lb_bench.repayment_allocations(repayment_id,instalment_id,allocated_amount,allocated_at)
SELECT r.repayment_id,i.instalment_id,28000,r.received_at
FROM lb_bench.repayments r
JOIN lb_bench.instalments i ON i.loan_id=r.loan_id
 AND i.instalment_no IN (
 split_part(r.provider_reference,'-',3)::int,
 split_part(r.provider_reference,'-',3)::int%4+1);
COMMIT;
ANALYZE lb_bench.borrowers;
ANALYZE lb_bench.kyc_records;
ANALYZE lb_bench.loan_products;
ANALYZE lb_bench.loan_applications;
ANALYZE lb_bench.loans;
ANALYZE lb_bench.instalments;
ANALYZE lb_bench.repayments;
ANALYZE lb_bench.repayment_allocations;
SELECT 'borrowers' AS table_name,count(*) AS rows FROM lb_bench.borrowers
UNION ALL SELECT 'loans',count(*) FROM lb_bench.loans
UNION ALL SELECT 'instalments',count(*) FROM lb_bench.instalments
UNION ALL SELECT 'repayments',count(*) FROM lb_bench.repayments
UNION ALL SELECT 'repayment_allocations',count(*) FROM lb_bench.repayment_allocations;
