-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT r.repayment_id,r.amount,COALESCE(sum(a.allocated_amount),0) AS allocated
FROM lb_bench.repayments r LEFT JOIN lb_bench.repayment_allocations a USING(repayment_id)
GROUP BY r.repayment_id,r.amount HAVING COALESCE(sum(a.allocated_amount),0)>r.amount;
