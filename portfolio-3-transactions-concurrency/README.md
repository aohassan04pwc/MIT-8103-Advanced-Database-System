# LendBridge — Portfolio 3: Transactions and Concurrency

This lab demonstrates atomic repayment reallocation between instalments of the same loan, using a separate `lb_p3` schema in `lendbridge_db`. Portfolios 1 and 2 remain separate. Read [analysis.md](analysis.md) for actual results and limitations, and [LendBridge_Portfolio_3_Guide.md](LendBridge_Portfolio_3_Guide.md) for reproduction instructions.

## Recorded results

| Measure | Ordered | Deliberately unordered |
|---|---:|---:|
| Successful operations | 70,214 | 384 |
| Deadlock failures | 0 | 37 |
| TPS | 2,364.68 | 12.35 |
| Average latency | 3.380 ms | 275.216 ms |
| Integrity problem counts | All zero | All zero |

The unordered function adds an intentional 10 ms delay. This affects performance independently of lock order, so these numbers are a fault demonstration rather than an isolated speed comparison. Both runs conserved ₦10,000,000 in allocated receipts.

## Contents

- `00_lab_setup.sql`: creates the isolated schema and six tables; run once on a fresh schema.
- `01_reallocation_function.sql`: safe operation, internal helper and deliberately unordered twin.
- `02_demo_setup.sql`: resets only lab data; export evidence and stop clients before using it.
- `03_commit_rollback_demo.sql`: transaction/idempotency/savepoint checks; corrected to preserve result rows between demonstration transactions.
- `04_two_session_demos.sql`: labelled manual blocks, not a whole-file batch.
- `05_stress_ordered.pgbench` and `06_stress_unordered.pgbench`: PowerShell pgbench workload inputs.
- `07_integrity_check.sql`: one-snapshot reconciliation, before and after each stress run.
- `output/`: original exported evidence plus derived stress summary.
- `screenshots/`: four demonstration screenshots.

## Reproduction

Connect pgAdmin to `lendbridge_db`; use Auto-commit for batch files, and no outer transaction wrapping the transaction demo. Run 00 once, 01, then 02. Run 03 after reset. Use distinct connections and labelled blocks for 04, ending all open transactions before reset. For each stress variant: reset with 02, export 07 baseline, execute its pgbench command from the guide, then export 07 after completion without resetting. Never use pgbench -i for these custom scripts.

Core tests have already been performed. The corrected 03 file has been statically reviewed after the original evidence run; no new execution is claimed. Its saved seven-row CSV includes a separately verified COMMIT result, explained in analysis.md. Keep original outputs unchanged.

Before uploading this folder alongside Portfolios 1 and 2, add your own short reflection under analysis.md Section 9 and any identification required by your module. This package follows the supplied reference structure; an unseen marking rubric has not been certified.
