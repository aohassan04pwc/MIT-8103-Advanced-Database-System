-- LendBridge Portfolio 2. PostgreSQL 14+. Run in pgAdmin connected to lendbridge_db.
-- Benchmark objects are explicitly qualified as lb_bench; public is not modified.
SELECT l.loan_reference,l.principal,l.disbursed_at
FROM lb_bench.borrowers b JOIN lb_bench.loan_applications a USING(borrower_id)
JOIN lb_bench.loans l USING(application_id)
WHERE b.borrower_id=1001 ORDER BY l.principal DESC,l.loan_id LIMIT 10;
