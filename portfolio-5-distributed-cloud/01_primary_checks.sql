-- Run on the original primary BEFORE failover.
-- After promotion, pg_stat_replication may be empty
-- because the promoted server has no standby.

SELECT version();
SELECT pg_is_in_recovery();
SHOW synchronous_standby_names;
SHOW synchronous_commit;

SELECT application_name, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;

SELECT slot_name, slot_type, active, wal_status
FROM pg_replication_slots;

SELECT
    (SELECT count(*) FROM lb_bench.borrowers) AS borrowers,
    (SELECT count(*) FROM lb_bench.loans) AS loans,
    count(*) AS repayments,
    sum(amount) AS repayment_total
FROM lb_bench.repayments;