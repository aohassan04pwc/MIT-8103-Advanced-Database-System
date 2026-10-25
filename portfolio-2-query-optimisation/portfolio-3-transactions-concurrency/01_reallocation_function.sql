-- Functions do not COMMIT: the caller controls the transaction.
-- Internal helper's unordered mode is deliberately flawed for demonstration.
CREATE OR REPLACE FUNCTION lb_p3.reallocate_internal(
 p_receipt bigint, p_from bigint, p_to bigint, p_amount numeric,
 p_key text, p_ordered boolean
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
 v_id bigint; v_existing lb_p3.requests%ROWTYPE;
 v_loan bigint; v_from_loan bigint; v_to_loan bigint;
 v_available numeric; v_to_due numeric; v_to_total numeric;
 v_first bigint; v_second bigint;
BEGIN
 IF p_receipt IS NULL OR p_from IS NULL OR p_to IS NULL
    OR p_from = p_to THEN RAISE EXCEPTION 'INVALID_IDENTIFIERS'; END IF;
 IF p_amount IS NULL OR p_amount::text IN ('NaN','Infinity','-Infinity') THEN
  RAISE EXCEPTION 'INVALID_AMOUNT';
 END IF;
 IF p_amount <= 0 OR p_amount <> round(p_amount,2)
    OR p_amount > 99999999999999999.99 THEN
  RAISE EXCEPTION 'INVALID_AMOUNT: positive two-decimal amount required';
 END IF;
 IF p_key IS NULL OR btrim(p_key) = '' THEN
  RAISE EXCEPTION 'INVALID_KEY';
 END IF;
 INSERT INTO lb_p3.requests(idempotency_key,repayment_id,
   from_instalment,to_instalment,amount,status)
 VALUES(p_key,p_receipt,p_from,p_to,p_amount,'PENDING')
 ON CONFLICT(idempotency_key) DO NOTHING RETURNING request_id INTO v_id;
 IF v_id IS NULL THEN
  SELECT * INTO v_existing FROM lb_p3.requests WHERE idempotency_key=p_key;
  IF NOT FOUND THEN
   RAISE EXCEPTION 'RETRY_TRANSACTION' USING ERRCODE='40001';
  END IF;
  IF v_existing.repayment_id IS DISTINCT FROM p_receipt
    OR v_existing.from_instalment IS DISTINCT FROM p_from
    OR v_existing.to_instalment IS DISTINCT FROM p_to
    OR v_existing.amount IS DISTINCT FROM p_amount THEN
   RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  END IF;
  IF v_existing.status <> 'COMPLETED' THEN
   RAISE EXCEPTION 'INCOMPLETE_REQUEST';
  END IF;
  RETURN v_existing.request_id;
 END IF;
 -- Ordered mode always locks the smaller instalment id first.
 -- Unordered mode locks the source first, then waits to widen the race window.
 v_first := CASE WHEN p_ordered THEN LEAST(p_from,p_to) ELSE p_from END;
 v_second := CASE WHEN p_ordered THEN GREATEST(p_from,p_to) ELSE p_to END;
 PERFORM 1 FROM lb_p3.instalments WHERE instalment_id=v_first FOR NO KEY UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INSTALMENT_NOT_FOUND'; END IF;
 IF NOT p_ordered THEN PERFORM pg_sleep(0.01); END IF;
 PERFORM 1 FROM lb_p3.instalments WHERE instalment_id=v_second FOR NO KEY UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'INSTALMENT_NOT_FOUND'; END IF;
 -- Lock receipt after instalments; every writer must follow this hierarchy.
 SELECT loan_id INTO v_loan FROM lb_p3.repayments
 WHERE repayment_id=p_receipt FOR NO KEY UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'REPAYMENT_NOT_FOUND'; END IF;
 SELECT loan_id INTO v_from_loan FROM lb_p3.instalments WHERE instalment_id=p_from;
 SELECT loan_id,total_due INTO v_to_loan,v_to_due
 FROM lb_p3.instalments WHERE instalment_id=p_to;
 IF v_loan <> v_from_loan OR v_loan <> v_to_loan THEN
  RAISE EXCEPTION 'CROSS_LOAN_REALLOCATION_NOT_ALLOWED';
 END IF;
 SELECT allocated_amount INTO v_available FROM lb_p3.allocations
 WHERE repayment_id=p_receipt AND instalment_id=p_from;
 IF NOT FOUND OR v_available < p_amount THEN
  RAISE EXCEPTION 'INSUFFICIENT_ALLOCATION';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM lb_p3.allocations
 WHERE repayment_id=p_receipt AND instalment_id=p_to) THEN
  RAISE EXCEPTION 'DESTINATION_ALLOCATION_NOT_FOUND';
 END IF;
 SELECT COALESCE(sum(allocated_amount),0) INTO v_to_total
 FROM lb_p3.allocations WHERE instalment_id=p_to;
 IF v_to_total + p_amount > v_to_due THEN
  RAISE EXCEPTION 'DESTINATION_OVERALLOCATION';
 END IF;
 UPDATE lb_p3.allocations SET allocated_amount=allocated_amount-p_amount
 WHERE repayment_id=p_receipt AND instalment_id=p_from;
 UPDATE lb_p3.allocations SET allocated_amount=allocated_amount+p_amount
 WHERE repayment_id=p_receipt AND instalment_id=p_to;
 INSERT INTO lb_p3.movements(request_id,repayment_id,instalment_id,delta)
 VALUES(v_id,p_receipt,p_from,-p_amount),(v_id,p_receipt,p_to,p_amount);
 UPDATE lb_p3.requests SET status='COMPLETED' WHERE request_id=v_id;
 RETURN v_id;
END;
$$;
CREATE OR REPLACE FUNCTION lb_p3.reallocate_payment(
 p_receipt bigint,p_from bigint,p_to bigint,p_amount numeric,p_key text
) RETURNS bigint LANGUAGE sql AS $$
 SELECT lb_p3.reallocate_internal($1,$2,$3,$4,$5,true);
$$;
CREATE OR REPLACE FUNCTION lb_p3.reallocate_payment_unordered(
 p_receipt bigint,p_from bigint,p_to bigint,p_amount numeric,p_key text
) RETURNS bigint LANGUAGE sql AS $$
 SELECT lb_p3.reallocate_internal($1,$2,$3,$4,$5,false);
$$;
