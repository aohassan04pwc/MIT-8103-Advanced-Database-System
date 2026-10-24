-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT version(),current_database(),current_user;
SELECT name,setting,unit FROM pg_settings WHERE name IN
('block_size','shared_buffers','work_mem','seq_page_cost','random_page_cost','cpu_tuple_cost','TimeZone');
SELECT c.relname,c.relpages,c.reltuples::bigint AS estimated_rows,
pg_size_pretty(pg_relation_size(c.oid)) AS relation_size
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='lb_bench' AND c.relkind IN ('r','i') ORDER BY pg_relation_size(c.oid) DESC;
SELECT tablename,attname,n_distinct,most_common_vals,correlation FROM pg_stats
WHERE schemaname='lb_bench' AND attname IN ('loan_id','received_at','amount');

-- Compare normal Q1 with scans discouraged, then restore settings via ROLLBACK.
BEGIN;
EXPLAIN (ANALYZE,BUFFERS)
SELECT r.repayment_id,r.received_at,r.amount,l.loan_reference
FROM lb_bench.repayments r JOIN lb_bench.loans l USING(loan_id)
WHERE r.loan_id=1001 ORDER BY r.received_at DESC,r.repayment_id DESC LIMIT 50;
SET LOCAL enable_indexscan=off;
SET LOCAL enable_indexonlyscan=off;
SET LOCAL enable_bitmapscan=off;
EXPLAIN (ANALYZE,BUFFERS)
SELECT r.repayment_id,r.received_at,r.amount,l.loan_reference
FROM lb_bench.repayments r JOIN lb_bench.loans l USING(loan_id)
WHERE r.loan_id=1001 ORDER BY r.received_at DESC,r.repayment_id DESC LIMIT 50;
ROLLBACK;
-- Selectivity experiment: same index, narrow versus broad window. No guaranteed plan.
EXPLAIN (ANALYZE,BUFFERS) SELECT * FROM lb_bench.repayments
WHERE received_at>=timestamptz '2025-01-01 UTC' AND received_at<timestamptz '2025-01-02 UTC';
EXPLAIN (ANALYZE,BUFFERS) SELECT * FROM lb_bench.repayments
WHERE received_at>=timestamptz '2024-01-01 UTC' AND received_at<timestamptz '2026-01-01 UTC';
-- A >= 60000 predicate can imply amount >= 50000, but this dataset has no matches.
-- A predicate amount >= 40000 does not imply the partial index predicate.
-- Compare index sizes. The large-receipts partial index contains EVERY benchmark receipt;
-- therefore it has no selectivity advantage here. The overlap is intentional for discussion.
SELECT indexrelname,pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE schemaname='lb_bench' ORDER BY indexrelname;
