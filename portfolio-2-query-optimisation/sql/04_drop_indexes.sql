-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
-- Remove only Portfolio 2 experimental indexes. Keep primary/unique indexes.
DROP INDEX IF EXISTS lb_bench.p2_receipts_loan_time;
DROP INDEX IF EXISTS lb_bench.p2_applications_borrower;
DROP INDEX IF EXISTS lb_bench.p2_receipts_time_cover;
DROP INDEX IF EXISTS lb_bench.p2_large_receipts_time;
DROP INDEX IF EXISTS lb_bench.p2_allocations_instalment;
