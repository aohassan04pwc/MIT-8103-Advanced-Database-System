# LendBridge Portfolio 3 — Transactions and Concurrency Analysis

## 1\. Business operation and scope

LendBridge is a fictional lender serving Nigerian MSMEs. This experiment corrects the allocation of an existing repayment between two instalments of the same loan. It does not move money between borrowers, collect another payment or change the repayment amount. Each successful operation reduces the source allocation, increases the destination allocation, records two signed servicing movements and completes one idempotent request.

A separate `lb\_p3` schema in `lendbridge\_db` isolates the experiment from Portfolio 1's `public` tables and Portfolio 2's `lb\_bench`. Ten synthetic loans each have a ₦1,000,000 receipt split equally between two instalments. Each instalment has ₦1,000,000 due. Opening movement records account for every initial allocation. The servicing movements provide a reconciliation trail; they are not a complete general ledger.

## 2\. Environment and method

Execution took place on 24–25 October 2026 using pgAdmin on Windows, PostgreSQL 18.6 (established in Portfolio 2), and pgbench 18.6 (confirmed by its outputs). The demonstrations used separate READ COMMITTED connections. Session ids initially were 18612/14408; after reconnecting on 25 October they were 18068/18644. CPU, RAM and disk specifications were not supplied.

The two stress variants each used eight clients, two threads, a nominal 30-second duration, simple query mode and one maximum try, meaning no automatic retries. Each variant started after resetting the lab and exporting a clean integrity baseline. The workload selects a random loan, direction and amount from ₦0.01 to ₦1.00, with a new random key per operation. Independent keys exercise concurrent operations; the separate same-key demonstration tests duplicate logical requests. One run of each variant was recorded. These are observations, not repeatability statistics or a production capacity estimate.

## 3\. Transaction evidence

`output/03\_transaction\_results.csv` contains seven true results: COMMIT, ROLLBACK, FAILURE\_ATOMICITY, IDEMPOTENCY, APPLIED\_ONCE, KEY\_PAYLOAD\_CHECK and SAVEPOINT. COMMIT retains a completed request; ROLLBACK removes an attempted request and restores its allocation changes. A deliberately excessive reallocation raises INSUFFICIENT\_ALLOCATION after request registration; the exception subtransaction undoes the request as well as any changes. Repeating an identical key returns the existing id and applies the amount once, while reusing the key with a changed amount is rejected. SAVEPOINT retains the first ₦10 step while undoing the second ₦20 step.

The original pgAdmin batch produced six evidence rows because the COMMIT evidence insertion was inadvertently included in the following rolled-back transaction. The COMMIT result was then verified separately against the persisted completed ₦100 request and added to the export. The submitted script now includes explicit transaction boundaries to preserve that evidence. Original output is retained unchanged. The corrected script is statically reviewed, not claimed as a newly executed seven-test run.

An unhandled error inside an explicit transaction requires ROLLBACK or recovery to a prior savepoint before continuing. File 03 catches expected errors in subtransactions so the batch can complete. A function does not commit its caller's transaction. Identity sequence gaps after rollback are normal and do not establish missing committed requests.

## 4\. Visibility, retries and ordered locking

The before-commit screenshot shows both allocations at ₦500,000 in Session B while Session A's ₦100 correction remains uncommitted. After A commits, a new statement in B sees ₦499,900 and ₦500,100. This demonstrates committed visibility at READ COMMITTED; it does not demonstrate serializable isolation.

For the concurrent retry, A registered `concurrent-same-key` and kept the transaction open. B submitted the same payload and waited. After A committed, B returned successfully. `output/04\_concurrent\_retry.csv` shows request id 1, COMPLETED, amount ₦25, two movements and allocations of ₦499,975/₦500,025. This supports one application of the logical request. The matching returned ids were part of the guided demonstration but are not captured together in a dedicated two-session screenshot.

The safe function acquires instalment locks in ascending id order, then locks the repayment, and validates source availability and destination capacity after acquiring the locks. It uses FOR NO KEY UPDATE so foreign-key KEY SHARE locks do not force conflicting lock upgrades on referenced keys. All cooperating writers must follow the same hierarchy. Ordered locking for this single operation does not prevent every possible deadlock involving other writers or multiple operations in one transaction.

The opposite-direction ordered demonstration returned allocations to ₦500,000 each, documented in `04\_ordered\_locking\_result.png`. The final screenshot confirms the end state; the waiting interval was observed interactively, rather than recorded through a separate lock-monitor export.

## 5\. Deliberate deadlock

A manually locked instalment 1 while B locked instalment 2. A then requested 2, and B requested 1, completing a cycle. `04\_deadlock\_detected.png` records SQLSTATE 40P01: process 18644 waited on process 18068 while 18068 waited on 18644. B received the deadlock error in this run. The victim is not a contractual choice on which application logic should rely. Both sessions were rolled back afterward.

The deliberately unordered function locks source then destination, with a 10 ms sleep between locks to widen the collision window. Opposite corrections can therefore acquire the same pair in reverse order. This variant exists only for the lab comparison.

## 6\. Measured stress results

|Metric|Ordered|Unordered|
|-|-:|-:|
|Successful transactions|70,214|384|
|Failed transactions|0|37|
|Deadlock failures|0|37|
|Serialization failures|0|0|
|Failure rate reported by pgbench|0.000%|8.789%|
|Average successful transaction latency|3.380 ms|275.216 ms|
|Latency standard deviation|3.738 ms|1,112.956 ms|
|Transactions/sec, excluding initial connection time|2,364.680522|12.354269|
|Initial connection time|328.978 ms|375.872 ms|

The unordered attempt count is 384 successes plus 37 failures: 421, so 37/421 agrees with the reported failure rate. pgbench can finish in-flight transactions beyond the nominal duration; do not substitute successes/30 for its reported TPS. Its mean latency concerns successful transactions and does not summarize the latency of failed attempts.

The ordered run had no observed deadlocks for this workload. The unordered run suffered 37 and exhibited markedly lower throughput and larger latency variation. Its artificial delay independently adds work and prolongs lock holding, so the full throughput/latency difference cannot be attributed to lock order alone. A fair performance-isolation experiment would use matched delays or remove the delay from both variants. No such extra experiment is claimed here.

Both raw text logs retain Windows PowerShell's NativeCommandError wrapper around progress emitted on stderr. That wrapper is not itself a PostgreSQL transaction failure. The final pgbench summaries and database checks establish the recorded transaction outcomes; the unordered log's 37 actual deadlock failures are reported explicitly.

## 7\. Integrity before and after stress

|Check|Ordered before|Ordered after|Unordered before|Unordered after|
|-|-:|-:|-:|-:|
|Total receipts (₦)|10,000,000|10,000,000|10,000,000|10,000,000|
|Total allocated (₦)|10,000,000|10,000,000|10,000,000|10,000,000|
|Allocation/ledger mismatches|0|0|0|0|
|Incomplete/invalid requests|0|0|0|0|
|Negative allocations|0|0|0|0|
|Overallocated instalments|0|0|0|0|
|Receipt-total mismatches|0|0|0|0|
|Committed stress requests|0|70,214|0|384|
|Stress movements|0|140,428|0|768|

Each successful stress request has two movements, and the count of committed requests matches the corresponding pgbench success count. The checks validate line counts, signed amounts, request status and allocation reconciliation, not merely zero-sum movement totals. Failed unordered attempts left no partial committed requests in these checks. Conservation here concerns the synthetic allocated receipts; it does not prove external bank cash reconciliation or crash recovery.

## 8\. Conclusions and limitations

Consistent locking and post-lock validation supported correct concurrent reallocation in this lab. The UNIQUE request key plus payload validation prevented duplicate application and ambiguous key reuse. PostgreSQL's atomic rollback preserved consistency even when the flawed workload deadlocked. An application should retry the entire aborted transaction for transient 40P01/40001 failures, using bounded attempts/backoff and a stable logical idempotency key; business-rule failures require correction rather than blind retries.

The lab uses ten hot loans, small random amounts, synthetic allocations and no competing production workflows. It does not test a real payment gateway, application authorisation, distributed transactions, server-crash durability or production throughput. Constraints enforce key relationships, but aggregate business rules depend on the function and cooperative writers. Production roles would need restricted direct DML and a controlled execution interface. No production-ready or universally deadlock-free claim is made.

## 9\. Personal reflection

This project helped me understand the difference between a transaction waiting for a lock and a deadlock. Watching one session wait until another committed made concurrency control clearer to me. The retry test also demonstrated why payment requests need idempotency keys.



The stress tests showed that transaction failures can occur without leaving inconsistent allocation records. In a future experiment, I would compare both locking approaches without the artificial delay and repeat the tests to assess how stable the results are..

## 10\. Evidence and references

`output/` preserves seven-test results, the concurrent-retry CSV, four integrity CSVs, both raw pgbench logs and a derived stress summary. `screenshots/` contains before/after visibility, ordered final allocations and the deadlock error. The guide and eight scripts document reproduction. The scripts were adapted from the user-supplied NairaPay Portfolio 3 reference to LendBridge's repayment servicing model.

PostgreSQL references: [Explicit locking](https://www.postgresql.org/docs/18/explicit-locking.html), [Transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html), [pgbench](https://www.postgresql.org/docs/18/pgbench.html).

