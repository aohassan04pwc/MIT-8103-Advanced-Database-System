-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT i.instalment_id,i.total_due,COALESCE(sum(a.allocated_amount),0) AS allocated
FROM lb_bench.instalments i LEFT JOIN lb_bench.repayment_allocations a USING(instalment_id)
GROUP BY i.instalment_id,i.total_due HAVING COALESCE(sum(a.allocated_amount),0)>i.total_due;
