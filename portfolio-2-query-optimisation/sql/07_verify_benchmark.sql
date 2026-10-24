-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
-- Expected: 5000, 5000, 1, 50000, 50000, 300000, 200000, 400000 rows.
SELECT 'borrowers' AS table_name,count(*) AS rows FROM lb_bench.borrowers
UNION ALL SELECT 'kyc_records',count(*) FROM lb_bench.kyc_records
UNION ALL SELECT 'loan_products',count(*) FROM lb_bench.loan_products
UNION ALL SELECT 'loan_applications',count(*) FROM lb_bench.loan_applications
UNION ALL SELECT 'loans',count(*) FROM lb_bench.loans
UNION ALL SELECT 'instalments',count(*) FROM lb_bench.instalments
UNION ALL SELECT 'repayments',count(*) FROM lb_bench.repayments
UNION ALL SELECT 'repayment_allocations',count(*) FROM lb_bench.repayment_allocations;
-- Expected mismatch counts all zero.
SELECT 'cross-loan allocations' AS check_name,count(*) AS mismatches
FROM lb_bench.repayment_allocations a JOIN lb_bench.repayments r USING(repayment_id)
JOIN lb_bench.instalments i USING(instalment_id) WHERE r.loan_id<>i.loan_id
UNION ALL SELECT 'invalid approved KYC',count(*) FROM lb_bench.loan_applications a
JOIN lb_bench.kyc_records k ON k.kyc_id=a.approved_kyc_id
WHERE k.borrower_id<>a.borrower_id OR k.status<>'VERIFIED';
