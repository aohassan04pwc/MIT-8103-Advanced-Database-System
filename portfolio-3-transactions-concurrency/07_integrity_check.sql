-- One statement gives one READ COMMITTED snapshot. Run with stress clients stopped.
WITH receipt_totals AS (
 SELECT r.repayment_id,r.amount,COALESCE(sum(a.allocated_amount),0) allocated
 FROM lb_p3.repayments r LEFT JOIN lb_p3.allocations a USING(repayment_id)
 GROUP BY r.repayment_id,r.amount
), instalment_totals AS (
 SELECT i.instalment_id,i.total_due,COALESCE(sum(a.allocated_amount),0) allocated
 FROM lb_p3.instalments i LEFT JOIN lb_p3.allocations a USING(instalment_id)
 GROUP BY i.instalment_id,i.total_due
), movement_totals AS (
 SELECT a.repayment_id,a.instalment_id,a.allocated_amount,COALESCE(sum(m.delta),0) ledger
 FROM lb_p3.allocations a LEFT JOIN lb_p3.movements m
 USING(repayment_id,instalment_id)
 GROUP BY a.repayment_id,a.instalment_id,a.allocated_amount
), request_lines AS (
 SELECT r.request_id,r.status,r.repayment_id,r.from_instalment,r.to_instalment,r.amount,
 count(m.movement_id) lines,COALESCE(sum(m.delta),0) net,
 count(*) FILTER(WHERE m.repayment_id=r.repayment_id
 AND m.instalment_id=r.from_instalment AND m.delta=-r.amount) source_lines,
 count(*) FILTER(WHERE m.repayment_id=r.repayment_id
 AND m.instalment_id=r.to_instalment AND m.delta=r.amount) destination_lines
 FROM lb_p3.requests r LEFT JOIN lb_p3.movements m USING(request_id)
 GROUP BY r.request_id
)
SELECT 'total_receipts' AS metric,sum(amount)::numeric AS value FROM lb_p3.repayments
UNION ALL SELECT 'total_allocated',sum(allocated_amount) FROM lb_p3.allocations
UNION ALL SELECT 'receipt_total_mismatches',count(*) FROM receipt_totals WHERE amount<>allocated
UNION ALL SELECT 'overallocated_instalments',count(*) FROM instalment_totals WHERE allocated>total_due
UNION ALL SELECT 'allocation_ledger_mismatches',count(*) FROM movement_totals WHERE allocated_amount<>ledger
UNION ALL SELECT 'incomplete_or_invalid_requests',count(*) FROM request_lines
 WHERE status<>'COMPLETED' OR lines<>2 OR net<>0 OR source_lines<>1 OR destination_lines<>1
UNION ALL SELECT 'negative_allocations',count(*) FROM lb_p3.allocations WHERE allocated_amount<0
UNION ALL SELECT 'stress_requests',count(*) FROM lb_p3.requests WHERE idempotency_key LIKE 'pgb-%'
UNION ALL SELECT 'stress_movements',count(*) FROM lb_p3.movements m JOIN lb_p3.requests r USING(request_id)
 WHERE r.idempotency_key LIKE 'pgb-%'
ORDER BY metric;
