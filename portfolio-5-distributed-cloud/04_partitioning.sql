BEGIN;

CREATE TABLE lb_p5.repayments_by_loan (
    repayment_id bigint NOT NULL,
    loan_id bigint NOT NULL,
    provider_reference varchar(100) NOT NULL,
    idempotency_key varchar(100) NOT NULL,
    amount numeric(19,2) NOT NULL CHECK (amount > 0),
    received_at timestamptz NOT NULL,
    PRIMARY KEY (loan_id, repayment_id)
) PARTITION BY HASH (loan_id);

CREATE TABLE lb_p5.repayments_p0
PARTITION OF lb_p5.repayments_by_loan
FOR VALUES WITH (MODULUS 4, REMAINDER 0);

CREATE TABLE lb_p5.repayments_p1
PARTITION OF lb_p5.repayments_by_loan
FOR VALUES WITH (MODULUS 4, REMAINDER 1);

CREATE TABLE lb_p5.repayments_p2
PARTITION OF lb_p5.repayments_by_loan
FOR VALUES WITH (MODULUS 4, REMAINDER 2);

CREATE TABLE lb_p5.repayments_p3
PARTITION OF lb_p5.repayments_by_loan
FOR VALUES WITH (MODULUS 4, REMAINDER 3);

INSERT INTO lb_p5.repayments_by_loan
SELECT repayment_id, loan_id, provider_reference,
       idempotency_key, amount, received_at
FROM lb_bench.repayments;

COMMIT;

ANALYZE lb_p5.repayments_by_loan;

SELECT 'original' AS dataset, count(*) AS rows,
       sum(amount) AS total_amount
FROM lb_bench.repayments
UNION ALL
SELECT 'partitioned', count(*), sum(amount)
FROM lb_p5.repayments_by_loan;

SELECT tableoid::regclass AS partition_name,
       count(*) AS rows
FROM lb_p5.repayments_by_loan
GROUP BY tableoid
ORDER BY partition_name;