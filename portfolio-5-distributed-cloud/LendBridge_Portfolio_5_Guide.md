# MIT 8103 Portfolio 5: LendBridge Distributed and Cloud Databases

**A practical self-study guide for Windows, PostgreSQL, Docker and MongoDB Atlas**  
Adapted from the supplied Portfolio 5 sample, with LendBridge-specific tables and self-contained reference scripts. Prepared 27 October 2026.

This is an implementation guide, not a completed submission. All result fields, screenshots, timings, analysis and reflection must come from your own execution. The sample mentions separate reference files, but those files were not attached. Appendix A supplies new LendBridge implementations rather than claiming to reproduce the missing originals.

## 1. What you will build

| Experiment | LendBridge implementation | Evidence |
|---|---|---|
| Streaming replication | Docker PostgreSQL primary and one read replica | WAL sender, WAL receiver, slot and matching counts |
| Stale reads | Pause replica replay, insert a harmless marker, compare | Different counts, then catch-up |
| Synchronous replication | Require acknowledgement from the named standby | Waiting commit, cancellation warning and recovery |
| Partitioning | Hash partition a copy of benchmark repayments by loan_id | Counts, totals and two EXPLAIN plans |
| Manual failover | Stop the primary, promote the replica, write a marker | Recovery-state change, successful write, measured RPO/RTO |
| Cloud deployment | Reuse Atlas cluster ADSMivaAz | Three-member topology, majority write, secondary read |
| Individual extension | Compare four and eight partitions, or another justified choice | Script, results and your interpretation |

PostgreSQL remains LendBridge's financial authority. Writes that approve loans, post repayments or allocate payments belong on the primary. Replica reports may tolerate declared staleness; repayment confirmation and current outstanding-balance decisions must not silently use a lagging replica. MongoDB retains the supplementary KYC/event role from Portfolio 4. Cloud probes use a separate database, `lendbridge_cloud`.

The existing PostgreSQL source is `lendbridge_db`. Work with **`lb_bench.borrowers`, `lb_bench.loans` and `lb_bench.repayments`**, not NairaPay accounts or ledger entries. The partitioned reporting copy and marker table live in **`lb_p5`**, only in the Docker copy. Do not rerun or reset Portfolios 1–4.

## 2. Concepts and important distinctions

**WAL and replication.** PostgreSQL logs changes in its write-ahead log. Physical streaming replication transfers WAL to a standby, which replays it. A base backup starts the standby from a consistent copy. A physical replication slot retains WAL needed by its consumer; unattended slots can consume disk. This lab limits retained slot WAL to 1 GB, so a sufficiently delayed replica may need rebuilding rather than catching up.

**Asynchronous versus synchronous.** Asynchronous commits do not wait for a replica. With `synchronous_commit=on` and a configured synchronous standby, a commit waits for that standby to flush the commit WAL durably. It does not necessarily wait for query visibility there. `remote_apply` additionally waits for replay. Neither setting makes every arbitrary replica read automatically current. Route correctness-sensitive reads deliberately.

**CAP.** CAP concerns consistency and availability during a network partition. Stopping one standby illustrates the dependence of synchronous acknowledgement on reachable replicas; it is not, by itself, a complete CAP or linearizability test. A primary can commit locally yet withhold the success acknowledgement while waiting for synchronous replication.

**Partitioning versus sharding.** Native PostgreSQL partitions here remain on one server. Their row placement and pruning illustrate part of shard-key design, but they provide no distributed transaction coordinator, network distribution or additional failure domains. Real sharding places data on multiple servers and must handle routing, global constraints and cross-shard operations.

**Recovery objectives.** RPO is the acceptable data-loss window; measure what evidence is actually available. RTO is the acceptable recovery duration; an observed lab recovery time is a measurement, not an enterprise guarantee. Replication is not a substitute for backup or point-in-time recovery.

## 3. Prepare the tools and folders

Use **PowerShell** for Docker, psql, pg_dump and file commands. Use **MongoDB Shell** only for JavaScript or `load(...)`. SQL files are passed to psql; they are not PowerShell code. Keep each exercise together and save its transcript before moving on.

Install Docker Desktop for Windows using its official installer and follow its WSL 2/virtualisation requirements. Open Docker Desktop and wait for its engine to run. Existing PostgreSQL and mongosh installations can be reused. Check:

```powershell
docker --version
docker compose version
psql --version
pg_dump --version
mongosh --version
```

This guide uses **PostgreSQL 18 for both Docker servers**, matching the PostgreSQL 18 installation used in the earlier work. Verify the actual local server with `SELECT version();`. If the source server is newer, select matching supported tools/images before dumping; do not dismiss restore errors as harmless version differences. Both physical replication servers must use the same PostgreSQL major version. Record actual patch versions and Docker image identifiers in your README; `postgres:18` can receive patch updates.

If psql is not found, use the installed PostgreSQL 18 bin directory for this terminal:

```powershell
$env:Path = 'C:\Program Files\PostgreSQL\18\bin;' + $env:Path
```

Use File Explorer to find the real directory if this path differs. Run commands from the local project root containing Portfolios 1–4. Based on your current layout:

```powershell
Set-Location 'C:\Users\USER\Downloads\ADM Project'
New-Item -ItemType Directory -Force -Path portfolio-5-distributed-cloud/output, portfolio-5-distributed-cloud/screenshots, portfolio-5-distributed-cloud/primary-init
```

If `ADM Project` is not a Git checkout, keep this folder layout and use GitHub's browser upload at the end, as with Portfolio 4. Do not run Git commands in an unrelated directory.

Append these patterns to the repository root `.gitignore`; preserve any existing entries:

```gitignore
.env
*.pgpass
lendbridge_dump.sql
lendbridge_dump.dump
```

The Docker passwords in Appendix A are visibly labelled coursework demo values and may appear in the Compose setup. Never reuse them for real services. Atlas credentials and real local passwords must not be committed. A private synthetic database dump is still excluded from the repository.

Suggested commit 1: **Create LendBridge Portfolio 5 guide and experiment structure**. Include this guide or another real file, since Git does not track empty directories.

## 4. Create and start the Docker cluster

Copy Appendix A's first three files into the exact paths shown. Use VS Code or another plain-text editor. Save both `.sh` files with **LF**, not CRLF, and UTF-8 without a BOM. In VS Code, click CRLF in the lower-right corner and select LF. These scripts are invoked by bash, so executable permissions are not required for this Windows workflow.

```powershell
docker compose -f portfolio-5-distributed-cloud/docker-compose.yml config --quiet
docker compose -f portfolio-5-distributed-cloud/docker-compose.yml up -d
docker compose -f portfolio-5-distributed-cloud/docker-compose.yml ps
docker logs lendbridge-pg-replica
```

Wait for both containers to be healthy. On a first start the replica performs `pg_basebackup`; readiness may take time. The published addresses are localhost port **5433** for primary and **5434** for replica. Your original PostgreSQL on **5432** is unaffected. If a port is occupied, inspect the conflicting service or choose different host ports and update both connection variables; do not stop an unknown service blindly.

The image uses PostgreSQL 18's version-specific data directory and mounts the parent `/var/lib/postgresql`. Do not replace this with a PostgreSQL 16 volume layout without adapting it. Primary initialisation runs only on an empty primary volume. Editing its init script after first startup will not rerun it.

```powershell
$env:PRIMARY = 'postgresql://postgres:lendbridge_demo_only@localhost:5433/lendbridge_db'
$env:REPLICA = 'postgresql://postgres:lendbridge_demo_only@localhost:5434/lendbridge_db'
```

These are local demonstration connections only. Re-enter them in a new terminal. Before substantive SQL, confirm where each connection points:

```powershell
psql $env:PRIMARY -X -v ON_ERROR_STOP=1 -c 'SELECT current_database(), inet_server_port(), pg_is_in_recovery();'
psql $env:REPLICA -X -v ON_ERROR_STOP=1 -c 'SELECT current_database(), inet_server_port(), pg_is_in_recovery();'
```

Inside both containers the server port is 5432; the host ports differ. The primary should return recovery false and the replica true.

Save `screenshots/01_docker_ps.png`, plus relevant startup logs if troubleshooting. Suggested commit 2: **Add LendBridge PostgreSQL primary and replica configuration**.

## 5. Copy existing LendBridge data into Docker

First inspect the source on port 5432. This is read-only verification:

```powershell
psql -h localhost -p 5432 -U postgres -d lendbridge_db -X -c 'SELECT version(); SELECT count(*) AS borrowers FROM lb_bench.borrowers; SELECT count(*) AS loans FROM lb_bench.loans; SELECT count(*) AS repayments FROM lb_bench.repayments;'
```

If a benchmark table is missing or empty, stop and check the Portfolio 2 source before importing. Do not create a NairaPay ledger to fit the sample. The dump copies your existing schemas, including the earlier portfolios; it does not turn them into a new authoritative production system.

Use PostgreSQL 18 pg_dump and restore tools:

```powershell
pg_dump -h localhost -p 5432 -U postgres -d lendbridge_db --no-owner --no-privileges --format=plain -f lendbridge_dump.sql
if ($LASTEXITCODE -ne 0) { throw 'Dump failed. Do not restore.' }
psql $env:PRIMARY -X -v ON_ERROR_STOP=1 -f lendbridge_dump.sql 2>&1 | Tee-Object -FilePath portfolio-5-distributed-cloud/output/00_restore.txt
if ($LASTEXITCODE -ne 0) { throw 'Restore failed. Inspect the first error before continuing.' }
```

Enter the real local PostgreSQL password at its prompt, if requested. `--no-privileges` and `--no-owner` avoid dependence on the source's role grants/ownership. Do not ignore errors about missing extensions, unsupported parameters or absent roles: diagnose the cause. A partial failed restore must be inspected before retrying; rerunning a plain dump into populated tables can fail or duplicate data.

Wait until these primary/replica counts match:

```powershell
psql $env:PRIMARY -X -c 'SELECT count(*) AS repayment_rows, sum(amount) AS repayment_amount FROM lb_bench.repayments;'
psql $env:REPLICA -X -c 'SELECT count(*) AS repayment_rows, sum(amount) AS repayment_amount FROM lb_bench.repayments;'
```

Save `screenshots/02_row_counts.png`. Replication may briefly lag. If they do not converge, inspect the receiver/sender instead of changing data. Suggested commit 3: **Record imported LendBridge counts and replication health**.

## 6. Experiment 1 — health and read-only behaviour

Save Appendix A's `01_primary_checks.sql` and `02_replica_checks.sql`, then run:

```powershell
psql $env:PRIMARY -X -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/01_primary_checks.sql 2>&1 | Tee-Object -FilePath portfolio-5-distributed-cloud/output/01_primary_checks.txt
if ($LASTEXITCODE -ne 0) { throw 'Primary checks failed.' }
psql $env:REPLICA -X -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/02_replica_checks.sql 2>&1 | Tee-Object -FilePath portfolio-5-distributed-cloud/output/02_replica_checks.txt
if ($LASTEXITCODE -ne 0) { throw 'Replica checks failed.' }
```

On the primary expect one streaming WAL sender named **lendbridge_replica**, `sync_state=async`, and an active physical slot **replica1_slot**. On the replica expect recovery true, transaction_read_only on, and a streaming receiver. The script catches the intended UPDATE rejection and prints a PASS notice with **SQLSTATE 25006**; this avoids treating an expected rejection as an unexplained script failure. An UPDATE matching zero rows still requires write permission and should be rejected on the standby.

`pg_last_xact_replay_timestamp()` may be null before a replayed commit. An idle primary can make the timestamp look old even when caught up; do not use its age alone as a universal lag measure. LSN gaps and receiver state provide complementary evidence.

Save `03_primary_checks.png` and `04_replica_checks.png`.

## 7. Experiment 2 — deliberately stale reads

Run each command separately. First create a marker on the **Docker primary**, using the PRIMARY variable, never your local source connection:

```powershell
psql $env:PRIMARY -X -v ON_ERROR_STOP=1 -c 'CREATE SCHEMA IF NOT EXISTS lb_p5; CREATE TABLE lb_p5.replication_marker (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, note text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp());'
psql $env:PRIMARY -X
```

At the **psql prompt**, type:

```sql
INSERT INTO lb_p5.replication_marker(note) VALUES ('baseline marker') RETURNING *;
\q
```

Return to PowerShell and query the replica until the table and baseline row are visible:

```powershell
psql $env:REPLICA -X -c 'TABLE lb_p5.replication_marker;'
psql $env:REPLICA -X -c 'SELECT pg_wal_replay_pause();'
psql $env:REPLICA -X -c 'SELECT pg_get_wal_replay_pause_state();'
```

Confirm **paused**, not merely pause requested, before proceeding. If still transitioning, repeat the pause-state query. Open primary psql again:

```powershell
psql $env:PRIMARY -X
```

```sql
INSERT INTO lb_p5.replication_marker(note) VALUES ('written while replay paused') RETURNING *;
\q
```

```powershell
psql $env:PRIMARY -X -c 'SELECT count(*) AS primary_markers FROM lb_p5.replication_marker;'
psql $env:REPLICA -X -c 'SELECT count(*) AS replica_markers FROM lb_p5.replication_marker;'
psql $env:PRIMARY -X -c 'SELECT sent_lsn, replay_lsn, pg_wal_lsn_diff(sent_lsn,replay_lsn) AS replay_gap_bytes FROM pg_stat_replication;'
```

On the first clean run the counts should be 2 and 1. Record actual values, not assumed ones. Pausing replay does not necessarily stop WAL receiving/flushing. This is a replay-lag experiment, not a full network outage.

```powershell
psql $env:REPLICA -X -c 'SELECT pg_wal_replay_resume();'
psql $env:REPLICA -X -c 'SELECT count(*) AS replica_markers FROM lb_p5.replication_marker;'
```

Repeat the count until it matches primary. Save `05_stale_read.png`, `06_caught_up.png` and a short `output/05_lag_observations.txt` with commands and actual results. Explain how a repayment posted on the primary could be absent from a lagging borrower statement. Suggested commit 4: **Demonstrate LendBridge stale reads and replay recovery**.

## 8. Experiment 3 — synchronous acknowledgement and unavailable standby

Ensure replay has resumed and the replica is streaming. Enter interactive primary psql:

```powershell
psql $env:PRIMARY -X
```

```sql
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (lendbridge_replica)';
SELECT pg_reload_conf();
SHOW synchronous_commit;
SELECT application_name, state, sync_state FROM pg_stat_replication;
```

Expect `synchronous_commit=on` and `sync_state=sync`; repeat the last query briefly if needed. Do not proceed with a mismatched application_name. With the replica up:

```sql
INSERT INTO lb_p5.replication_marker(note) VALUES ('sync replica available') RETURNING *;
\q
```

Stop only the Docker replica, then enter primary psql:

```powershell
docker stop lendbridge-pg-replica
psql $env:PRIMARY -X
```

```sql
INSERT INTO lb_p5.replication_marker(note) VALUES ('sync replica unavailable') RETURNING *;
```

The command should wait for synchronous replication confirmation. Save `07_sync_wait.png`. In a second PowerShell window you can prove the wait using:

```powershell
docker exec lendbridge-pg-primary psql -U postgres -d lendbridge_db -X -c "SELECT pid, state, wait_event_type, wait_event FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
```

Return to the waiting terminal and press **Ctrl+C once**. Read and preserve the warning: the transaction may already be committed locally even though the replication wait was cancelled. Do not interpret the missing success acknowledgement as rollback, and do not blindly retry a financial payment. Idempotency keys and reconciliation are needed to resolve uncertain outcomes. Save `08_sync_warning.png` and the actual warning text in `output/06_sync_observations.txt`.

At the psql prompt restore asynchronous mode:

```sql
ALTER SYSTEM RESET synchronous_standby_names;
SELECT pg_reload_conf();
SELECT note, count(*) FROM lb_p5.replication_marker GROUP BY note ORDER BY note;
\q
```

If your original psql session is unavailable, use a separate local administrative connection through `docker exec ... psql` to reset the setting. Then:

```powershell
docker start lendbridge-pg-replica
psql $env:PRIMARY -X -c 'SELECT count(*) FROM lb_p5.replication_marker;'
psql $env:REPLICA -X -c 'SELECT count(*) FROM lb_p5.replication_marker;'
```

Wait for matching counts and streaming state. Record whether the cancelled operation is present locally and after catch-up. This is stronger evidence than assuming its outcome.

| Mode | Completion condition | Standby unavailable | Financial implication |
|---|---|---|---|
| Async, synchronous_commit on | Local WAL durable | Primary can acknowledge writes | Unreplicated acknowledged writes may be lost on failover |
| Sync, synchronous_commit on | Local WAL plus selected standby WAL durable | Acknowledgement can wait | Reduces loss exposure for acknowledged writes; replica query visibility can still lag |
| Sync with remote_apply, conceptual comparison | Selected standby has replayed commit | Acknowledgement can wait | Stronger read-after-commit visibility on that standby, with extra latency |

Explain a LendBridge policy: favour durable repayment posting, use bounded application timeouts without assuming rollback, and provide explicit pending/reconciliation states when the outcome is uncertain. A second synchronous candidate and managed failover could improve availability, but this two-node lab has no such redundancy. Suggested commit 5: **Record synchronous replication wait and uncertain commit outcome**.

## 9. Experiment 4 — partition the repayment reporting copy

Save Appendix A's `03_partitioning.sql`. Run once:

```powershell
psql $env:PRIMARY -X -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/03_partitioning.sql 2>&1 | Tee-Object -FilePath portfolio-5-distributed-cloud/output/03_partitioning.txt
if ($LASTEXITCODE -ne 0) { throw 'Partition experiment failed. Do not rerun into an existing table.' }
```

Confirm original and copied row counts **and monetary totals** match. Expect four hash partitions with broadly balanced counts, not mathematically identical counts. The dynamically chosen existing loan makes the first EXPLAIN relevant even when source identifiers differ.

The loan_id query should access one partition; the repayment_id-only query should consider all four. Inspect actual plans: pruning is about relations visited, not a promise of faster execution on a small dataset. All repayments for a loan are colocated by loan_id. Borrower-level reports across several loans can still span partitions, and a heavily active loan can create uneven load.

This is a reporting copy, not a replacement for the original repayment table. Its composite primary key enforces uniqueness for `(loan_id, repayment_id)`, not global uniqueness of repayment_id alone. The source's provider-reference and idempotency-key uniqueness, loan foreign key and payment-allocation rules are not recreated on this demonstration copy. Do not use it for payment ingestion.

Save `09_partitioning.png` showing counts and plan evidence; use numbered additional images if the output does not fit. Verify that the partitioned table eventually appears on the physical replica. Suggested commit 6: **Add repayment partitioning and pruning evidence**.

## 10. Individual extension — complete before failover

Choose and explain at least one meaningful extension. Appendix A provides an **AI-assisted starter** comparing four with eight loan-key hash partitions. Save it as `05_partition_extension.sql`, run it once and compare the plans with Step 9:

```powershell
psql $env:PRIMARY -X -v ON_ERROR_STOP=1 -f portfolio-5-distributed-cloud/05_partition_extension.sql 2>&1 | Tee-Object -FilePath portfolio-5-distributed-cloud/output/05_partition_extension.txt
if ($LASTEXITCODE -ne 0) { throw 'Extension failed.' }
```

Explain which queries still prune to one partition, which now visit eight, how row balance changes, and why more partitions need not be faster. Add your own choice or investigation: for example compare a borrower-level multi-loan query or choose a different key and explain the cost. Simply running supplied code unchanged does not establish independent authorship. Disclose assistance and explain every stage yourself.

Save `13_own_extension.png`. Suggested commit 7: **Compare LendBridge partition choices and explain trade-offs**.

## 11. Experiment 5 — controlled manual failover (last Docker experiment)

Before stopping the primary, preserve all previous outputs, ensure replay is resumed and asynchronous mode restored, and stop other writes. For a planned no-loss demonstration, insert a final marker on the primary and record its WAL position:

```powershell
psql $env:PRIMARY -X
```

```sql
INSERT INTO lb_p5.replication_marker(note) VALUES ('last marker before failover') RETURNING *;
SELECT pg_current_wal_lsn() AS primary_target_lsn;
\q
```

Copy the actual LSN into the comparison below, replacing `YOUR_RECORDED_LSN`:

```powershell
psql $env:REPLICA -X -c "SELECT pg_last_wal_replay_lsn(), pg_last_wal_replay_lsn() >= 'YOUR_RECORDED_LSN'::pg_lsn AS caught_up;"
```

Wait for caught_up true. Save this pre-stop evidence. These commands measure a controlled caught-up failover, not the worst-case loss from an unexpected asynchronous crash.

In PowerShell:

```powershell
$failoverStart = Get-Date
docker stop lendbridge-pg-primary
psql $env:REPLICA -X -v ON_ERROR_STOP=1 -c 'SELECT pg_is_in_recovery();'
psql $env:REPLICA -X -v ON_ERROR_STOP=1 -c 'SELECT pg_promote(true, 60);'
psql $env:REPLICA -X -v ON_ERROR_STOP=1 -c 'SELECT pg_is_in_recovery();'
psql $env:REPLICA -X
```

The replica remains read-only until you explicitly promote it. After promotion recovery should be false. At its psql prompt:

```sql
INSERT INTO lb_p5.replication_marker(note) VALUES ('write on promoted replica') RETURNING *;
SELECT * FROM lb_p5.replication_marker ORDER BY id;
\q
```

After a confirmed successful write:

```powershell
$observedRecoverySeconds = ((Get-Date) - $failoverStart).TotalSeconds
$observedRecoverySeconds
```

This manual observation includes your typing and command time. Record the definition rather than reporting it as automated failover latency. Verify the final pre-stop marker survived. A sequence gap may occur and is not evidence of missing committed payments. If no gap occurs, report that honestly.

Save `10_failover.png` and `output/07_failover_observations.txt` containing timestamp, target/replayed LSN, recovery states, surviving marker and elapsed duration. The observed loss may be zero in this controlled trial; unexpected asynchronous failure can lose WAL not received/replayed. Do not claim a guaranteed zero RPO.

**Leave the old primary stopped.** The promoted node follows a new timeline. Starting the old primary as a writer risks split brain. Rejoining requires an appropriate rebuild or pg_rewind workflow with prerequisites; it is not achieved by merely restarting the container.

For now retain Docker volumes and stop the lab after evidence is saved:

```powershell
docker compose -f portfolio-5-distributed-cloud/docker-compose.yml stop
```

Only if deliberately discarding this isolated lab after all evidence is retained, the following deletes **both Portfolio 5 Docker database volumes**:

```powershell
docker compose -f portfolio-5-distributed-cloud/docker-compose.yml down -v
```

That is an optional reset, not a routine step needed to complete the portfolio. It does not delete the original PostgreSQL database or Atlas data. Suggested commit 8: **Record manual failover and recovery observations**.

## 12. Experiment 6 — cloud evidence using your existing Atlas cluster

Reuse **ADSMivaAz** from Portfolio 4; do not create a paid cluster or reseed existing collections. Confirm the current IP allowlist, database credentials and observed version. Your earlier deployment used MongoDB 8.0.34 and mongosh 2.14.0; record what this run actually shows.

Copy Appendix A's JavaScript to `04_atlas_cloud_check.js`. In PowerShell, set a password-free URI using the exact host copied from Atlas; use your existing database user or a suitably authorised lab user:

```powershell
$env:ATLAS_URI = 'mongodb+srv://YOUR_ACTUAL_ATLAS_HOST/lendbridge_cloud'
$env:ATLAS_USER = 'aohassan04_db_user'
mongosh $env:ATLAS_URI --username $env:ATLAS_USER --authenticationDatabase admin --file portfolio-5-distributed-cloud/04_atlas_cloud_check.js 2>&1 | Tee-Object -FilePath portfolio-5-distributed-cloud/output/04_atlas_cloud_check.txt
if ($LASTEXITCODE -ne 0) { throw 'Atlas experiment did not finish. Inspect output; do not claim a pass.' }
```

Enter the database-user password at its prompt; do not put it in the URI. In a new terminal re-enter the variables. This script writes only a small uniquely identified cloud probe and restores primary read preference afterwards. It does not modify your Portfolio 4 validators, profiles, events or TTL evidence. If authentication fails, distinguish the database-user password from the Atlas website password.

The output should show the replica-set name, member hosts, current primary, an acknowledged majority write, the probe observed with **secondary** read preference and **majority** read concern, and an explain document including the serving server's information. Capture the actual serverInfo.host; do not claim a particular secondary served the query from topology alone. If the deployment does not expose needed diagnostics, retain the exact limitation instead of inventing a host.

`w: majority` is an acknowledgement policy. In a normal three voting data-bearing member deployment a majority is two; loss of two leaves no voting majority for an ordinary elected writable primary and majority-acknowledged writes cannot complete. Do not try to stop Atlas nodes to demonstrate this: Free clusters do not expose the primary-failover test feature. A write-concern timeout means an uncertain acknowledgement outcome, not proof that no write occurred.

Secondary reads can be stale. A majority read excludes data outside the majority-committed view but does not mean the newest wall-clock value is always returned. The script polls for its specific probe, so it does not claim automatic causal read-after-write or linearizability. Stronger application semantics require the appropriate session/read/write settings and routing.

Capture Atlas cluster topology and region as `11_atlas_cluster.png`, script output as `12_atlas_check_output.png`, and available Metrics as `14_atlas_metrics.png`. Actual Free-cluster metrics and privileges are limited; document unavailable items. Free clusters have a fixed three-node replication factor and cannot be configured as sharded clusters. Backup availability/features should be checked in the current UI; do not claim backups are configured because the platform offers them.

Suggested commit 9: **Add LendBridge Atlas topology and read-write concern evidence**.

## 13. README, production design and reflection

Create `portfolio-5-distributed-cloud/README.md` with these compact sections:

1. **Architecture and workload routing:** include the lab diagram below, actual versions and docker ps evidence. Distinguish the copied Docker database from your original local source. Identify which read paths can tolerate lag.
2. **Replication and consistency:** describe base backup, role, slot, sender/receiver evidence, stale reads, async/sync observations and uncertain commit outcomes. Include your chosen repayment-posting policy.
3. **Partitioning and distributed design:** include real row counts, amount totals and both plans. Write **150–250 words** on distributing LendBridge: shard key, colocating loan/instalment/repayment records, cross-loan operations, global idempotency, reporting without a key, hotspots, and the difference from MongoDB sharding.
4. **Failover and recovery:** show promotion, fencing/split-brain risks, recorded LSN/marker evidence, observed recovery time and limits on RPO conclusions. Explain backups and PITR as additional production requirements.
5. **Cloud deployment:** actual member topology, majority acknowledgement, secondary-read result and serving-host evidence, current tier limitations and security configuration.
6. **Individual extension and limitations:** your question, changes, actual results and what you learned. Include single-host Docker failure domain, one standby, manual failover, lab superuser use, demo passwords, no configured lab TLS, no demonstrated backup/PITR, and no real multi-server sharding. Atlas uses TLS; do not incorrectly say the whole portfolio has no encryption in transit.
7. **Reproduction, reflection and AI use:** exact order, evidence paths, safe rerun rules, one real difficulty, one improvement, and tool/assistance disclosure. Do not claim that an assisted example is independently authored.

```mermaid
flowchart TD
    App["LendBridge application"] --> P["Docker PostgreSQL primary: 5433"]
    App --> R["Read replica: 5434; stale-tolerant reports"]
    P -->|"Physical WAL replication"| R
    App --> M["Existing Atlas replica set; KYC and events"]
    Src["Original local lendbridge_db: 5432"] -->|"One-time dump and restore"| P
```

This is the **lab** layout, not a multi-zone production deployment. In a production design, describe a managed PostgreSQL service or coordinated primary/standby topology with independent zones, fencing, connection routing, monitoring and tested backups. Keep acknowledged repayment writes durable, route current balance/confirmation reads appropriately, and explain the latency/availability cost. Distributed transactions or two-phase commit require explicit coordinator and failure recovery design. A saga can coordinate compensating business actions, but is not a blanket replacement for atomic monetary invariants.

Use your source design to discuss loan-centred sharding rather than copying wallet-transfer examples. If a repayment allocation spans shards, define how posting authority, idempotency and reconciliation prevent double allocation. MongoDB sharding is different from a replica set: shards partition data, while replicas duplicate a shard's data for resilience. No actual MongoDB sharded cluster is deployed here.

### Results worksheet — populate from your own outputs

| Check | Recorded result | Evidence file |
|---|---|---|
| Source and replicated borrower/loan/repayment counts | To record | 02_row_counts.png |
| Streaming sender/receiver and slot | To record | 01/02 check outputs |
| Read-only rejection | To record | 02_replica_checks.txt |
| Paused primary count / replica count | To record | 05_lag_observations.txt |
| Counts after resuming | To record | 06_caught_up.png |
| Sync wait event and cancellation warning | To record | 06_sync_observations.txt |
| Original/copied rows and amount totals | To record | 03_partitioning.txt |
| Key/non-key partitions accessed | To record | 03_partitioning.txt |
| Promotion, marker survival, elapsed recovery | To record | 07_failover_observations.txt |
| Atlas topology/majority write/secondary read | To record | 04_atlas_cloud_check.txt |
| Individual extension findings | To record | Extension output and image |

Suggested final documentation commit: **Explain LendBridge distributed database findings and AI assistance**.

## 14. Evidence and submission checklist

The expected deliverables are:

- This guide, plus the three Docker/setup files from Appendix A.
- `01_primary_checks.sql`, `02_replica_checks.sql`, `03_partitioning.sql`, `04_atlas_cloud_check.js` and your extension file.
- Four principal experiment outputs: `01_primary_checks.txt`, `02_replica_checks.txt`, `03_partitioning.txt`, `04_atlas_cloud_check.txt`; retain the import, lag, synchronous and failover observations too.
- Screenshots 01–14 as described; extra images only where needed for readable evidence.
- README containing the diagram, actual results, 150–250-word distributed design, extension, personal reflection, limitations and AI-use declaration.
- No real passwords, credential files or database dumps in GitHub.
- **At least six genuine incremental commits**, as required by the sample; commit as the work progresses. Do not backdate or fabricate history.

Your existing repository contains Portfolios 1–4. Add **`portfolio-5-distributed-cloud` alongside them**, never nested inside another portfolio. If using GitHub's browser upload, upload the files for each completed milestone with meaningful commit messages. If using a local checkout:

```powershell
git status
git check-ignore lendbridge_dump.sql
git add portfolio-5-distributed-cloud .gitignore
git diff --cached --stat
git commit -m 'Add LendBridge Portfolio 5 completed experiment evidence'
git branch --show-current
git push origin main
```

Use the actual branch name. Review staged file contents for credentials, not only the filename summary. Avoid broad `git add -A` when unrelated files are present. After upload, check file types, lowercase output/screenshots paths, README rendering and evidence completeness.

The supplied sample requires a **private repository**, while your current repository is public. Check your lecturer's required access arrangement before submission; do not silently change visibility or presume the public setting meets the brief.

## 15. Troubleshooting and safe stopping points

| Symptom | Check/action |
|---|---|
| docker command not found / engine unavailable | Install/start Docker Desktop; check WSL 2 and virtualisation requirements |
| Shell script shows carriage-return errors | Save LF without BOM; inspect logs before considering a lab reset |
| Replica cannot authenticate | Confirm initial role creation, replication HBA rule and matching demo password; init scripts only run on empty volumes |
| Primary healthy but replica startup fails | Read replica logs; pg_isready is not proof of replication permission |
| Slot invalidated or required WAL removed | Preserve evidence; rebuild the dedicated lab standby through a controlled procedure |
| Restore reports errors | Stop at the first error; check source/target/tool major versions and extensions |
| Sync insert waits unexpectedly | Verify standby health, matching application_name, sync setting and replay state; preserve uncertain outcome warning |
| Stale-read counts do not match immediately | Check pause state and receiver; wait for replay to catch up |
| Second partition run says table exists | Preserve original results; do not insert again or drop tables blindly |
| Atlas secondary read fails | Check topology, available secondary, permissions, IP and exact error; do not mark a failed observation as a pass |
| Old primary after promotion | Keep stopped; do not allow two independent writers |

Before failover, a normal pause in work can use `docker compose ... stop`; restart both via `up -d` and verify health next time. Never leave replay paused or synchronous settings waiting on an unavailable standby without recording that state. After promotion, avoid `up -d` for the whole old topology until it has been deliberately rebuilt.

## 16. Sources and validation status

Primary documentation checked when preparing this adaptation:

- [PostgreSQL 18 standby and streaming replication](https://www.postgresql.org/docs/18/warm-standby.html)
- [PostgreSQL 18 replication settings](https://www.postgresql.org/docs/18/runtime-config-replication.html)
- [PostgreSQL 18 WAL and synchronous_commit](https://www.postgresql.org/docs/18/runtime-config-wal.html)
- [PostgreSQL 18 pg_basebackup](https://www.postgresql.org/docs/18/app-pgbasebackup.html)
- [PostgreSQL partitioning](https://www.postgresql.org/docs/18/ddl-partitioning.html)
- [Docker Official Image for PostgreSQL](https://hub.docker.com/_/postgres)
- [Docker Desktop for Windows installation](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Atlas Free cluster limits](https://www.mongodb.com/docs/atlas/reference/free-shared-limitations/)
- [MongoDB write concern](https://www.mongodb.com/docs/manual/reference/write-concern/)
- [MongoDB read preference](https://www.mongodb.com/docs/manual/core/read-preference/)
- [MongoDB read concern](https://www.mongodb.com/docs/manual/reference/read-concern/)

The shell and JavaScript scripts receive static syntax checks, and the Compose YAML is parsed during preparation. No Docker daemon, PostgreSQL server or authenticated Atlas session was available in the guide-generation environment. Therefore **replication, restore, SQL execution, promotion and cloud behaviour are not claimed as tested here**. Confirm them in your environment and preserve your own outputs. No performance values or recovery outcomes are prefilled.

## Appendix A — complete reference scripts

Create each file at its named path below, relative to `portfolio-5-distributed-cloud`. Copy only the content inside its code block. The supplied Markdown is self-contained; these are the actual scripts to save and run.


### `docker-compose.yml`

```yaml
name: lendbridge-p5
services:
  primary:
    image: postgres:18
    container_name: lendbridge-pg-primary
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: lendbridge_demo_only
      POSTGRES_DB: lendbridge_db
      PGDATA: /var/lib/postgresql/18/docker
    ports:
      - "127.0.0.1:5433:5432"
    volumes:
      - primary_data:/var/lib/postgresql
      - ./primary-init/01_replication.sh:/docker-entrypoint-initdb.d/01_replication.sh:ro
    command: ["postgres", "-c", "wal_level=replica", "-c", "max_wal_senders=10", "-c", "max_replication_slots=10", "-c", "max_slot_wal_keep_size=1GB", "-c", "hot_standby=on"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d lendbridge_db"]
      interval: 5s
      timeout: 5s
      retries: 30
  replica:
    image: postgres:18
    container_name: lendbridge-pg-replica
    environment:
      PGDATA: /var/lib/postgresql/18/docker
      PGPASSWORD: lendbridge_replication_demo
    ports:
      - "127.0.0.1:5434:5432"
    volumes:
      - replica_data:/var/lib/postgresql
      - ./replica-entrypoint.sh:/replica-entrypoint.sh:ro
    entrypoint: ["bash", "/replica-entrypoint.sh"]
    depends_on:
      primary:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d lendbridge_db"]
      interval: 5s
      timeout: 5s
      retries: 30
volumes:
  primary_data:
  replica_data:
```


### `primary-init/01_replication.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE lb_replicator WITH REPLICATION LOGIN PASSWORD 'lendbridge_replication_demo';
SELECT pg_create_physical_replication_slot('replica1_slot');
SQL
printf '\nhost replication lb_replicator 0.0.0.0/0 scram-sha-256\n' >> "$PGDATA/pg_hba.conf"
```


### `replica-entrypoint.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" = '0' ]; then
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  exec gosu postgres bash "$0"
fi
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  if [ -n "$(ls -A "$PGDATA")" ]; then
    echo 'Replica directory is nonempty without PG_VERSION; inspect failed initialisation.' >&2
    exit 1
  fi
  until pg_isready -h primary -p 5432 -U lb_replicator; do sleep 2; done
  pg_basebackup -d 'host=primary port=5432 user=lb_replicator application_name=lendbridge_replica' \
    -D "$PGDATA" -Fp -Xs -P -R -S replica1_slot
fi
exec postgres -D "$PGDATA" -c hot_standby=on
```


### `01_primary_checks.sql`

```sql
\set ON_ERROR_STOP on
SELECT version(), current_database(), pg_is_in_recovery() AS is_replica;
SHOW synchronous_standby_names;
SHOW synchronous_commit;
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_gap_bytes,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
SELECT slot_name, slot_type, active, restart_lsn, wal_status
FROM pg_replication_slots;
SELECT 'borrowers' AS relation, count(*) FROM lb_bench.borrowers
UNION ALL SELECT 'loans', count(*) FROM lb_bench.loans
UNION ALL SELECT 'repayments', count(*) FROM lb_bench.repayments;
```


### `02_replica_checks.sql`

```sql
\set ON_ERROR_STOP on
SELECT version(), current_database(), pg_is_in_recovery() AS is_replica;
SHOW transaction_read_only;
SELECT status, sender_host, sender_port, slot_name, latest_end_lsn
FROM pg_stat_wal_receiver;
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       pg_last_xact_replay_timestamp() AS last_replayed_commit_time;
SELECT count(*) AS repayment_rows FROM lb_bench.repayments;
-- Catch only the intended read-only rejection; unexpected success/errors abort.
DO $$
BEGIN
  BEGIN
    UPDATE lb_bench.repayments SET amount = amount WHERE repayment_id = -1;
    RAISE EXCEPTION 'FAIL: replica accepted an UPDATE';
  EXCEPTION WHEN read_only_sql_transaction THEN
    RAISE NOTICE 'PASS: replica refused UPDATE with SQLSTATE 25006';
  END;
END $$;
```


### `03_partitioning.sql`

```sql
\set ON_ERROR_STOP on
CREATE SCHEMA IF NOT EXISTS lb_p5;
-- A fresh table name deliberately prevents accidental reruns from duplicating data.
CREATE TABLE lb_p5.repayments_by_loan (
  loan_id bigint NOT NULL,
  repayment_id bigint NOT NULL,
  amount numeric(19,2) NOT NULL CHECK (amount > 0),
  received_at timestamptz NOT NULL,
  PRIMARY KEY (loan_id, repayment_id)
) PARTITION BY HASH (loan_id);
CREATE TABLE lb_p5.repayment_shard_0 PARTITION OF lb_p5.repayments_by_loan
  FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE lb_p5.repayment_shard_1 PARTITION OF lb_p5.repayments_by_loan
  FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE lb_p5.repayment_shard_2 PARTITION OF lb_p5.repayments_by_loan
  FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE lb_p5.repayment_shard_3 PARTITION OF lb_p5.repayments_by_loan
  FOR VALUES WITH (MODULUS 4, REMAINDER 3);
INSERT INTO lb_p5.repayments_by_loan
SELECT loan_id, repayment_id, amount, received_at FROM lb_bench.repayments;
ANALYZE lb_p5.repayments_by_loan;
SELECT tableoid::regclass AS partition, count(*) AS rows
FROM lb_p5.repayments_by_loan GROUP BY tableoid ORDER BY partition::text;
SELECT (SELECT count(*) FROM lb_bench.repayments) AS original_rows,
       (SELECT count(*) FROM lb_p5.repayments_by_loan) AS partitioned_rows,
       (SELECT sum(amount) FROM lb_bench.repayments) AS original_amount,
       (SELECT sum(amount) FROM lb_p5.repayments_by_loan) AS partitioned_amount;
SELECT loan_id AS sample_loan, repayment_id AS sample_repayment
FROM lb_bench.repayments ORDER BY repayment_id LIMIT 1 \gset
\echo Loan-key query: expect a plan accessing one partition
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM lb_p5.repayments_by_loan WHERE loan_id = :sample_loan;
\echo Repayment-ID query: expect all four partitions in the plan
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM lb_p5.repayments_by_loan WHERE repayment_id = :sample_repayment;
```


### `04_atlas_cloud_check.js`

```javascript
// Run in mongosh; keeps Portfolio 4 collections unchanged.
const cloud = db.getSiblingDB('lendbridge_cloud');
const hello = cloud.adminCommand({hello: 1});
printjson({checked_at: new Date(), setName: hello.setName,
  primary: hello.primary, hosts: hello.hosts,
  connected_is_primary: hello.isWritablePrimary,
  connected_is_secondary: hello.secondary});
if (!hello.setName || !hello.hosts || hello.hosts.length < 3) {
  throw Error('A three-member replica set was not established. Inspect topology before proceeding.');
}
const markerId = 'p5-' + new ObjectId().toHexString();
const result = cloud.cloud_probes.insertOne(
  {_id: markerId, project: 'LendBridge', purpose: 'Portfolio 5 cloud probe', created_at: new Date()},
  {writeConcern: {w: 'majority', wtimeout: 10000}}
);
print('MAJORITY_WRITE'); printjson(result);
if (!result.acknowledged) throw Error('Write not acknowledged');
const conn = db.getMongo();
try {
  conn.setReadPref('secondary');
  let seen = [];
  // Majority visibility on a secondary may lag; poll this specific marker.
  for (let attempt = 0; attempt < 20; attempt++) {
    seen = cloud.cloud_probes.find({_id: markerId}).readConcern('majority').maxTimeMS(10000).toArray();
    if (seen.length === 1) break;
    sleep(500);
  }
  if (seen.length !== 1) throw Error('Marker not visible on a secondary within this observation window');
  print('SECONDARY_MAJORITY_READ'); printjson(seen);
  const plan = cloud.cloud_probes.find({_id: markerId}).readConcern('majority').explain('executionStats');
  print('SECONDARY_READ_EXPLAIN'); printjson(plan);
  print('Inspect serverInfo.host in this plan alongside the hello member list.');
} finally {conn.setReadPref('primary');}
print('PASS: majority write acknowledged and marker observed using secondary read preference with majority read concern.');
print('This is not a linearizability test, a failover test, or an outage simulation.');
```


### `05_partition_extension.sql`

```sql
\set ON_ERROR_STOP on
-- Assisted extension example: eight hash partitions; adapt and explain yourself.
CREATE TABLE lb_p5.repayments_by_loan_8 (
  loan_id bigint NOT NULL, repayment_id bigint NOT NULL,
  amount numeric(19,2) NOT NULL CHECK (amount > 0),
  received_at timestamptz NOT NULL,
  PRIMARY KEY (loan_id, repayment_id)
) PARTITION BY HASH (loan_id);
DO $$
BEGIN
  FOR i IN 0..7 LOOP
    EXECUTE format('CREATE TABLE lb_p5.repayment8_%s PARTITION OF lb_p5.repayments_by_loan_8 FOR VALUES WITH (MODULUS 8, REMAINDER %s)', i, i);
  END LOOP;
END $$;
INSERT INTO lb_p5.repayments_by_loan_8
SELECT loan_id, repayment_id, amount, received_at FROM lb_bench.repayments;
ANALYZE lb_p5.repayments_by_loan_8;
SELECT tableoid::regclass AS partition, count(*) AS rows
FROM lb_p5.repayments_by_loan_8 GROUP BY tableoid ORDER BY partition::text;
SELECT count(*) AS rows, sum(amount) AS amount FROM lb_p5.repayments_by_loan_8;
SELECT loan_id AS sample_loan, repayment_id AS sample_repayment
FROM lb_bench.repayments ORDER BY repayment_id LIMIT 1 \gset
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM lb_p5.repayments_by_loan_8 WHERE loan_id = :sample_loan;
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM lb_p5.repayments_by_loan_8 WHERE repayment_id = :sample_repayment;
```
