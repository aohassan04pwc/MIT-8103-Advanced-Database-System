-- Batched experiment: execute once; export final six rows. Temporary copies only.
DROP TABLE IF EXISTS pg_temp.p2_write_results;
DROP TABLE IF EXISTS pg_temp.p2_no_index;
DROP TABLE IF EXISTS pg_temp.p2_with_index;
CREATE TEMP TABLE p2_no_index AS SELECT * FROM lb_bench.repayments WITH NO DATA;
CREATE TEMP TABLE p2_with_index AS SELECT * FROM lb_bench.repayments WITH NO DATA;
CREATE INDEX ON p2_with_index (loan_id, received_at DESC, repayment_id DESC);
CREATE INDEX ON p2_with_index (received_at) INCLUDE (amount, loan_id);
CREATE INDEX ON p2_with_index (received_at) INCLUDE (loan_id, amount) WHERE amount >= 50000;
CREATE TEMP TABLE p2_write_results (trial INTEGER, execution_order INTEGER, variant TEXT, rows_inserted BIGINT, elapsed_ms NUMERIC, total_size_bytes BIGINT);
DO $$
DECLARE trial_no INTEGER; position_no INTEGER; target_table TEXT; started_at TIMESTAMPTZ; duration_ms NUMERIC; inserted_rows BIGINT;
BEGIN
 FOR trial_no IN 1..3 LOOP
  TRUNCATE TABLE p2_no_index, p2_with_index;
  FOR position_no IN 1..2 LOOP
   IF (trial_no % 2 = 1 AND position_no = 1) OR (trial_no % 2 = 0 AND position_no = 2) THEN target_table := 'p2_no_index'; ELSE target_table := 'p2_with_index'; END IF;
   started_at := clock_timestamp();
   EXECUTE format('INSERT INTO pg_temp.%I SELECT * FROM lb_bench.repayments', target_table);
   GET DIAGNOSTICS inserted_rows = ROW_COUNT;
   duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - started_at)) * 1000;
   INSERT INTO p2_write_results VALUES (trial_no, position_no, CASE target_table WHEN 'p2_no_index' THEN 'No extra indexes' ELSE 'Three extra indexes' END, inserted_rows, ROUND(duration_ms,3), pg_total_relation_size(format('pg_temp.%I',target_table)::regclass));
  END LOOP;
 END LOOP;
END;
$$;
SELECT trial, execution_order, variant, rows_inserted, elapsed_ms, total_size_bytes, pg_size_pretty(total_size_bytes) AS total_size FROM p2_write_results ORDER BY trial, execution_order;
