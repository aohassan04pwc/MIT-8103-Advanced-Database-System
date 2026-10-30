-- Run once in pgAdmin connected to lendbridge_db.
-- Deliberately fails if lb_p3 already exists; reset data with 02_demo_setup.sql.
BEGIN;
CREATE SCHEMA lb_p3;
CREATE TABLE lb_p3.loans (
 loan_id bigint PRIMARY KEY, loan_reference text UNIQUE NOT NULL
);
CREATE TABLE lb_p3.instalments (
 instalment_id bigint PRIMARY KEY,
 loan_id bigint NOT NULL REFERENCES lb_p3.loans,
 total_due numeric(19,2) NOT NULL CHECK(total_due > 0),
 UNIQUE(instalment_id,loan_id)
);
CREATE TABLE lb_p3.repayments (
 repayment_id bigint PRIMARY KEY,
 loan_id bigint NOT NULL REFERENCES lb_p3.loans,
 amount numeric(19,2) NOT NULL CHECK(amount > 0),
 UNIQUE(repayment_id,loan_id)
);
CREATE TABLE lb_p3.allocations (
 repayment_id bigint NOT NULL,
 instalment_id bigint NOT NULL,
 loan_id bigint NOT NULL,
 allocated_amount numeric(19,2) NOT NULL CHECK(allocated_amount >= 0),
 PRIMARY KEY(repayment_id,instalment_id),
 FOREIGN KEY(repayment_id,loan_id) REFERENCES lb_p3.repayments(repayment_id,loan_id),
 FOREIGN KEY(instalment_id,loan_id) REFERENCES lb_p3.instalments(instalment_id,loan_id)
);
CREATE TABLE lb_p3.requests (
 request_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 idempotency_key text UNIQUE NOT NULL CHECK(btrim(idempotency_key) <> ''),
 repayment_id bigint NOT NULL REFERENCES lb_p3.repayments,
 from_instalment bigint NOT NULL REFERENCES lb_p3.instalments(instalment_id),
 to_instalment bigint NOT NULL REFERENCES lb_p3.instalments(instalment_id),
 amount numeric(19,2) NOT NULL CHECK(amount > 0),
 status text NOT NULL CHECK(status IN ('PENDING','COMPLETED')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(from_instalment <> to_instalment)
);
CREATE TABLE lb_p3.movements (
 movement_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 request_id bigint REFERENCES lb_p3.requests,
 repayment_id bigint NOT NULL,
 instalment_id bigint NOT NULL,
 delta numeric(19,2) NOT NULL CHECK(delta <> 0),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(repayment_id,instalment_id)
 REFERENCES lb_p3.allocations(repayment_id,instalment_id),
 UNIQUE(request_id,instalment_id)
);
COMMIT;
