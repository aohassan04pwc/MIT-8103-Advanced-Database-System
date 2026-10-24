-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
BEGIN;
CREATE INDEX IF NOT EXISTS p2_receipts_loan_time ON lb_bench.repayments (loan_id,received_at DESC,repayment_id DESC);
CREATE INDEX IF NOT EXISTS p2_applications_borrower ON lb_bench.loan_applications (borrower_id,application_id);
CREATE INDEX IF NOT EXISTS p2_receipts_time_cover ON lb_bench.repayments (received_at) INCLUDE (amount,loan_id);
CREATE INDEX IF NOT EXISTS p2_large_receipts_time ON lb_bench.repayments (received_at) INCLUDE (loan_id,amount) WHERE amount>=50000;
CREATE INDEX IF NOT EXISTS p2_allocations_instalment ON lb_bench.repayment_allocations (instalment_id) INCLUDE (allocated_amount);
COMMIT;
ANALYZE lb_bench.repayments;
ANALYZE lb_bench.loan_applications;
ANALYZE lb_bench.repayment_allocations;
SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='lb_bench' ORDER BY indexname;
