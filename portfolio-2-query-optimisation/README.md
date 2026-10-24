# LendBridge — Portfolio 2: Query Processing and Optimisation

This project extends LendBridge's lending model with a separate PostgreSQL benchmark for repayment statements, borrower searches, reporting and allocation audits. Read [performance-analysis.md](performance-analysis.md) for measured results, explanations and limitations.

## Included deliverables

- Eight timed business/audit queries and one join fan-out demonstration in `queries/`.
- Reproducible setup, index, plan, result, planner and integrity scripts in `sql/`.
- All 48 before/after execution plans plus experiment exports in `plans/`.
- Computed per-query medians in `plans/timing_summary.csv`.
- A completed evidence-based performance analysis, with a personal reflection prompt remaining for the student.

## Results

Q01, Q02 and Q03 median times improved by approximately 749×, 9.16× and 49.88× respectively. Q04 improved 1.87× and Q07 1.89×. Q05 stayed effectively unchanged; Q06 regressed; Q08 showed only a small, uncertain timing gain. The write experiment found 10.38× longer median insertion time with three additional repayment indexes. These are fixture-specific observations, not production guarantees.

## Reproduction in pgAdmin

Use PostgreSQL 14+; the recorded environment was PostgreSQL 18.6 on Windows. Connect to `lendbridge_db`. Do not run Portfolio 1 table-creation scripts over existing operational data.

1. On a fresh benchmark schema, run `sql/00_prepare_benchmark.sql`. It creates `lb_bench` and synthetic data. It intentionally fails if that schema already exists; do not blindly rerun it on an existing benchmark.
2. Run `sql/07_verify_benchmark.sql` and inspect all counts and mismatch checks.
3. Use `sql/04_drop_indexes.sql` only when intentionally reproducing the baseline. It drops the five experimental indexes, not constraint indexes.
4. VACUUM (ANALYZE) repayments, loan_applications and repayment_allocations in `lb_bench`, each as a separate command outside a transaction.
5. Capture Q01–Q08 with EXPLAIN (ANALYZE, BUFFERS): warm up, then export three full plans per query. Use `qNN_before_runN.csv` filenames.
6. Run `sql/03_create_indexes.sql`, repeat the same maintenance and capture protocol with `after` filenames.
7. Run result queries and planner experiments, exporting each result before replacing its output. Keep forced planner settings local to a transaction and ROLLBACK afterward.
8. Use `sql/06_write_cost.sql` for the batched three-trial write experiment. It creates temporary copies and returns six rows for one export, `write_cost_results.csv`.

The supplied evidence has already been collected. These steps are for reproduction, not an instruction to repeat completed work. Baseline and after filenames must remain distinct.

## Final submission preparation

Merge this folder with your existing Portfolio 2 folder, retaining your screenshots. Add your own short reflection and any module-required identification. Full plain-result before/after exports were not supplied for every query; the report states this limitation. This package follows the supplied sample's structure, adapted to lending, and is not a certification against an unseen marking rubric. Commit the Portfolio 2 folder alongside Portfolio 1 in the existing GitHub repository.
