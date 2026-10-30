-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT repayment_id,loan_id,amount,received_at FROM lb_bench.repayments
WHERE idempotency_key='IDEM-1001-1';
