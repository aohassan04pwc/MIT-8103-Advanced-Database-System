\set ON_ERROR_STOP on

BEGIN;

CREATE TABLE lb_p5.repayments_by_loan_8 (
    LIKE lb_p5.repayments_by_loan INCLUDING ALL
) PARTITION BY HASH (loan_id);

DO $$
BEGIN
    FOR i IN 0..7 LOOP
        EXECUTE format(
            'CREATE TABLE lb_p5.repayments_8_p%s
             PARTITION OF lb_p5.repayments_by_loan_8
             FOR VALUES WITH (MODULUS 8, REMAINDER %s)',
            i, i
        );
    END LOOP;
END
$$;

INSERT INTO lb_p5.repayments_by_loan_8
SELECT * FROM lb_p5.repayments_by_loan;

COMMIT;

ANALYZE lb_p5.repayments_by_loan_8;

SELECT 'four partitions' AS dataset,
       count(*) AS rows, sum(amount) AS total_amount
FROM lb_p5.repayments_by_loan
UNION ALL
SELECT 'eight partitions', count(*), sum(amount)
FROM lb_p5.repayments_by_loan_8;

SELECT tableoid::regclass AS partition_name, count(*) AS rows
FROM lb_p5.repayments_by_loan_8
GROUP BY tableoid
ORDER BY partition_name;

-- Warm up both queries.
SELECT count(*) FROM lb_p5.repayments_by_loan WHERE loan_id = 100;
SELECT count(*) FROM lb_p5.repayments_by_loan_8 WHERE loan_id = 100;

-- Compare the same query with equivalent indexes.
\echo FOUR PARTITIONS
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM lb_p5.repayments_by_loan WHERE loan_id = 100;

\echo EIGHT PARTITIONS
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM lb_p5.repayments_by_loan_8 WHERE loan_id = 100;