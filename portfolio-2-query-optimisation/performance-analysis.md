# LendBridge Portfolio 2: Query Processing and Optimisation

## 1\. Purpose and environment

LendBridge is a fictional fintech providing working-capital loans to Nigerian MSMEs. This portfolio evaluates repayment statements, borrower loan searches, cash reporting and allocation audits using a separate synthetic benchmark schema, `lb\_bench`. The operational `public` schema is not modified by the benchmark scripts.

Measurements were collected on 23–24 October 2026 using pgAdmin, PostgreSQL 18.6, x86\_64 Windows, compiled with MSVC 19.44.35229. The database is `lendbridge\_db`; the session user is `postgres`. CPU, RAM and disk specifications were not supplied and are not assumed.

|Setting|Observed value|
|-|-:|
|Block size|8,192 bytes|
|shared\_buffers|128 MiB (16,384 × 8 KiB)|
|work\_mem|4 MiB|
|seq\_page\_cost|1|
|random\_page\_cost|4|
|cpu\_tuple\_cost|0.01|
|TimeZone|Africa/Lagos|

The fixture creates 5,000 borrowers, 5,000 KYC records, one product, 50,000 applications, 50,000 loans, 300,000 instalments, 200,000 repayments and 400,000 allocations. The setup counts and two integrity checks were reviewed during execution; both mismatch checks returned zero. Relation statistics record 2,942 pages for allocations (23 MB), 2,804 for instalments (22 MB) and 2,231 for repayments (17 MB). These are individual relation sizes, not totals including all indexes and TOAST.

## 2\. Queries and method

|Query|LendBridge purpose|Main features|
|-|-|-|
|Q01|Latest receipts for loan 1001|JOIN, ORDER BY, LIMIT 50|
|Q02|Daily receipt totals for January 2025|Date filter, aggregation|
|Q03|Largest loans for borrower 1001|Four-table join, top-N|
|Q04|Rank loans by large January receipts|Partial-index predicate, GROUP BY, HAVING|
|Q05|Find an idempotency key|UNIQUE lookup; control query|
|Q06|Find receipts allocated above their amount|LEFT JOIN, GROUP BY, HAVING|
|Q07|Find instalments allocated above total due|LEFT JOIN, GROUP BY, HAVING|
|Q08|Monthly cash position over six months|Date range, FILTER aggregates|
|Q09|Demonstrate incorrect totals from join fan-out|Scalar aggregate comparisons|

Q01–Q08 each have three recorded before and three recorded after plans: 48 CSV files. A warm-up was requested before recording. The comparison uses the median of the three saved Execution Time values, excluding planning time and pgAdmin's client elapsed time. The original query text is retained. Five experimental indexes were added together, so the results describe that index set rather than an independently controlled test of each index. Constraint indexes remained present during the baseline.

VACUUM (ANALYZE) on repayments, applications and allocations was performed in both phases. Runs were not conducted under a controlled cold-cache protocol; background workload and parallel worker allocation can vary. Saved CSVs are authoritative where conversational timing labels differed, especially Q07. Q09 is a correctness demonstration, not part of the timing comparison.

## 3\. Measured results

Speed-up = before median / after median. Values below 1 mean a slowdown.

|Query|Before median (ms)|After median (ms)|Ratio|
|-|-:|-:|-:|
|Q01|91.423|0.122|749.37×|
|Q02|188.102|20.534|9.16×|
|Q03|11.223|0.225|49.88×|
|Q04|90.930|48.707|1.87×|
|Q05|0.075|0.071|1.06×|
|Q06|848.875|1142.077|0.74×|
|Q07|2147.108|1136.803|1.89×|
|Q08|205.333|193.831|1.06×|

All individual timings are in `plans/timing\_summary.csv`. Plan details below use representative run 2 files; medians summarize all three runs.

## 4\. Plan analysis

### Q01: Loan receipt statement

Before indexing, PostgreSQL used a parallel sequential scan of repayments and sorted the matches. The after plan uses `p2\_receipts\_loan\_time`: loan\_id is first for equality filtering, followed by received\_at DESC and repayment\_id DESC to match the requested order deterministically. Root shared buffer hits fell from 2,249 to 10 in the representative plans. The fixture has four receipts per loan, so LIMIT 50 returns four rows; this experiment does not demonstrate stopping after 50 matches in a long statement history.

### Q02: Daily receipt totals

The before plan scans repayments in parallel. The after plan uses an index-only scan on `p2\_receipts\_time\_cover`, with the date range as the index condition and amount/loan\_id available in the index. It reads 16,985 qualifying entries with zero heap fetches. Root shared hits fall from 2,239 to 88. Aggregation and sorting remain necessary for the 31 daily results. This query needs all qualifying receipts, unlike a selective point lookup.

### Q03: Borrower's largest loans

The baseline scans 50,000 applications, returning 10 and removing 49,990. `p2\_applications\_borrower(borrower\_id, application\_id)` provides an index-only route to those applications; existing keys support the other joins. Representative root shared hits fall from 943 to 36. Sorting the resulting loans by principal still occurs; the application index does not directly order loan principal values.

### Q04: Large receipts

The baseline sequential scan returns 16,985 January receipts. The after plan uses `p2\_large\_receipts\_time`, an index-only date scan with zero heap fetches; root shared hits fall from 2,231 to 88. Aggregation and top-N ranking still process many rows. Critically, all synthetic repayments are ₦56,000, so every row satisfies amount >= 50,000. This partial index is not selective by amount in this fixture; its observed benefit comes from date access and coverage, and it duplicates much of the general date index. A varied amount distribution is needed to evaluate a genuinely selective large-payment predicate.

### Q05: Idempotency control

Both phases use the existing `uq\_repayments\_idempotency\_key` index, return one row and record four shared hits. The tiny timing difference is noise, not convincing evidence of improvement. UNIQUE constraints already create indexes suitable for equality lookup; another index on the same key would add maintenance without a demonstrated need.

### Q06: Receipt allocation audit

Both representative plans use GroupAggregate over a merge left join, scanning the repayments primary key and the allocation composite primary key. Root shared hits remain 7,263. No experimental index changes the chosen access path. The after median is 34.54% slower. The benchmark supports reporting a regression with unchanged plan shape; it does not establish that index maintenance caused a slower SELECT. Cache, scheduling and runtime variation remain possible explanations.

### Q07: Instalment allocation audit

The baseline uses a hash right join and hash aggregation. Its aggregate spills into 17 batches with 30,880 kB disk usage; the plan records temporary reads/writes. After indexing, a merge left join combines the instalments primary key scan with an index-only scan of `p2\_allocations\_instalment`, followed by GroupAggregate. The allocation scan has zero heap fetches and no temporary spill is reported. This explains why a full audit can improve despite still examining all instalments and allocations. The join processes 500,000 rows: 400,000 allocated matches plus 100,000 unmatched instalments. Both phases return zero violations.

### Q08: Monthly cash position

The baseline uses a parallel sequential scan. The after plan uses a parallel index-only scan on `p2\_receipts\_time\_cover` with zero heap fetches. Representative root shared hits fall from 2,238 to 455, but the median gain is only about 6%, with overlapping timing ranges and different worker counts. It should not be presented as a strong, stable speed-up. The large-receipt partial index is not generally valid for this query because the query also needs receipts below its threshold; a FILTER inside one aggregate does not restrict the whole input relation.

## 5\. Correctness and fan-out

Q06 and Q07 returned zero over-allocation violations in both phases, as shown by the saved plans. Q09 reports an incorrect joined receipt sum of ₦22,400,000,000, compared with actual cash and allocated totals of ₦11,200,000,000 each: a ratio of 2.0. Each receipt has two allocation rows, so joining first duplicates the receipt amount. Sum receipts at receipt grain, aggregate each side before joining, or use the allocation amount for an allocation-grain report. SUM(DISTINCT amount) is not a general repair because different receipts can have equal amounts.

Full plain-result exports for Q01–Q05 and Q08 were not supplied. Consequently, this evidence does not claim a complete before/after result-set comparison for every query. Unchanged query text and matching row counts support the experiment, but are weaker than value-by-value comparison. `sql/02\_query\_results.sql` retains all result queries for reproduction.

## 6\. Cost-based planner experiments

|Experiment|Observed outcome|
|-|-|
|Q01 normal|Index scans; four rows; 0.168 ms; 10 shared hits|
|Q01 index, index-only and bitmap scans disabled locally|Parallel sequential repayment scan and sequential loan scan; four rows; 125.103 ms; 2,792 shared hits|
|One-day receipt range|Bitmap Heap Scan via p2\_receipts\_time\_cover; estimate 280 rows, actual 548; 1.339 ms; 554 shared hits|
|Two-year receipt range|Sequential scan; estimate and actual 200,000 rows; 99.047 ms; 2,231 shared reads|

The forced test disables index paths for both joined tables, so its difference cannot be attributed solely to the new receipt index. Settings were scoped with SET LOCAL and restored using ROLLBACK. These diagnostic single runs are separate from the three-run benchmark medians.

The planner estimates costs using table sizes, distributions and configured cost parameters, then selects a low-cost plan. Narrow predicates can benefit from index access; retrieving an entire table can favour a sequential pass. The narrow/broad timings are not controlled speed comparisons because their row counts and cache conditions differ. A shared read means a PostgreSQL buffer miss and a request to the operating system, not proof of physical disk access. The narrow row-estimate discrepancy alone does not prove stale statistics: sampling and distribution assumptions also matter.

`pg\_stats` confirms one distinct repayment amount and 455 distinct received\_at values. Negative n\_distinct values express a fraction of the relation's rows, rather than a negative count. Statistics are estimates and must be interpreted with the fixture distribution.

## 7\. Storage and write trade-offs

|Experimental index|Bytes|Main demonstrated use|
|-|-:|-|
|p2\_allocations\_instalment|12,632,064|Q07|
|p2\_receipts\_time\_cover|8,134,656|Q02, Q08|
|p2\_large\_receipts\_time|8,134,656|Q04; amount predicate matches all fixture rows|
|p2\_receipts\_loan\_time|8,134,656|Q01|
|p2\_applications\_borrower|1,589,248|Q03|

The five experimental indexes occupy 38,625,280 bytes in total. The inventory includes 21 indexes, including constraint indexes.

The write experiment inserts the same 200,000 repayments into two temporary copies, one without additional indexes and one with the three experimental repayment indexes. Three trials reset both copies using TRUNCATE; the indexed copy runs first in trial 2. Elapsed time is measured with clock\_timestamp around dynamic INSERT execution, not EXPLAIN Execution Time. Reset, index creation and final transaction commit are outside the timed interval.

|Variant|Trial 1 (ms)|Trial 2 (ms)|Trial 3 (ms)|Median (ms)|Total bytes|
|-|-:|-:|-:|-:|-:|
|No extra indexes|195.200|320.104|196.113|196.113|18,300,928|
|Three extra indexes|2,331.972|1,980.618|2,035.995|2,035.995|46,997,504|

Median insert time is 10.38× as long with the indexes. Total storage grows by 28,696,576 bytes (27.37 MiB), or approximately 2.57× overall. These temporary copies exclude production primary/foreign keys, triggers and durable-table WAL behaviour, and do not measure commit latency. They isolate the additional index workload rather than predicting production payment throughput. The populated index sizes here differ from bulk-built benchmark indexes because the construction histories differ.

## 8\. Recommendations and limitations

Retain the loan/time index for statement access, borrower/application index for borrower searches, general date covering index for date reports and allocation/instalment index for audits where their workloads justify the measured costs. Review whether the large-receipt index is worth retaining alongside the general date index: the current uniform fixture provides no amount-selectivity advantage. Preserve constraint indexes for correctness irrespective of benchmark timing.

The synthetic data has uniform loan sizes and receipt amounts, four receipts per loan and fixed dates. It excludes concurrency, production workflow triggers, skewed borrower activity and failures. Timings varied substantially, phases occurred at different times, and worker/cache conditions were not fixed. No claim of linear performance at 100× volume is supported. At larger scale, examine date partitioning only where pruning benefits the workload, monitor statistics and visibility maps, and schedule appropriate vacuum/analyze maintenance. Reindex only when evidence such as bloat or corruption warrants it.

## 9\. Reflection



This project helped me understand that adding indexes does not improve every query equally. The loan statement query improved substantially, while the receipt allocation audit became slower despite the additional indexes. I also learned that execution plans and buffer usage provide more useful explanations than execution time alone.



The insert tests demonstrated the trade-off between faster reads, slower writes and additional storage. If I repeated this experiment, I would use more varied repayment amounts and borrower activity to better represent LendBridge's workload.

## 10\. Evidence

All supplied CSVs are retained in `plans/`, including the 48 measured plans, environment/settings, relation and index sizes, column statistics, normal/forced plans, selectivity plans, write trials and Q09 output. Screenshot evidence remains in the student's local screenshots folder and was not included in the uploaded plans ZIP. Add those existing screenshots when merging this package; no rerun is required merely to duplicate evidence.

