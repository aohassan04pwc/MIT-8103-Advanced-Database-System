-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
-- Q1: loan_payment_statement
SELECT r.repayment_id,r.received_at,r.amount,l.loan_reference
FROM lb_bench.repayments r JOIN lb_bench.loans l USING(loan_id)
WHERE r.loan_id=1001 ORDER BY r.received_at DESC,r.repayment_id DESC LIMIT 50;

-- Q2: daily_receipt_totals
SELECT (received_at AT TIME ZONE 'UTC')::date AS receipt_day,count(*) AS receipts,sum(amount) AS amount
FROM lb_bench.repayments WHERE received_at >= timestamptz '2025-01-01 UTC'
AND received_at < timestamptz '2025-02-01 UTC' GROUP BY 1 ORDER BY 1;

-- Q3: borrower_largest_loans
SELECT l.loan_reference,l.principal,l.disbursed_at
FROM lb_bench.borrowers b JOIN lb_bench.loan_applications a USING(borrower_id)
JOIN lb_bench.loans l USING(application_id)
WHERE b.borrower_id=1001 ORDER BY l.principal DESC,l.loan_id LIMIT 10;

-- Q4: large_receipts
SELECT loan_id,count(*) AS receipts,sum(amount) AS total
FROM lb_bench.repayments WHERE amount>=50000
AND received_at>=timestamptz '2025-01-01 UTC' AND received_at<timestamptz '2025-02-01 UTC'
GROUP BY loan_id HAVING count(*)>=1 ORDER BY total DESC,loan_id LIMIT 20;

-- Q5: idempotency_lookup
SELECT repayment_id,loan_id,amount,received_at FROM lb_bench.repayments
WHERE idempotency_key='IDEM-1001-1';

-- Q6: receipt_allocation_audit
SELECT r.repayment_id,r.amount,COALESCE(sum(a.allocated_amount),0) AS allocated
FROM lb_bench.repayments r LEFT JOIN lb_bench.repayment_allocations a USING(repayment_id)
GROUP BY r.repayment_id,r.amount HAVING COALESCE(sum(a.allocated_amount),0)>r.amount;

-- Q7: instalment_allocation_audit
SELECT i.instalment_id,i.total_due,COALESCE(sum(a.allocated_amount),0) AS allocated
FROM lb_bench.instalments i LEFT JOIN lb_bench.repayment_allocations a USING(instalment_id)
GROUP BY i.instalment_id,i.total_due HAVING COALESCE(sum(a.allocated_amount),0)>i.total_due;

-- Q8: monthly_cash_position
SELECT date_trunc('month',received_at AT TIME ZONE 'UTC') AS month,
count(*) FILTER (WHERE amount>=50000) AS large_receipts,sum(amount) AS cash_received
FROM lb_bench.repayments WHERE received_at>=timestamptz '2024-10-01 UTC'
AND received_at<timestamptz '2025-04-01 UTC' GROUP BY 1 ORDER BY 1;

-- Q9: join_fanout_trap
SELECT
(SELECT sum(r.amount) FROM lb_bench.repayments r
 JOIN lb_bench.repayment_allocations a USING(repayment_id)) AS incorrect_join_total,
(SELECT sum(amount) FROM lb_bench.repayments) AS correct_receipt_total,
(SELECT sum(allocated_amount) FROM lb_bench.repayment_allocations) AS correct_allocated_total,
(SELECT sum(r.amount) FROM lb_bench.repayments r JOIN lb_bench.repayment_allocations a USING(repayment_id))
 / NULLIF((SELECT sum(amount) FROM lb_bench.repayments),0) AS fanout_ratio;
