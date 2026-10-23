-- ==============================================================================
-- Portfolio 1: LendBridge Advanced Relational Database Design
-- Script: 03_procedures_and_triggers.sql
-- Description: Business workflow procedures, concurrency controls (row-locking),
--              and defensive triggers guarding relational and ledger integrity.
-- Author: Senior Database Engineer & MIT 8103 Project Contributor
-- Target Engine: PostgreSQL 14+
-- ==============================================================================
--
-- EXECUTION INSTRUCTIONS FOR pgAdmin:
-- 1. Ensure you are connected to 'lendbridge_db' in pgAdmin Query Tool.
-- 2. Execute the entire script (F5).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- TRIGGER FUNCTION 1: fn_validate_repayment_allocation()
-- Purpose:
--  1. Ensures repayment and allocated instalment belong to the exact same loan.
--  2. Enforces allocation ceiling: Total allocated per repayment <= repayment.amount.
--  3. Enforces obligation ceiling: Total allocated per instalment <= instalment.total_due.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_validate_repayment_allocation()
RETURNS TRIGGER AS $$
DECLARE
    v_repayment_loan_id BIGINT;
    v_instalment_loan_id BIGINT;
    v_repayment_amount NUMERIC(19, 2);
    v_instalment_total_due NUMERIC(19, 2);
    v_current_rep_allocated NUMERIC(19, 2);
    v_current_inst_allocated NUMERIC(19, 2);
BEGIN
    -- 1. Verify parent repayment existence and retrieve loan_id + amount
    SELECT loan_id, amount 
    INTO v_repayment_loan_id, v_repayment_amount
    FROM repayments 
    WHERE repayment_id = NEW.repayment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Allocation rejected: Referenced repayment_id % does not exist.', NEW.repayment_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- 2. Verify parent instalment existence and retrieve loan_id + total_due
    SELECT loan_id, total_due 
    INTO v_instalment_loan_id, v_instalment_total_due
    FROM instalments 
    WHERE instalment_id = NEW.instalment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Allocation rejected: Referenced instalment_id % does not exist.', NEW.instalment_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- 3. Cross-loan integrity check (Rule: A repayment and its allocated instalment must belong to the same loan)
    IF v_repayment_loan_id IS DISTINCT FROM v_instalment_loan_id THEN
        RAISE EXCEPTION 'Cross-loan allocation prohibited: Repayment % belongs to Loan %, but Instalment % belongs to Loan %.',
            NEW.repayment_id, v_repayment_loan_id, NEW.instalment_id, v_instalment_loan_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- 4. Verify repayment ceiling: Total allocated from this repayment cannot exceed receipt amount
    SELECT COALESCE(SUM(allocated_amount), 0)
    INTO v_current_rep_allocated
    FROM repayment_allocations
    WHERE repayment_id = NEW.repayment_id
      AND NOT (repayment_id = NEW.repayment_id AND instalment_id = NEW.instalment_id);

    IF (v_current_rep_allocated + NEW.allocated_amount) > v_repayment_amount THEN
        RAISE EXCEPTION 'Allocation ceiling exceeded: Repayment % has amount %, but requested total allocation is % (existing % + new %).',
            NEW.repayment_id, v_repayment_amount, (v_current_rep_allocated + NEW.allocated_amount), v_current_rep_allocated, NEW.allocated_amount
            USING ERRCODE = 'check_violation';
    END IF;

    -- 5. Verify instalment ceiling: Total allocated to this instalment cannot exceed scheduled total_due
    SELECT COALESCE(SUM(allocated_amount), 0)
    INTO v_current_inst_allocated
    FROM repayment_allocations
    WHERE instalment_id = NEW.instalment_id
      AND NOT (repayment_id = NEW.repayment_id AND instalment_id = NEW.instalment_id);

    IF (v_current_inst_allocated + NEW.allocated_amount) > v_instalment_total_due THEN
        RAISE EXCEPTION 'Obligation ceiling exceeded: Instalment % has total_due %, but requested total allocation is % (existing % + new %).',
            NEW.instalment_id, v_instalment_total_due, (v_current_inst_allocated + NEW.allocated_amount), v_current_inst_allocated, NEW.allocated_amount
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_repayment_allocation ON repayment_allocations;
CREATE TRIGGER trg_validate_repayment_allocation
    BEFORE INSERT OR UPDATE ON repayment_allocations
    FOR EACH ROW
    EXECUTE FUNCTION fn_validate_repayment_allocation();

-- ------------------------------------------------------------------------------
-- TRIGGER FUNCTION 2: fn_guard_loan_contract_immutability()
-- Purpose: Freezes loan parameters at disbursement; prevents modification of snapshot terms.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_loan_contract_immutability()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.principal IS DISTINCT FROM OLD.principal OR
           NEW.flat_rate IS DISTINCT FROM OLD.flat_rate OR
           NEW.term_months IS DISTINCT FROM OLD.term_months OR
           NEW.application_id IS DISTINCT FROM OLD.application_id THEN
            RAISE EXCEPTION 'Contract terms are immutable: Loan % parameters cannot be modified post-disbursement.', OLD.loan_id
                USING ERRCODE = 'restrict_violation';
        END IF;
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Loan deletion prohibited: Disbursed loan % must be preserved for financial audit.', OLD.loan_id
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_guard_loan_contract_immutability ON loans;
CREATE TRIGGER trg_guard_loan_contract_immutability
    BEFORE UPDATE OR DELETE ON loans
    FOR EACH ROW
    EXECUTE FUNCTION fn_guard_loan_contract_immutability();

-- ------------------------------------------------------------------------------
-- TRIGGER FUNCTION 3: fn_guard_disbursed_application()
-- Purpose: Prevents modification or deletion of an application once disbursed into a loan.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_guard_disbursed_application()
RETURNS TRIGGER AS $$
DECLARE
    v_has_loan BOOLEAN;
BEGIN
    SELECT EXISTS (SELECT 1 FROM loans WHERE application_id = OLD.application_id)
    INTO v_has_loan;

    IF v_has_loan THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'Application deletion rejected: Application % has a disbursed loan.', OLD.application_id
                USING ERRCODE = 'restrict_violation';
        ELSIF TG_OP = 'UPDATE' THEN
            IF NEW.status IS DISTINCT FROM OLD.status OR
               NEW.requested_amount IS DISTINCT FROM OLD.requested_amount OR
               NEW.product_id IS DISTINCT FROM OLD.product_id THEN
                RAISE EXCEPTION 'Disbursed application is locked: Application % already produced a contractual loan.', OLD.application_id
                    USING ERRCODE = 'restrict_violation';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_guard_disbursed_application ON loan_applications;
CREATE TRIGGER trg_guard_disbursed_application
    BEFORE UPDATE OR DELETE ON loan_applications
    FOR EACH ROW
    EXECUTE FUNCTION fn_guard_disbursed_application();

-- ------------------------------------------------------------------------------
-- PROCEDURE 1: sp_approve_application()
-- Purpose: Controlled credit underwriting approval procedure.
-- Business Rules Enforced:
--  - Application must exist and be in 'SUBMITTED' status.
--  - Supporting KYC record must exist, belong to applicant, and have status 'VERIFIED'.
--  - Requested principal must be within product min_amount and max_amount limits.
--  - Product must be active.
--  - Row locking prevents concurrent conflicting approvals.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_approve_application(
    p_application_id BIGINT,
    p_kyc_id BIGINT,
    p_decision_reason TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrower_id BIGINT;
    v_product_id BIGINT;
    v_requested_amount NUMERIC(19, 2);
    v_app_status VARCHAR(20);
    
    v_kyc_borrower_id BIGINT;
    v_kyc_status VARCHAR(20);
    
    v_min_amount NUMERIC(19, 2);
    v_max_amount NUMERIC(19, 2);
    v_product_active BOOLEAN;
BEGIN
    IF p_decision_reason IS NULL OR TRIM(p_decision_reason) = '' THEN
        RAISE EXCEPTION 'Approval rejected: A valid decision reason is mandatory.'
            USING ERRCODE = 'check_violation';
    END IF;

    -- 1. Lock and inspect the application row
    SELECT borrower_id, product_id, requested_amount, status
    INTO v_borrower_id, v_product_id, v_requested_amount, v_app_status
    FROM loan_applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Approval rejected: Application % does not exist.', p_application_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_app_status <> 'SUBMITTED' THEN
        RAISE EXCEPTION 'Approval rejected: Application % is already in status "%". Only SUBMITTED applications can be approved.',
            p_application_id, v_app_status
            USING ERRCODE = 'check_violation';
    END IF;

    -- 2. Validate supporting KYC record
    SELECT borrower_id, status
    INTO v_kyc_borrower_id, v_kyc_status
    FROM kyc_records
    WHERE kyc_id = p_kyc_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Approval rejected: KYC record % does not exist.', p_kyc_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_kyc_borrower_id <> v_borrower_id THEN
        RAISE EXCEPTION 'Approval rejected: KYC record % belongs to borrower %, not applicant %.',
            p_kyc_id, v_kyc_borrower_id, v_borrower_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_kyc_status <> 'VERIFIED' THEN
        RAISE EXCEPTION 'Approval rejected: Supporting KYC record % is "%". Only VERIFIED KYC documents qualify for credit approval.',
            p_kyc_id, v_kyc_status
            USING ERRCODE = 'check_violation';
    END IF;

    -- 3. Validate product eligibility bounds
    SELECT min_amount, max_amount, active
    INTO v_min_amount, v_max_amount, v_product_active
    FROM loan_products
    WHERE product_id = v_product_id;

    IF NOT v_product_active THEN
        RAISE EXCEPTION 'Approval rejected: Loan product % is inactive.', v_product_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_requested_amount < v_min_amount OR v_requested_amount > v_max_amount THEN
        RAISE EXCEPTION 'Approval rejected: Requested amount (%) falls outside product limits (Min: %, Max: %).',
            v_requested_amount, v_min_amount, v_max_amount
            USING ERRCODE = 'check_violation';
    END IF;

    -- 4. Record the approval decision
    UPDATE loan_applications
    SET status = 'APPROVED',
        decided_at = CURRENT_TIMESTAMP,
        decision_reason = p_decision_reason,
        approved_kyc_id = p_kyc_id
    WHERE application_id = p_application_id;

END;
$$;

-- ------------------------------------------------------------------------------
-- PROCEDURE 2: sp_reject_application()
-- Purpose: Controlled credit underwriting rejection procedure.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_reject_application(
    p_application_id BIGINT,
    p_decision_reason TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_app_status VARCHAR(20);
BEGIN
    IF p_decision_reason IS NULL OR TRIM(p_decision_reason) = '' THEN
        RAISE EXCEPTION 'Rejection rejected: A valid decision reason is mandatory.'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT status INTO v_app_status
    FROM loan_applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rejection failed: Application % does not exist.', p_application_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_app_status <> 'SUBMITTED' THEN
        RAISE EXCEPTION 'Rejection failed: Application % is in status "%". Only SUBMITTED applications can be rejected.',
            p_application_id, v_app_status
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE loan_applications
    SET status = 'REJECTED',
        decided_at = CURRENT_TIMESTAMP,
        decision_reason = p_decision_reason,
        approved_kyc_id = NULL
    WHERE application_id = p_application_id;

END;
$$;

-- ------------------------------------------------------------------------------
-- PROCEDURE 3: sp_disburse_loan()
-- Purpose: Atomic loan creation and schedule generation.
-- Business Rules Enforced:
--  - Application must be APPROVED (SUBMITTED and REJECTED applications are rejected).
--  - Exactly one loan per application (UNIQUE constraint + pre-check).
--  - Contract terms (principal, flat_rate, term_months) are frozen as snapshots.
--  - Entire schedule generated atomically:
--      * Total interest = ROUND(principal * flat_rate, 2).
--      * Total contractual dues = principal + total_interest.
--      * Regular instalments receive rounded monthly principal and interest splits.
--      * Final instalment absorbs any kobo rounding differences to ensure mathematical precision.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_disburse_loan(
    p_application_id BIGINT,
    p_loan_reference VARCHAR(50),
    INOUT p_loan_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_app_status VARCHAR(20);
    v_principal NUMERIC(19, 2);
    v_product_id BIGINT;
    v_flat_rate NUMERIC(7, 6);
    v_term_months INT;
    
    v_total_interest NUMERIC(19, 2);
    v_monthly_principal NUMERIC(19, 2);
    v_monthly_interest NUMERIC(19, 2);
    v_inst_principal NUMERIC(19, 2);
    v_inst_interest NUMERIC(19, 2);
    v_due_date DATE;
    v_disbursed_at TIMESTAMPTZ := CURRENT_TIMESTAMP;
BEGIN
    IF p_loan_reference IS NULL OR TRIM(p_loan_reference) = '' THEN
        RAISE EXCEPTION 'Disbursement rejected: Loan reference cannot be empty.'
            USING ERRCODE = 'check_violation';
    END IF;

    -- 1. Lock and validate application
    SELECT status, requested_amount, product_id
    INTO v_app_status, v_principal, v_product_id
    FROM loan_applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Disbursement rejected: Application % does not exist.', p_application_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_app_status <> 'APPROVED' THEN
        RAISE EXCEPTION 'Disbursement rejected: Application % is in status "%". Only APPROVED applications can be disbursed.',
            p_application_id, v_app_status
            USING ERRCODE = 'check_violation';
    END IF;

    -- 2. Verify no existing loan exists for this application
    IF EXISTS (SELECT 1 FROM loans WHERE application_id = p_application_id) THEN
        RAISE EXCEPTION 'Disbursement rejected: A loan has already been disbursed for application %.', p_application_id
            USING ERRCODE = 'unique_violation';
    END IF;

    -- 3. Retrieve product terms snapshot
    SELECT flat_rate, term_months
    INTO v_flat_rate, v_term_months
    FROM loan_products
    WHERE product_id = v_product_id;

    -- 4. Insert loan record snapshot
    INSERT INTO loans (
        application_id,
        loan_reference,
        principal,
        flat_rate,
        term_months,
        disbursed_at
    ) VALUES (
        p_application_id,
        p_loan_reference,
        v_principal,
        v_flat_rate,
        v_term_months,
        v_disbursed_at
    )
    RETURNING loan_id INTO p_loan_id;

    -- 5. Calculate repayment schedule with exact rounding
    v_total_interest := ROUND(v_principal * v_flat_rate, 2);
    v_monthly_principal := ROUND(v_principal / v_term_months, 2);
    v_monthly_interest := ROUND(v_total_interest / v_term_months, 2);

    -- 6. Insert all scheduled instalments atomically
    FOR i IN 1..v_term_months LOOP
        -- Calendar due date: 1 month interval per instalment
        v_due_date := (v_disbursed_at::DATE + (i || ' month')::INTERVAL)::DATE;

        IF i < v_term_months THEN
            v_inst_principal := v_monthly_principal;
            v_inst_interest := v_monthly_interest;
        ELSE
            -- Final instalment absorbs cumulative rounding residuals
            v_inst_principal := v_principal - (v_monthly_principal * (v_term_months - 1));
            v_inst_interest := v_total_interest - (v_monthly_interest * (v_term_months - 1));
        END IF;

        INSERT INTO instalments (
            loan_id,
            instalment_no,
            due_date,
            principal_due,
            interest_due
        ) VALUES (
            p_loan_id,
            i,
            v_due_date,
            v_inst_principal,
            v_inst_interest
        );
    END LOOP;

END;
$$;

-- ------------------------------------------------------------------------------
-- PROCEDURE 4: sp_process_repayment()
-- Purpose: Concurrency-safe payment recording and waterfall allocation.
-- Concurrency & Locking Strategy:
--  - Obtains row-level exclusive lock on parent loan (SELECT ... FOR UPDATE).
--    All writers for this loan serialize on this lock, eliminating double-allocation race conditions.
-- Idempotency Strategy:
--  - Checks provider_reference and idempotency_key.
--  - If the same payment retry arrives, it returns the existing receipt without duplicate inserts.
-- Allocation Algorithm:
--  - Iterates through instalments ordered by instalment_no ASC (oldest due first).
--  - Allocates available payment cash up to the unpaid balance of each instalment.
--  - If payment exceeds remaining loan debt, the surplus remains unapplied cash (no negative debt).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_process_repayment(
    p_loan_id BIGINT,
    p_provider_reference VARCHAR(100),
    p_idempotency_key VARCHAR(100),
    p_amount NUMERIC(19, 2),
    INOUT p_repayment_id BIGINT DEFAULT NULL,
    INOUT p_allocated_total NUMERIC(19, 2) DEFAULT 0.00,
    INOUT p_unapplied_amount NUMERIC(19, 2) DEFAULT 0.00,
    INOUT p_status_message TEXT DEFAULT ''
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_locked_loan_id BIGINT;
    v_existing_id BIGINT;
    v_existing_loan BIGINT;
    v_existing_amount NUMERIC(19, 2);
    v_cash_remaining NUMERIC(19, 2);
    v_total_allocated NUMERIC(19, 2) := 0.00;
    
    r_inst RECORD;
    v_inst_allocated NUMERIC(19, 2);
    v_inst_remaining NUMERIC(19, 2);
    v_alloc_chunk NUMERIC(19, 2);
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Repayment rejected: Received amount must be strictly positive (passed %).', p_amount
            USING ERRCODE = 'check_violation';
    END IF;

    -- 1. Acquire pessimistic lock on parent loan to serialize all allocations for this loan
    SELECT loan_id INTO v_locked_loan_id
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Repayment rejected: Loan % does not exist.', p_loan_id
            USING ERRCODE = 'no_data_found';
    END IF;

    -- 2. Idempotency Check: Verify if this callback/request has already been recorded
    SELECT repayment_id, loan_id, amount
    INTO v_existing_id, v_existing_loan, v_existing_amount
    FROM repayments
    WHERE provider_reference = p_provider_reference
       OR idempotency_key = p_idempotency_key;

    IF FOUND THEN
        IF v_existing_loan = p_loan_id AND v_existing_amount = p_amount THEN
            -- Idempotent retry: Return existing allocation status gracefully
            p_repayment_id := v_existing_id;
            SELECT COALESCE(SUM(allocated_amount), 0)
            INTO p_allocated_total
            FROM repayment_allocations
            WHERE repayment_id = v_existing_id;
            
            p_unapplied_amount := p_amount - p_allocated_total;
            p_status_message := 'IDEMPOTENT_RETRY_ACKNOWLEDGED: Existing receipt returned with unchanged allocations.';
            RETURN;
        ELSE
            RAISE EXCEPTION 'Idempotency conflict: Key % or Ref % already exists with different parameters (Loan: %, Amount: %).',
                p_idempotency_key, p_provider_reference, v_existing_loan, v_existing_amount
                USING ERRCODE = 'unique_violation';
        END IF;
    END IF;

    -- 3. Record confirmed inbound repayment receipt
    INSERT INTO repayments (
        loan_id,
        provider_reference,
        idempotency_key,
        amount,
        received_at
    ) VALUES (
        p_loan_id,
        p_provider_reference,
        p_idempotency_key,
        p_amount,
        CURRENT_TIMESTAMP
    )
    RETURNING repayment_id INTO p_repayment_id;

    -- 4. Waterfall allocation across scheduled instalments (ordered by instalment_no ASC)
    v_cash_remaining := p_amount;

    FOR r_inst IN 
        SELECT 
            i.instalment_id,
            i.instalment_no,
            i.total_due,
            COALESCE(SUM(ra.allocated_amount), 0) AS total_allocated
        FROM instalments i
        LEFT JOIN repayment_allocations ra ON i.instalment_id = ra.instalment_id
        WHERE i.loan_id = p_loan_id
        GROUP BY i.instalment_id, i.instalment_no, i.total_due
        ORDER BY i.instalment_no ASC
    LOOP
        v_inst_remaining := r_inst.total_due - r_inst.total_allocated;

        IF v_inst_remaining > 0 AND v_cash_remaining > 0 THEN
            v_alloc_chunk := LEAST(v_inst_remaining, v_cash_remaining);

            INSERT INTO repayment_allocations (
                repayment_id,
                instalment_id,
                allocated_amount,
                allocated_at
            ) VALUES (
                p_repayment_id,
                r_inst.instalment_id,
                v_alloc_chunk,
                CURRENT_TIMESTAMP
            );

            v_cash_remaining := v_cash_remaining - v_alloc_chunk;
            v_total_allocated := v_total_allocated + v_alloc_chunk;
        END IF;

        EXIT WHEN v_cash_remaining <= 0;
    END LOOP;

    p_allocated_total := v_total_allocated;
    p_unapplied_amount := v_cash_remaining;

    IF p_unapplied_amount > 0 THEN
        p_status_message := 'SURPLUS_UNAPPLIED_CASH: Payment exceeds outstanding loan obligations; excess retained as unapplied cash.';
    ELSE
        p_status_message := 'SUCCESSFULLY_ALLOCATED: Payment fully allocated across scheduled instalments.';
    END IF;

END;
$$;
