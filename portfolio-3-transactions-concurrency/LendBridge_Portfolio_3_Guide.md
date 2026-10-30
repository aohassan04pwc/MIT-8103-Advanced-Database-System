# MIT 8103 Portfolio 3 — LendBridge Transactions and Concurrency

## Purpose and adaptation

This is LendBridge's companion reference and execution guide, adapted from the supplied NairaPay Portfolio 3 reference files. NairaPay transfers wallet balances; LendBridge corrects the allocation of an existing repayment between two instalments of the **same loan**. The operation does not collect new cash, change the repayment amount or move funds between borrowers. It changes the servicing allocation and records equal negative/positive movements for an audit trail. These movements form a servicing subledger, not a complete general ledger or a claim of full accounting double-entry compliance.

The exercise demonstrates atomicity, COMMIT, ROLLBACK, SAVEPOINT, idempotency, concurrent retries, row locking, deadlocks, stress testing and reconciliation. It uses a dedicated `lb_p3` schema in `lendbridge_db`, leaving `public` and `lb_bench` unchanged. The lab is a simplified extension of the Portfolio 1 lending concepts; its functions are not replacements for Portfolio 1 procedures and are not production deployment scripts.

**Status:** core lab tests executed on 24–25 October 2026. See `analysis.md` for the observed results and evidence limitations. The transaction-demo script was subsequently corrected for evidence persistence; this revised file has been statically reviewed but not rerun.

## Folder and tools

Create `portfolio-3-transactions-concurrency` alongside your Portfolio 1 and 2 folders. Inside it, create `output` and `screenshots`. Save each code block below to the indicated filename using Antigravity or another plain-text editor. Copy only the code inside the fence. Save this document as `LendBridge_Portfolio_3_Guide.md` in that folder.

Use pgAdmin for `.sql` files. Use two **independent Query Tool connections** for concurrency demonstrations. Verify distinct `pg_backend_pid()` values. Use Windows PowerShell for pgbench commands; `.pgbench` files are workload inputs and are not SQL to paste into pgAdmin.

## Mapping to the supplied sample

| Sample component | LendBridge version |
|---|---|
| A: safe transfer and deliberately unordered twin | 01_reallocation_function.sql |
| B: demo wallets and reset | 00_lab_setup.sql and 02_demo_setup.sql |
| C: commit/rollback/failure/idempotency/savepoint | 03_commit_rollback_demo.sql |
| Locking demonstrations described by the sample | 04_two_session_demos.sql; explicitly supplied here |
| D and E: ordered/unordered stress workloads | 05 and 06 .pgbench files |
| F: integrity check | 07_integrity_check.sql |

## Execution sequence: batch routine work, separate concurrency steps

1. In pgAdmin connected to `lendbridge_db`, run 00 once, then 01, then 02. File 00 intentionally fails if the schema exists: use 02 to reset fixture data instead of deleting other portfolios.
2. Run all of 03 once. Export its final seven-row PASS/FAIL table as `output/03_transaction_results.csv`. Every `passed` value should be true. The file assumes a fresh reset; reset before repeating it.
3. Run 04 in labelled session blocks. Do not execute the whole file at once. Export or screenshot the visibility, blocking, concurrent-key and deadlock evidence. Finish open transactions with COMMIT or ROLLBACK before a reset.
4. Reset with 02, export 07 as `output/ordered_before.csv`, run ordered pgbench, then export 07 as `output/ordered_after.csv`.
5. After saving that evidence, reset with 02, export 07 as `output/unordered_before.csv`, run unordered pgbench, then export 07 as `output/unordered_after.csv`.
6. Complete the analysis template near the end of this document and upload the finished folder to the existing GitHub repository.

**Reset changes only lab data but deletes prior lab request/movement history. Stop the clients and save evidence first. Never reset during a test.**

## Design decisions and boundaries

- Ten synthetic loans each have one ₦1,000,000 repayment, allocated ₦500,000 to each of two instalments; each instalment has ₦1,000,000 due. Opening movements reconcile all initial allocations. Totals begin at ₦10,000,000 for both repayments and allocations.
- Each reallocation subtracts from one allocation and adds the same amount to the other. It also inserts two signed movements and completes one request, all in the caller's transaction.
- The safe function locks both instalments in ascending id order, then the receipt. Amounts and destination capacity are validated after locking. All other writers must use the same hierarchy; ordered locking here does not guarantee the absence of every possible deadlock in a larger application or multi-call transaction.
- The function uses FOR NO KEY UPDATE because it changes allocation amounts, not referenced key values. This lock mode is compatible with the KEY SHARE locks taken by foreign-key validation; using FOR UPDATE here can introduce lock-upgrade deadlocks even when instalment ids are ordered.
- A UNIQUE idempotency key registers the request. An identical retry returns the original completed id; a changed payload is rejected. At READ COMMITTED, a concurrent conflicting insert waits and the following statement can observe the committed result. Higher isolation levels can require retrying the entire transaction on SQLSTATE 40001.
- A failed SQL statement is rolled back atomically. Inside an explicit transaction, an unhandled error leaves the transaction aborted until ROLLBACK or recovery to a prior savepoint. File 03 catches deliberate failures in PL/pgSQL subtransactions so its tests can run in one batch; its separate SAVEPOINT example uses a successful second step for easy pgAdmin execution.
- Constraints prevent invalid keys and cross-loan allocation rows. Aggregate capacity and audit relationships depend on the function and integrity check; direct DML can bypass those rules. A production implementation needs restricted table privileges, a controlled execution interface, authorisation and audit retention. This lab uses invoker rights and does not grant production roles.
- The unordered twin shares validation logic but intentionally changes lock order and inserts a 10 ms delay. It is a fault demonstration. Do not expose it as an approved application operation.

## FILE: `00_lab_setup.sql`

```sql
-- Run once in pgAdmin connected to lendbridge_db.
-- Deliberately fails if lb_p3 already exists; reset data with 02_demo_setup.sql.
BEGIN;
CREATE SCHEMA lb_p3;
CREATE TABLE lb_p3.loans (
 loan_id bigint PRIMARY KEY, loan_reference text UNIQUE NOT NULL
);
CREATE TABLE lb_p3.instalments (
 instalment_id bigint PRIMARY KEY,
 loan_id bigint NOT NULL REFERENCES lb_p3.loans,
 total_due numeric(19,2) NOT NULL CHECK(total_due > 0),
 UNIQUE(instalment_id,loan_id)
);
CREATE TABLE lb_p3.repayments (
 repayment_id bigint PRIMARY KEY,
 loan_id bigint NOT NULL REFERENCES lb_p3.loans,
 amount numeric(19,2) NOT NULL CHECK(amount > 0),
 UNIQUE(repayment_id,loan_id)
);
CREATE TABLE lb_p3.allocations (
 repayment_id bigint NOT NULL,
 instalment_id bigint NOT NULL,
 loan_id bigint NOT NULL,
 allocated_amount numeric(19,2) NOT NULL CHECK(allocated_amount >= 0),
 PRIMARY KEY(repayment_id,instalment_id),
 FOREIGN KEY(repayment_id,loan_id) REFERENCES lb_p3.repayments(repayment_id,loan_id),
 FOREIGN KEY(instalment_id,loan_id) REFERENCES lb_p3.instalments(instalment_id,loan_id)
);
CREATE TABLE lb_p3.requests (
 request_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 idempotency_key text UNIQUE NOT NULL CHECK(btrim(idempotency_key) <> ''),
 repayment_id bigint NOT NULL REFERENCES lb_p3.repayments,
 from_instalment bigint NOT NULL REFERENCES lb_p3.instalments(instalment_id),
 to_instalment bigint NOT NULL REFERENCES lb_p3.instalments(instalment_id),
 amount numeric(19,2) NOT NULL CHECK(amount > 0),
 status text NOT NULL CHECK(status IN ('PENDING','COMPLETED')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(from_instalment <> to_instalment)
);
CREATE TABLE lb_p3.movements (
 movement_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 request_id bigint REFERENCES lb_p3.requests,
 repayment_id bigint NOT NULL,
 instalment_id bigint NOT NULL,
 delta numeric(19,2) NOT NULL CHECK(delta <> 0),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(repayment_id,instalment_id)
 REFERENCES lb_p3.allocations(repayment_id,instalment_id),
 UNIQUE(request_id,instalment_id)
);
COMMIT;
```

## FILE: `01_reallocation_function.sql`

```sql
-- Functions do not COMMIT: the caller controls the transaction.
-- Internal helper's unordered mode is deliberately flawed for demonstration.
CREATE OR REPLACE FUNCTION lb_p3.reallocate_internal(
 p_receipt bigint, p_from bigint, p_to bigint, p_amount numeric,
 p_key text, p_ordered boolean
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
 v_id bigint; v_existing lb_p3.requests%ROWTYPE;
 v_loan bigint; v_from_loan bigint; v_to_loan bigint;
 v_available numeric; v_to_due numeric; v_to_total numeric;
 v_first bigint; v_second bigint;
BEGIN
 IF p_receipt IS NULL OR p_from IS NULL OR p_to IS NULL
    OR p_from = p_to THEN RAISE EXCEPTION 'INVALID_IDENTIFIERS'; END IF;
 IF p_amount IS NULL OR p_amount::text IN ('NaN','Infinity','-Infinity') THEN
  RAISE EXCEPTION 'INVALID_AMOUNT';
 END IF;
 IF p_amount <= 0 OR p_amount <> round(p_amount,2)
    OR p_amount > 99999999999999999.99 THEN
  RAISE EXCEPTION 'INVALID_AMOUNT: positive two-decimal amount required';
 END IF;
 IF p_key IS NULL OR btrim(p_key) = '' THEN
  RAISE EXCEPTION 'INVALID_KEY';
 END IF;
 INSERT INTO lb_p3.requests(idempotency_key,repayment_id,
   from_instalment,to_instalment,amount,status)
 VALUES(p_key,p_receipt,p_from,p_to,p_amount,'PENDING')
 ON CONFLICT(idempotency_key) DO NOTHING RETURNING request_id INTO v_id;
 IF v_id IS NULL THEN
  SELECT * INTO v_existing FROM lb_p3.requests WHERE idempotency_key=p_key;
  IF NOT FOUND THEN
   RAISE EXCEPTION 'RETRY_TRANSACTION' USING ERRCODE='40001';
  END IF;
  IF v_existing.repayment_id IS DISTINCT FROM p_receipt
    OR v_existing.from_instalment IS DISTINCT FROM p_from
    OR v_existing.to_instalment IS DISTINCT FROM p_to
    OR v_existing.amount IS DISTINCT FROM p_amount THEN
   RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  END IF;
  IF v_existing.status <> 'COMPLETED' THEN
   RAISE EXCEPTION 'INCOMPLETE_REQUEST';
  END IF;
  RETURN v_existing.request_id;
 END IF;
 -- Ordered mode always locks the smaller instalment id first.
 -- Unordered mode locks the source first, then waits to widen the race window.
 v_first := CASE WHEN p_ordered THEN LEAST(p_from,p_to) ELSE p_from END;
 v_second := CASE WHEN p_ordered THEN GREATEST(p_from,p_to) ELSE p_to END;
 PERFORM 1 FROM lb_p3.instalments WHERE instalment_id=v_first FOR NO KEY UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INSTALMENT_NOT_FOUND'; END IF;
 IF NOT p_ordered THEN PERFORM pg_sleep(0.01); END IF;
 PERFORM 1 FROM lb_p3.instalments WHERE instalment_id=v_second FOR NO KEY UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INSTALMENT_NOT_FOUND'; END IF;
 -- Lock receipt after instalments; every writer must follow this hierarchy.
 SELECT loan_id INTO v_loan FROM lb_p3.repayments
 WHERE repayment_id=p_receipt FOR NO KEY UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'REPAYMENT_NOT_FOUND'; END IF;
 SELECT loan_id INTO v_from_loan FROM lb_p3.instalments WHERE instalment_id=p_from;
 SELECT loan_id,total_due INTO v_to_loan,v_to_due
 FROM lb_p3.instalments WHERE instalment_id=p_to;
 IF v_loan <> v_from_loan OR v_loan <> v_to_loan THEN
  RAISE EXCEPTION 'CROSS_LOAN_REALLOCATION_NOT_ALLOWED';
 END IF;
 SELECT allocated_amount INTO v_available FROM lb_p3.allocations
 WHERE repayment_id=p_receipt AND instalment_id=p_from;
 IF NOT FOUND OR v_available < p_amount THEN
  RAISE EXCEPTION 'INSUFFICIENT_ALLOCATION';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM lb_p3.allocations
 WHERE repayment_id=p_receipt AND instalment_id=p_to) THEN
  RAISE EXCEPTION 'DESTINATION_ALLOCATION_NOT_FOUND';
 END IF;
 SELECT COALESCE(sum(allocated_amount),0) INTO v_to_total
 FROM lb_p3.allocations WHERE instalment_id=p_to;
 IF v_to_total + p_amount > v_to_due THEN
  RAISE EXCEPTION 'DESTINATION_OVERALLOCATION';
 END IF;
 UPDATE lb_p3.allocations SET allocated_amount=allocated_amount-p_amount
 WHERE repayment_id=p_receipt AND instalment_id=p_from;
 UPDATE lb_p3.allocations SET allocated_amount=allocated_amount+p_amount
 WHERE repayment_id=p_receipt AND instalment_id=p_to;
 INSERT INTO lb_p3.movements(request_id,repayment_id,instalment_id,delta)
 VALUES(v_id,p_receipt,p_from,-p_amount),(v_id,p_receipt,p_to,p_amount);
 UPDATE lb_p3.requests SET status='COMPLETED' WHERE request_id=v_id;
 RETURN v_id;
END;
$$;
CREATE OR REPLACE FUNCTION lb_p3.reallocate_payment(
 p_receipt bigint,p_from bigint,p_to bigint,p_amount numeric,p_key text
) RETURNS bigint LANGUAGE sql AS $$
 SELECT lb_p3.reallocate_internal($1,$2,$3,$4,$5,true);
$$;
CREATE OR REPLACE FUNCTION lb_p3.reallocate_payment_unordered(
 p_receipt bigint,p_from bigint,p_to bigint,p_amount numeric,p_key text
) RETURNS bigint LANGUAGE sql AS $$
 SELECT lb_p3.reallocate_internal($1,$2,$3,$4,$5,false);
$$;
```

## FILE: `02_demo_setup.sql`

```sql
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
```

## FILE: `03_commit_rollback_demo.sql`

```sql
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
```

## FILE: `04_two_session_demos.sql`

```sql
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
```

## FILE: `05_stress_ordered.pgbench`

```text
\set loan random(1,10)
\set direction random(0,1)
\set cents random(1,100)
\set src 2 * :loan - 1 + :direction
\set dst 2 * :loan - :direction
SELECT lb_p3.reallocate_payment(:loan,:src,:dst,:cents::numeric/100,
 'pgb-ordered-'||gen_random_uuid()::text);
```

## FILE: `06_stress_unordered.pgbench`

```text
\set loan random(1,10)
\set direction random(0,1)
\set cents random(1,100)
\set src 2 * :loan - 1 + :direction
\set dst 2 * :loan - :direction
SELECT lb_p3.reallocate_payment_unordered(:loan,:src,:dst,:cents::numeric/100,
 'pgb-unordered-'||gen_random_uuid()::text);
```

## FILE: `07_integrity_check.sql`

```sql
-- One statement gives one READ COMMITTED snapshot. Run with stress clients stopped.
WITH receipt_totals AS (
 SELECT r.repayment_id,r.amount,COALESCE(sum(a.allocated_amount),0) allocated
 FROM lb_p3.repayments r LEFT JOIN lb_p3.allocations a USING(repayment_id)
 GROUP BY r.repayment_id,r.amount
), instalment_totals AS (
 SELECT i.instalment_id,i.total_due,COALESCE(sum(a.allocated_amount),0) allocated
 FROM lb_p3.instalments i LEFT JOIN lb_p3.allocations a USING(instalment_id)
 GROUP BY i.instalment_id,i.total_due
), movement_totals AS (
 SELECT a.repayment_id,a.instalment_id,a.allocated_amount,COALESCE(sum(m.delta),0) ledger
 FROM lb_p3.allocations a LEFT JOIN lb_p3.movements m
 USING(repayment_id,instalment_id)
 GROUP BY a.repayment_id,a.instalment_id,a.allocated_amount
), request_lines AS (
 SELECT r.request_id,r.status,r.repayment_id,r.from_instalment,r.to_instalment,r.amount,
 count(m.movement_id) lines,COALESCE(sum(m.delta),0) net,
 count(*) FILTER(WHERE m.repayment_id=r.repayment_id
 AND m.instalment_id=r.from_instalment AND m.delta=-r.amount) source_lines,
 count(*) FILTER(WHERE m.repayment_id=r.repayment_id
 AND m.instalment_id=r.to_instalment AND m.delta=r.amount) destination_lines
 FROM lb_p3.requests r LEFT JOIN lb_p3.movements m USING(request_id)
 GROUP BY r.request_id
)
SELECT 'total_receipts' AS metric,sum(amount)::numeric AS value FROM lb_p3.repayments
UNION ALL SELECT 'total_allocated',sum(allocated_amount) FROM lb_p3.allocations
UNION ALL SELECT 'receipt_total_mismatches',count(*) FROM receipt_totals WHERE amount<>allocated
UNION ALL SELECT 'overallocated_instalments',count(*) FROM instalment_totals WHERE allocated>total_due
UNION ALL SELECT 'allocation_ledger_mismatches',count(*) FROM movement_totals WHERE allocated_amount<>ledger
UNION ALL SELECT 'incomplete_or_invalid_requests',count(*) FROM request_lines
 WHERE status<>'COMPLETED' OR lines<>2 OR net<>0 OR source_lines<>1 OR destination_lines<>1
UNION ALL SELECT 'negative_allocations',count(*) FROM lb_p3.allocations WHERE allocated_amount<0
UNION ALL SELECT 'stress_requests',count(*) FROM lb_p3.requests WHERE idempotency_key LIKE 'pgb-%'
UNION ALL SELECT 'stress_movements',count(*) FROM lb_p3.movements m JOIN lb_p3.requests r USING(request_id)
 WHERE r.idempotency_key LIKE 'pgb-%'
ORDER BY metric;
```

## Running the stress tests on Windows

Open PowerShell in `portfolio-3-transactions-concurrency` (File Explorer address bar: type `powershell`, Enter). The commands below use the PostgreSQL 18 executable location; adjust only if your installation differs. Create `output` first. Authenticate at the prompt; do not put a password in the command or evidence file. **Do not run pgbench -i**: the custom workload needs no standard pgbench tables.

Confirm the tool exists:

```powershell
& "C:\Program Files\PostgreSQL\18\bin\pgbench.exe" --version
```

After the ordered reset and before-integrity export, run:

```powershell
& "C:\Program Files\PostgreSQL\18\bin\pgbench.exe" -h localhost -p 5432 -U postgres -d lendbridge_db -n -c 8 -j 2 -T 30 -P 5 -r --max-tries=1 --failures-detailed -f .\05_stress_ordered.pgbench 2>&1 | Tee-Object -FilePath .\output\05_ordered_stress.txt
```

Wait until it ends; run/export integrity. Save outputs, reset and capture before-integrity, then run:

```powershell
& "C:\Program Files\PostgreSQL\18\bin\pgbench.exe" -h localhost -p 5432 -U postgres -d lendbridge_db -n -c 8 -j 2 -T 30 -P 5 -r --max-tries=1 --failures-detailed -f .\06_stress_unordered.pgbench 2>&1 | Tee-Object -FilePath .\output\06_unordered_stress.txt
```

Both workloads choose a receipt/loan and the direction between its two instalments, moving ₦0.01–₦1.00 per operation. They use distinct random keys. The initial allocation cushion reduces the risk of exhausting a source; an unexpected business-rule error must still be investigated, not counted as a deadlock. Runs use no automatic retries so deadlock failures remain visible. An optional later retry experiment can use --max-tries=3 and a separate filename, but is not needed for the core deliverables.

The unordered test is likely to show deadlocks under contention but scheduling does not guarantee a particular count. The manual cycle in file 04 provides explicit deadlock evidence. Its artificial delay also affects latency/TPS, so do not attribute the full performance difference to deadlocks. Use the same client/thread/duration settings and report failures alongside throughput. Repeat both variants from reset only if the marking rubric calls for repeatability statistics or a result needs investigation; label each run separately.

## Expected evidence and reconciliation

| Evidence | Expected observation |
|---|---|
| 03_transaction_results.csv | Seven rows, all passed=true |
| COMMIT/ROLLBACK | Kept request persists; rolled-back request is absent |
| Same-key concurrent retry | One completed request, two movements, one net application |
| Changed key payload | Explicit rejection; previous completed request unchanged |
| READ COMMITTED visibility | Session B sees committed allocation values, then new values after A commits |
| Ordered lock test | B waits; after A commits both operations can complete |
| Deliberate lock cycle | One victim receives deadlock error 40P01; roll back both sessions |
| Ordered/unordered integrity totals | total_receipts=10000000; total_allocated=10000000 |
| Five problem metrics | Zero receipt mismatches, overallocated instalments, ledger mismatches, invalid requests and negative allocations |
| Stress counts | stress_movements = 2 × stress_requests for committed requests |

A zero-sum reallocation preserves allocated cash; it does not prove a bank's external cash position. Opening movements are included in allocation reconciliation but excluded from stress movement counts. Identity sequence gaps after rollback are normal; do not treat them as missing committed requests. clock_timestamp records wall-clock event times, not a guaranteed global commit order.

Run the integrity check with clients stopped and no pending lab transactions. Its single statement checks one snapshot. A missing or incomplete request, incorrect line count, wrong signed movement, cross-loan mapping or mismatch requires investigation before claiming success.

## Analysis template: complete after execution

### Environment and method

Record PostgreSQL/pgbench versions, database, Windows version, CPU/RAM if available, test date/time, READ COMMITTED isolation, eight clients, two threads, 30-second duration and retry setting. State whether other workloads were running. Distinguish expected outcomes in this guide from actual saved outputs.

### Transaction outcomes

Explain the COMMIT, ROLLBACK, failure, idempotency and SAVEPOINT results using the exported seven-row table. Describe what the other session could see before and after commit. Explain why validating balances before acquiring locks could lead to stale decisions.

### Concurrency and stress comparison

| Metric | Ordered test: measured | Unordered test: measured |
|---|---|---|
| Successful transactions | Fill from output | Fill from output |
| Failed transactions | Fill from output | Fill from output |
| Deadlock failures | Fill from output | Fill from output |
| Average successful latency (ms) | Fill from output | Fill from output |
| Transactions per second | Fill from output | Fill from output |
| Integrity checks | Fill from CSV | Fill from CSV |

Explain the observed wait cycle and which session became a victim. Do not assert that ordered locking eliminates all deadlocks across every application pathway. Discuss whole-transaction retries with bounded attempts/backoff and a stable client idempotency key; production retry keys must identify a logical request across network retries. pgbench's random key workload tests independent operations, while the two-session test covers duplicate logical requests.

### Limitations and reflection

This is a small synthetic allocation-correction lab, not a load test of Portfolio 1 production procedures, a new-payment collection workflow or an external payment gateway. It does not test authorisation, recovery from server crashes, distributed transactions or accounting integration. The unordered sleep intentionally exaggerates contention. Add your own short reflection on the most useful observed failure and how you would extend the tests.

## Submission checklist

- This guide plus SQL files 00–04 and 07, and pgbench files 05–06.
- Seven-row transaction result export.
- Two-session screenshots showing session identity, visibility/blocking, concurrent retry and deliberate deadlock.
- Ordered and unordered pgbench text outputs with actual measured metrics.
- Four before/after integrity CSVs and your completed analysis.
- Existing Portfolio 1 and 2 data retained; no fabricated outcomes or passwords in evidence.

## Technical references

- PostgreSQL explicit locking: https://www.postgresql.org/docs/18/explicit-locking.html
- PostgreSQL transaction isolation: https://www.postgresql.org/docs/18/transaction-iso.html
- PostgreSQL pgbench options and failure reporting: https://www.postgresql.org/docs/18/pgbench.html

The supplied NairaPay reference provided the exercise structure. This LendBridge adaptation adds a self-contained lab fixture, payload validation for reused keys, opening-balance reconciliation, pgAdmin-compatible batch tests and explicit two-session instructions.
