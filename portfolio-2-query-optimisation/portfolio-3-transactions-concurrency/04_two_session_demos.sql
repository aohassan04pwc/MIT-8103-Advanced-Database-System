-- INSTRUCTIONS: execute only the labelled block, in its specified session.
-- Open two independent pgAdmin Query Tool connections; verify different PIDs.
SELECT pg_backend_pid(),current_database(),current_setting('transaction_isolation');

-- A. READ COMMITTED visibility. Reset first; then Session A:
BEGIN;
SELECT lb_p3.reallocate_payment(1,1,2,100,'visibility-a');
-- Leave uncommitted. Session B runs this: still 500000 / 500000.
SELECT * FROM lb_p3.allocations WHERE repayment_id=1 ORDER BY instalment_id;
-- Session A:
COMMIT;
-- Session B repeats SELECT: now 499900 / 500100.

-- B. Concurrent same-key retry. Reset first. Session A:
BEGIN;
SELECT lb_p3.reallocate_payment(1,1,2,25,'concurrent-same-key');
-- Session B (blocks until A commits):
SELECT lb_p3.reallocate_payment(1,1,2,25,'concurrent-same-key');
-- Session A: COMMIT; Then B returns the SAME request id.
-- Verify one request and two movement rows for that request.

-- C. Ordered locking waits. Reset first. Session A:
BEGIN;
SELECT lb_p3.reallocate_payment(1,1,2,10,'ordered-a');
-- Session B: waits while A holds locks.
SELECT lb_p3.reallocate_payment(1,2,1,10,'ordered-b');
-- Session A: COMMIT; B can finish. Final allocations are 500000 each.

-- D. Deliberate deadlock, deterministic manual lock order. Reset first.
-- Session A, execute:
BEGIN;
SELECT 1 FROM lb_p3.instalments WHERE instalment_id=1 FOR UPDATE;
-- Session B, execute:
BEGIN;
SELECT 1 FROM lb_p3.instalments WHERE instalment_id=2 FOR UPDATE;
-- Session A, execute (waits):
SELECT 1 FROM lb_p3.instalments WHERE instalment_id=2 FOR UPDATE;
-- Session B, execute (closes cycle):
SELECT 1 FROM lb_p3.instalments WHERE instalment_id=1 FOR UPDATE;
-- One session receives SQLSTATE 40P01; victim is not predetermined.
-- Run ROLLBACK in BOTH tabs after observing the error.

-- Observer: use a THIRD independent tab while a session is blocked.
SELECT pid,application_name,state,wait_event_type,wait_event,
 pg_blocking_pids(pid) AS blockers,query
FROM pg_stat_activity
WHERE datname=current_database() AND pid<>pg_backend_pid();
