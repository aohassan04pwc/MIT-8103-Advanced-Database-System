-- Reset lb_p3 only. Stop other lab sessions/stress clients before running.
-- Clears previous evidence data: export outputs before resetting.
BEGIN;
TRUNCATE lb_p3.movements,lb_p3.requests,lb_p3.allocations,
 lb_p3.repayments,lb_p3.instalments,lb_p3.loans RESTART IDENTITY;
INSERT INTO lb_p3.loans SELECT n,'LB-P3-'||n FROM generate_series(1,10) n;
INSERT INTO lb_p3.instalments
 SELECT 2*n-1,n,1000000 FROM generate_series(1,10) n
 UNION ALL SELECT 2*n,n,1000000 FROM generate_series(1,10) n;
INSERT INTO lb_p3.repayments SELECT n,n,1000000 FROM generate_series(1,10) n;
INSERT INTO lb_p3.allocations
 SELECT n,2*n-1,n,500000 FROM generate_series(1,10) n
 UNION ALL SELECT n,2*n,n,500000 FROM generate_series(1,10) n;
-- Opening movements reconcile every starting allocation; NULL request = opening.
INSERT INTO lb_p3.movements(request_id,repayment_id,instalment_id,delta)
 SELECT NULL,repayment_id,instalment_id,allocated_amount FROM lb_p3.allocations;
COMMIT;
SELECT * FROM lb_p3.allocations ORDER BY repayment_id,instalment_id;
