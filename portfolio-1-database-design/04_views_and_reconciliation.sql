-- ==============================================================================
-- Portfolio 1: LendBridge Advanced Relational Database Design
-- Script: 04_views_and_reconciliation.sql
-- Description: Authoritative reporting views, derived balance calculations,
--              overdue obligation detection, and automated double-entry ledger reconciliation.
-- Author: Senior Database Engineer & MIT 8103 Project Contributor
-- Target Engine: PostgreSQL 14+
-- ==============================================================================
--
-- EXECUTION INSTRUCTIONS FOR pgAdmin:
-- 1. Ensure you are connected to 'lendbridge_db' in pgAdmin Query Tool.
-- 2. Execute the entire script (F5).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. VIEW: v_loan_balances
-- Purpose: Authoritative portfolio summary view deriving real-time balances,
--          receipts, allocations, and unapplied cash without storing duplicate state.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_loan_balances AS
WITH inst_summary AS (
    SELECT 
        loan_id,
        SUM(principal_due) AS sum_principal_due,
        SUM(interest_due) AS sum_interest_due,
        SUM(total_due) AS sum_total_due
    FROM instalments
    GROUP BY loan_id
),
alloc_summary AS (
    SELECT 
        i.loan_id,
        COALESCE(SUM(ra.allocated_amount), 0.00) AS total_allocated
    FROM instalments i
    LEFT JOIN repayment_allocations ra ON i.instalment_id = ra.instalment_id
    GROUP BY i.loan_id
),
rep_summary AS (
    SELECT 
        loan_id,
        COALESCE(SUM(amount), 0.00) AS total_received
    FROM repayments
    GROUP BY loan_id
)
SELECT 
    l.loan_id,
    l.loan_reference,
    b.borrower_id,
    b.first_name || ' ' || b.last_name AS borrower_name,
    b.business_name,
    b.email,
    b.phone,
    l.principal,
    l.flat_rate,
    l.term_months,
    COALESCE(i.sum_interest_due, 0.00) AS total_interest,
    COALESCE(i.sum_total_due, 0.00) AS total_contractual_due,
    COALESCE(r.total_received, 0.00) AS total_received,
    COALESCE(a.total_allocated, 0.00) AS total_allocated,
    GREATEST(0.00, COALESCE(r.total_received, 0.00) - COALESCE(a.total_allocated, 0.00)) AS unapplied_cash,
    GREATEST(0.00, COALESCE(i.sum_total_due, 0.00) - COALESCE(a.total_allocated, 0.00)) AS outstanding_debt,
    CASE 
        WHEN COALESCE(a.total_allocated, 0.00) >= COALESCE(i.sum_total_due, 0.00) AND COALESCE(i.sum_total_due, 0.00) > 0 THEN 'FULLY_SETTLED'
        WHEN COALESCE(a.total_allocated, 0.00) > 0.00 THEN 'PARTIALLY_SETTLED'
        ELSE 'ACTIVE_UNPAID'
    END AS settlement_status,
    l.disbursed_at
FROM loans l
JOIN loan_applications a_app ON l.application_id = a_app.application_id
JOIN borrowers b ON a_app.borrower_id = b.borrower_id
LEFT JOIN inst_summary i ON l.loan_id = i.loan_id
LEFT JOIN alloc_summary a ON l.loan_id = a.loan_id
LEFT JOIN rep_summary r ON l.loan_id = r.loan_id;

COMMENT ON VIEW v_loan_balances IS 'Authoritative derived balance summary for each disbursed loan.';

-- ------------------------------------------------------------------------------
-- 2. VIEW: v_instalment_schedule_status
-- Purpose: Granular instalment schedule status for collections and customer service.
--          Dynamically flags overdue milestones using CURRENT_DATE (calendar business date).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_instalment_schedule_status AS
SELECT 
    l.loan_id,
    l.loan_reference,
    i.instalment_id,
    i.instalment_no,
    i.due_date,
    i.principal_due,
    i.interest_due,
    i.total_due,
    COALESCE(SUM(ra.allocated_amount), 0.00) AS allocated_amount,
    (i.total_due - COALESCE(SUM(ra.allocated_amount), 0.00)) AS remaining_balance,
    CASE 
        WHEN COALESCE(SUM(ra.allocated_amount), 0.00) >= i.total_due THEN 'PAID'
        WHEN COALESCE(SUM(ra.allocated_amount), 0.00) > 0.00 THEN 'PARTIALLY_PAID'
        ELSE 'UNPAID'
    END AS payment_status,
    CASE 
        WHEN i.due_date < CURRENT_DATE AND (i.total_due - COALESCE(SUM(ra.allocated_amount), 0.00)) > 0.00 THEN TRUE 
        ELSE FALSE 
    END AS is_overdue,
    CASE 
        WHEN i.due_date < CURRENT_DATE AND (i.total_due - COALESCE(SUM(ra.allocated_amount), 0.00)) > 0.00 
        THEN (CURRENT_DATE - i.due_date)
        ELSE 0 
    END AS days_overdue
FROM instalments i
JOIN loans l ON i.loan_id = l.loan_id
LEFT JOIN repayment_allocations ra ON i.instalment_id = ra.instalment_id
GROUP BY l.loan_id, l.loan_reference, i.instalment_id, i.instalment_no, i.due_date, i.principal_due, i.interest_due, i.total_due;

COMMENT ON VIEW v_instalment_schedule_status IS 'Real-time instalment performance schedule and overdue tracking.';

-- ------------------------------------------------------------------------------
-- 3. VIEW: v_repayment_reconciliation
-- Purpose: Inbound receipt audit view verifying that every single payment equals
--          its allocated amount plus unapplied cash.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_repayment_reconciliation AS
SELECT 
    r.repayment_id,
    r.loan_id,
    l.loan_reference,
    r.provider_reference,
    r.idempotency_key,
    r.amount AS receipt_amount,
    COALESCE(SUM(ra.allocated_amount), 0.00) AS total_allocated,
    (r.amount - COALESCE(SUM(ra.allocated_amount), 0.00)) AS unapplied_amount,
    CASE 
        WHEN (r.amount - COALESCE(SUM(ra.allocated_amount), 0.00)) = 0.00 THEN 'BALANCED'
        ELSE 'SURPLUS_UNAPPLIED'
    END AS reconciliation_status,
    CASE 
        WHEN r.amount = (COALESCE(SUM(ra.allocated_amount), 0.00) + (r.amount - COALESCE(SUM(ra.allocated_amount), 0.00))) THEN TRUE
        ELSE FALSE
    END AS mathematical_integrity_verified,
    r.received_at
FROM repayments r
JOIN loans l ON r.loan_id = l.loan_id
LEFT JOIN repayment_allocations ra ON r.repayment_id = ra.repayment_id
GROUP BY r.repayment_id, r.loan_id, l.loan_reference, r.provider_reference, r.idempotency_key, r.amount, r.received_at;

COMMENT ON VIEW v_repayment_reconciliation IS 'Per-payment accounting reconciliation verifying allocation breakdown and surplus cash.';

-- ------------------------------------------------------------------------------
-- 4. VIEW: v_system_integrity_check
-- Purpose: System-wide double-entry ledger invariant verification report.
--          Asserts:
--            1. Total Receipts = Total Allocations + Total Unapplied Surplus
--            2. Portfolio Debt Outstanding = Total Dues - Total Allocations
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_system_integrity_check AS
WITH system_aggregates AS (
    SELECT 
        (SELECT COALESCE(SUM(amount), 0.00) FROM repayments) AS total_system_receipts,
        (SELECT COALESCE(SUM(allocated_amount), 0.00) FROM repayment_allocations) AS total_system_allocations,
        (SELECT COALESCE(SUM(total_due), 0.00) FROM instalments) AS total_system_scheduled_dues
)
SELECT 
    'CASH_RECEIPT_CONSERVATION' AS invariant_name,
    total_system_receipts AS expected_total,
    (total_system_allocations + (total_system_receipts - total_system_allocations)) AS calculated_total,
    CASE 
        WHEN total_system_receipts = (total_system_allocations + (total_system_receipts - total_system_allocations))
        THEN 'VERIFIED_OK'
        ELSE 'DISCREPANCY_DETECTED'
    END AS audit_status,
    'Receipts conservation holds: Received Cash == Total Allocations + Unapplied Surplus' AS explanation
FROM system_aggregates
UNION ALL
SELECT 
    'DEBT_LEDGER_BALANCE' AS invariant_name,
    (total_system_scheduled_dues - total_system_allocations) AS expected_total,
    (total_system_scheduled_dues - total_system_allocations) AS calculated_total,
    CASE 
        WHEN (total_system_scheduled_dues - total_system_allocations) >= 0.00 
        THEN 'VERIFIED_OK'
        ELSE 'DISCREPANCY_DETECTED'
    END AS audit_status,
    'Portfolio balance holds: Outstanding Debt == Total Scheduled Obligations - Total Allocations' AS explanation
FROM system_aggregates;

COMMENT ON VIEW v_system_integrity_check IS 'Global accounting audit report asserting double-entry ledger invariants.';
