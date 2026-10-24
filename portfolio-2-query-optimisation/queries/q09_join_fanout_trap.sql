-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT
(SELECT sum(r.amount) FROM lb_bench.repayments r
 JOIN lb_bench.repayment_allocations a USING(repayment_id)) AS incorrect_join_total,
(SELECT sum(amount) FROM lb_bench.repayments) AS correct_receipt_total,
(SELECT sum(allocated_amount) FROM lb_bench.repayment_allocations) AS correct_allocated_total,
(SELECT sum(r.amount) FROM lb_bench.repayments r JOIN lb_bench.repayment_allocations a USING(repayment_id))
 / NULLIF((SELECT sum(amount) FROM lb_bench.repayments),0) AS fanout_ratio;
