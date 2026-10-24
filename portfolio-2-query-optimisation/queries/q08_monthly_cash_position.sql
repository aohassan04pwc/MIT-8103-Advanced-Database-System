-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT date_trunc('month',received_at AT TIME ZONE 'UTC') AS month,
count(*) FILTER (WHERE amount>=50000) AS large_receipts,sum(amount) AS cash_received
FROM lb_bench.repayments WHERE received_at>=timestamptz '2024-10-01 UTC'
AND received_at<timestamptz '2025-04-01 UTC' GROUP BY 1 ORDER BY 1;
