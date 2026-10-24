-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT (received_at AT TIME ZONE 'UTC')::date AS receipt_day,count(*) AS receipts,sum(amount) AS amount
FROM lb_bench.repayments WHERE received_at >= timestamptz '2025-01-01 UTC'
AND received_at < timestamptz '2025-02-01 UTC' GROUP BY 1 ORDER BY 1;
