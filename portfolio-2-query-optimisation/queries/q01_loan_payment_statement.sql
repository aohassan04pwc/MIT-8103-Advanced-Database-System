-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT r.repayment_id,r.received_at,r.amount,l.loan_reference
FROM lb_bench.repayments r JOIN lb_bench.loans l USING(loan_id)
WHERE r.loan_id=1001 ORDER BY r.received_at DESC,r.repayment_id DESC LIMIT 50;
