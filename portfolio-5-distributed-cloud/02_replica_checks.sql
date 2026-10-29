-- Run on the replica BEFORE promotion.
-- Expected before promotion: recovery = true, read-only = on.
-- After promotion: recovery = false, read-only = off.

SELECT pg_is_in_recovery();
SHOW transaction_read_only;

SELECT status, sender_host, sender_port,
       written_lsn, flushed_lsn
FROM pg_stat_wal_receiver;

SELECT pg_last_wal_receive_lsn(),
       pg_last_wal_replay_lsn(),
       pg_last_xact_replay_timestamp();

SELECT
    (SELECT count(*) FROM lb_bench.borrowers) AS borrowers,
    (SELECT count(*) FROM lb_bench.loans) AS loans,
    count(*) AS repayments,
    sum(amount) AS repayment_total
FROM lb_bench.repayments;

-- Expected error on an unpromoted standby.
-- The negative ID avoids changing an existing repayment
-- if this is accidentally run after promotion.
UPDATE lb_bench.repayments
SET amount = amount
WHERE repayment_id = -1;