-- Run complete file once after reset. Expected errors are caught in subtransactions.
CREATE TEMP TABLE IF NOT EXISTS p3_demo_results(
 test text, passed boolean, detail text
);
TRUNCATE p3_demo_results;
COMMIT; -- Separate setup from the demonstration transaction.
-- COMMIT
BEGIN;
SELECT lb_p3.reallocate_payment(1,1,2,100,'demo-commit');
COMMIT;
INSERT INTO p3_demo_results SELECT 'COMMIT',
 (SELECT allocated_amount=499900 FROM lb_p3.allocations WHERE repayment_id=1 AND instalment_id=1),
 '100 moved from instalment 1 to 2';
COMMIT; -- Preserve evidence before the next demonstration rolls back.
-- ROLLBACK
BEGIN;
SELECT lb_p3.reallocate_payment(1,1,2,50,'demo-rollback');
ROLLBACK;
INSERT INTO p3_demo_results SELECT 'ROLLBACK',
 NOT EXISTS(SELECT 1 FROM lb_p3.requests WHERE idempotency_key='demo-rollback')
 AND (SELECT allocated_amount=499900 FROM lb_p3.allocations WHERE repayment_id=1 AND instalment_id=1),
 'Request and allocation changes undone';
-- Failure occurs after request registration: exception subtransaction undoes it.
DO $$ BEGIN
 BEGIN
  PERFORM lb_p3.reallocate_payment(1,1,2,9999999,'demo-failure');
  RAISE EXCEPTION 'TEST_DID_NOT_FAIL';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'INSUFFICIENT_ALLOCATION' THEN RAISE; END IF;
 END;
END $$;
INSERT INTO p3_demo_results SELECT 'FAILURE_ATOMICITY',
 NOT EXISTS(SELECT 1 FROM lb_p3.requests WHERE idempotency_key='demo-failure')
 AND (SELECT allocated_amount=499900 FROM lb_p3.allocations WHERE repayment_id=1 AND instalment_id=1),
 'Failed operation leaves no request or allocation change';
-- IDEMPOTENCY
DO $$ DECLARE a bigint; b bigint; BEGIN
 a:=lb_p3.reallocate_payment(1,1,2,25,'demo-idem');
 b:=lb_p3.reallocate_payment(1,1,2,25,'demo-idem');
 INSERT INTO p3_demo_results VALUES('IDEMPOTENCY',a=b,'Identical retry returns same request id');
END $$;
INSERT INTO p3_demo_results SELECT 'APPLIED_ONCE',
 (SELECT allocated_amount=499875 FROM lb_p3.allocations WHERE repayment_id=1 AND instalment_id=1)
 AND (SELECT count(*)=1 FROM lb_p3.requests WHERE idempotency_key='demo-idem'),
 'Two calls moved only 25';
DO $$ BEGIN
 BEGIN
  PERFORM lb_p3.reallocate_payment(1,1,2,26,'demo-idem');
  RAISE EXCEPTION 'TEST_DID_NOT_FAIL';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD' THEN RAISE; END IF;
 END;
 INSERT INTO p3_demo_results VALUES('KEY_PAYLOAD_CHECK',true,'Changed amount rejected');
END $$;
COMMIT; -- Finish the evidence/idempotency transaction before SAVEPOINT demo.
-- SAVEPOINT: discard valid second step while preserving the first.
BEGIN;
SELECT lb_p3.reallocate_payment(1,1,2,10,'demo-sp-first');
SAVEPOINT second_step;
SELECT lb_p3.reallocate_payment(1,1,2,20,'demo-sp-second');
ROLLBACK TO SAVEPOINT second_step;
COMMIT;
INSERT INTO p3_demo_results SELECT 'SAVEPOINT',
 EXISTS(SELECT 1 FROM lb_p3.requests WHERE idempotency_key='demo-sp-first')
 AND NOT EXISTS(SELECT 1 FROM lb_p3.requests WHERE idempotency_key='demo-sp-second')
 AND (SELECT allocated_amount=499865 FROM lb_p3.allocations WHERE repayment_id=1 AND instalment_id=1),
 'First 10 retained; second 20 undone';
COMMIT; -- Preserve final evidence independently of subsequent work.
SELECT * FROM p3_demo_results ORDER BY test;
