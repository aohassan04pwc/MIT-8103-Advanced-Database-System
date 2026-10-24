-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT loan_id,count(*) AS receipts,sum(amount) AS total
FROM lb_bench.repayments WHERE amount>=50000
AND received_at>=timestamptz '2025-01-01 UTC' AND received_at<timestamptz '2025-02-01 UTC'
GROUP BY loan_id HAVING count(*)>=1 ORDER BY total DESC,loan_id LIMIT 20;
