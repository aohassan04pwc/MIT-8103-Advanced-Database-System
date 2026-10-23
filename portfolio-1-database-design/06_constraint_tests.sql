-- LendBridge corrected constraint and workflow tests
-- PostgreSQL 14+; run the ENTIRE file in the lendbridge_db Query Tool.
-- Prerequisites: your supplied 02_create_tables.sql and
-- 03_procedures_and_triggers.sql have already run successfully.
-- Does not recreate tables, disable constraints, or require fixed seed IDs.
-- Uses isolated synthetic fixtures and rolls them back after collecting results.
-- Identity sequences still advance when test inserts are rolled back (normal).
-- ROLLBACK below clears any transaction left aborted by the previous failed run.
-- Validation status: reviewed against the supplied schema/procedures;
-- execution in your PostgreSQL installation is still required.

ROLLBACK;
SET search_path TO public;
CREATE TEMP TABLE IF NOT EXISTS lb_corrected_results (
    test_id text PRIMARY KEY,
    test_name text NOT NULL,
    actual_status text NOT NULL,
    details text
);
TRUNCATE pg_temp.lb_corrected_results;

-- TEST-16 accepts either PostgreSQL restrictive-FK error code and requires
-- one of the named borrower foreign keys. Other errors still fail the test.
-- Each attempted invalid statement runs in its own exception subtransaction.
-- Even an unexpectedly successful statement is rolled back before logging FAIL.
-- A wrong error or wrong constraint is FAIL, not a false PASS.
CREATE OR REPLACE FUNCTION pg_temp.lb_expect_error(
    p_id text, p_name text, p_sql text, p_state text,
    p_constraint text DEFAULT NULL, p_message_fragment text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    v_state text; v_message text; v_constraint text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        RAISE EXCEPTION USING ERRCODE='ZL001', MESSAGE='Statement unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE,
            v_message=MESSAGE_TEXT, v_constraint=CONSTRAINT_NAME;
    END;
    INSERT INTO pg_temp.lb_corrected_results VALUES (
        p_id, p_name,
        CASE WHEN v_state=ANY(string_to_array(p_state,'|'))
            AND (p_constraint IS NULL OR v_constraint=ANY(string_to_array(p_constraint,'|')))
            AND (p_message_fragment IS NULL OR position(p_message_fragment IN v_message)>0)
            THEN 'PASS' ELSE 'FAIL' END,
        format('Expected SQLSTATE %s; actual %s; constraint %s; %s',
            p_state, v_state, coalesce(nullif(v_constraint,''),'not supplied'), v_message)
    );
END $fn$;

CREATE OR REPLACE FUNCTION pg_temp.lb_assert(
    p_id text, p_name text, p_ok boolean, p_details text
) RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
    INSERT INTO pg_temp.lb_corrected_results VALUES (
        p_id, p_name, CASE WHEN p_ok IS TRUE THEN 'PASS' ELSE 'FAIL' END, p_details
    );
END $fn$;

DO $suite$
DECLARE
    tag text := substr(md5(clock_timestamp()::text || random()::text),1,12);
    phone_base text;
    b1 bigint; b2 bigint;
    p1 bigint; p3 bigint;
    k1 bigint; k2 bigint; kp bigint;
    app_a bigint; app_b bigint; app_pending bigint; app_rejected bigint;
    app_outside bigint; app_positive bigint;
    loan_a bigint; loan_b bigint; loan_positive bigint; ignored_loan bigint;
    inst_a bigint; inst_b bigint;
    rep_base bigint; rep_small bigint; rep_large bigint;
    r1 bigint; r2 bigint; r3 bigint; retry_id bigint;
    allocated numeric; unapplied numeric; status_message text;
    n bigint; saved_count bigint; saved_sum numeric;
    s1 numeric; s2 numeric; s3 numeric; total numeric; principal_sum numeric;
    results_json jsonb;
BEGIN
    -- All fixture creation and tests are enclosed in this subtransaction.
    BEGIN
        phone_base := '8' || lpad((floor(random()*1000000000000)::bigint)::text,12,'0');
        INSERT INTO borrowers(first_name,last_name,business_name,email,phone)
        VALUES('Amina','Test','Synthetic Test Trader','lb.'||tag||'.a@example.test',phone_base||'1')
        RETURNING borrower_id INTO b1;
        INSERT INTO borrowers(first_name,last_name,business_name,email,phone)
        VALUES('Babatunde','Test','Synthetic Test Logistics','lb.'||tag||'.b@example.test',phone_base||'2')
        RETURNING borrower_id INTO b2;
        INSERT INTO loan_products(product_name,min_amount,max_amount,term_months,flat_rate,active)
        VALUES('Test Nano '||tag,20000,100000,1,0.03,true) RETURNING product_id INTO p1;
        INSERT INTO loan_products(product_name,min_amount,max_amount,term_months,flat_rate,active)
        VALUES('Test Trader '||tag,50000,500000,3,0.06,true) RETURNING product_id INTO p3;
        INSERT INTO kyc_records(borrower_id,document_type,document_reference,status,decided_at)
        VALUES(b1,'BVN','TEST-'||tag||'-A','VERIFIED',CURRENT_TIMESTAMP) RETURNING kyc_id INTO k1;
        INSERT INTO kyc_records(borrower_id,document_type,document_reference,status,decided_at)
        VALUES(b2,'BVN','TEST-'||tag||'-B','VERIFIED',CURRENT_TIMESTAMP) RETURNING kyc_id INTO k2;
        INSERT INTO kyc_records(borrower_id,document_type,document_reference,status)
        VALUES(b1,'CAC_CERT','TEST-'||tag||'-P','PENDING') RETURNING kyc_id INTO kp;

        INSERT INTO loan_applications(borrower_id,product_id,requested_amount,purpose)
        VALUES(b1,p3,300000,'Test baseline loan A') RETURNING application_id INTO app_a;
        CALL sp_approve_application(app_a,k1,'Synthetic test approval');
        CALL sp_disburse_loan(app_a,'TEST-A-'||tag,loan_a);
        INSERT INTO loan_applications(borrower_id,product_id,requested_amount,purpose)
        VALUES(b2,p1,50000,'Test baseline loan B') RETURNING application_id INTO app_b;
        CALL sp_approve_application(app_b,k2,'Synthetic test approval');
        CALL sp_disburse_loan(app_b,'TEST-B-'||tag,loan_b);
        INSERT INTO loan_applications(borrower_id,product_id,requested_amount,purpose)
        VALUES(b1,p1,50000,'Test pending application') RETURNING application_id INTO app_pending;
        INSERT INTO loan_applications(borrower_id,product_id,requested_amount,purpose)
        VALUES(b1,p1,50000,'Test rejected application') RETURNING application_id INTO app_rejected;
        CALL sp_reject_application(app_rejected,'Synthetic rejection test');
        INSERT INTO loan_applications(borrower_id,product_id,requested_amount,purpose)
        VALUES(b1,p1,150000,'Test above product maximum') RETURNING application_id INTO app_outside;
        SELECT instalment_id INTO STRICT inst_a FROM instalments WHERE loan_id=loan_a AND instalment_no=1;
        SELECT instalment_id INTO STRICT inst_b FROM instalments WHERE loan_id=loan_b AND instalment_no=1;
        INSERT INTO repayments(loan_id,provider_reference,idempotency_key,amount)
        VALUES(loan_a,'BASE-'||tag,'BASE-KEY-'||tag,5000) RETURNING repayment_id INTO rep_base;
        INSERT INTO repayment_allocations(repayment_id,instalment_id,allocated_amount)
        VALUES(rep_base,inst_a,1000);
        INSERT INTO repayments(loan_id,provider_reference,idempotency_key,amount)
        VALUES(loan_a,'SMALL-'||tag,'SMALL-KEY-'||tag,100) RETURNING repayment_id INTO rep_small;
        INSERT INTO repayments(loan_id,provider_reference,idempotency_key,amount)
        VALUES(loan_a,'LARGE-'||tag,'LARGE-KEY-'||tag,200000) RETURNING repayment_id INTO rep_large;

        PERFORM pg_temp.lb_expect_error('TEST-01', 'Duplicate email',
            format($sql$INSERT INTO borrowers(first_name,last_name,business_name,email,phone) VALUES('Dup','Email','Test',%L,%L)$sql$, 'lb.'||tag||'.a@example.test', phone_base||'3'), '23505', 'uq_borrowers_email', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-02', 'Duplicate phone',
            format($sql$INSERT INTO borrowers(first_name,last_name,business_name,email,phone) VALUES('Dup','Phone','Test',%L,%L)$sql$, 'lb.'||tag||'.c@example.test', phone_base||'1'), '23505', 'uq_borrowers_phone', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-03', 'Invalid product amount range',
            format($sql$INSERT INTO loan_products(product_name,min_amount,max_amount,term_months,flat_rate) VALUES(%L,500000,200000,3,0.05)$sql$, 'Bad bounds '||tag), '23514', 'chk_products_amount_range', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-04', 'Application zero principal',
            format($sql$INSERT INTO loan_applications(borrower_id,product_id,requested_amount,purpose) VALUES(%s,%s,0,'Zero test')$sql$, b1, p1), '23514', 'chk_applications_amount_positive', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-05', 'Nonexistent borrower',
            format($sql$INSERT INTO loan_applications(borrower_id,product_id,requested_amount,purpose) VALUES(-1,%s,50000,'FK test')$sql$, p1), '23503', 'fk_applications_borrower', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-06', 'Pending KYC with decision timestamp',
            format($sql$INSERT INTO kyc_records(borrower_id,document_type,document_reference,status,decided_at) VALUES(%s,'BVN','TEST-BAD','PENDING',CURRENT_TIMESTAMP)$sql$, b1), '23514', 'chk_kyc_decision_lifecycle', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-07A', 'Approval with own pending KYC',
            format($sql$CALL sp_approve_application(%s,%s,'Pending KYC test')$sql$, app_pending, kp), '23514', NULL, 'Only VERIFIED KYC');
        PERFORM pg_temp.lb_expect_error('TEST-07B', 'Approval above product maximum',
            format($sql$CALL sp_approve_application(%s,%s,'Product maximum test')$sql$, app_outside, k1), '23514', NULL, 'falls outside product limits');
        PERFORM pg_temp.lb_expect_error('TEST-07C', 'Approval with another borrower KYC',
            format($sql$CALL sp_approve_application(%s,%s,'Wrong owner test')$sql$, app_pending, k2), '23514', NULL, 'not applicant');
        PERFORM pg_temp.lb_expect_error('TEST-08A', 'Disburse submitted application',
            format($sql$CALL sp_disburse_loan(%s,%L,NULL)$sql$, app_pending, 'UNAPPROVED-'||tag), '23514', NULL, 'Only APPROVED applications');
        PERFORM pg_temp.lb_expect_error('TEST-08B', 'Disburse rejected application',
            format($sql$CALL sp_disburse_loan(%s,%L,NULL)$sql$, app_rejected, 'REJECTED-'||tag), '23514', NULL, 'Only APPROVED applications');
        PERFORM pg_temp.lb_expect_error('TEST-09A', 'Procedure blocks second loan',
            format($sql$CALL sp_disburse_loan(%s,%L,NULL)$sql$, app_b, 'DUP-PROC-'||tag), '23505', NULL, 'already been disbursed');
        PERFORM pg_temp.lb_expect_error('TEST-09B', 'Unique application constraint blocks second loan',
            format($sql$INSERT INTO loans(application_id,loan_reference,principal,flat_rate,term_months) VALUES(%s,%L,50000,0.03,1)$sql$, app_b, 'DUP-ROW-'||tag), '23505', 'uq_loans_application_id', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-10', 'Duplicate instalment number',
            format($sql$INSERT INTO instalments(loan_id,instalment_no,due_date,principal_due,interest_due) VALUES(%s,1,CURRENT_DATE+30,10000,500)$sql$, loan_a), '23505', 'uq_instalments_loan_no', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-11A', 'Reject zero repayment',
            format($sql$INSERT INTO repayments(loan_id,provider_reference,idempotency_key,amount) VALUES(%s,%L,%L,0)$sql$, loan_a, 'INVALID-A-'||tag, 'INVALID-KEY-A-'||tag), '23514', 'chk_repayments_amount_positive', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-11B', 'Reject negative repayment',
            format($sql$INSERT INTO repayments(loan_id,provider_reference,idempotency_key,amount) VALUES(%s,%L,%L,-500)$sql$, loan_a, 'INVALID-B-'||tag, 'INVALID-KEY-B-'||tag), '23514', 'chk_repayments_amount_positive', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-12A', 'Duplicate provider reference',
            format($sql$INSERT INTO repayments(loan_id,provider_reference,idempotency_key,amount) VALUES(%s,%L,%L,5000)$sql$, loan_a, 'BASE-'||tag, 'OTHER-KEY-'||tag), '23505', 'uq_repayments_provider_ref', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-12B', 'Duplicate idempotency key',
            format($sql$INSERT INTO repayments(loan_id,provider_reference,idempotency_key,amount) VALUES(%s,%L,%L,5000)$sql$, loan_a, 'OTHER-REF-'||tag, 'BASE-KEY-'||tag), '23505', 'uq_repayments_idempotency_key', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-13', 'Duplicate allocation primary key',
            format($sql$INSERT INTO repayment_allocations(repayment_id,instalment_id,allocated_amount) VALUES(%s,%s,1000)$sql$, rep_base, inst_a), '23505', 'pk_repayment_allocations', NULL);
        PERFORM pg_temp.lb_expect_error('TEST-14', 'Cross loan allocation',
            format($sql$INSERT INTO repayment_allocations(repayment_id,instalment_id,allocated_amount) VALUES(%s,%s,50)$sql$, rep_small, inst_b), '23514', NULL, 'Cross-loan allocation prohibited');
        PERFORM pg_temp.lb_expect_error('TEST-15A', 'Allocation exceeds receipt amount',
            format($sql$INSERT INTO repayment_allocations(repayment_id,instalment_id,allocated_amount) VALUES(%s,%s,500)$sql$, rep_small, inst_a), '23514', NULL, 'Allocation ceiling exceeded');
        PERFORM pg_temp.lb_expect_error('TEST-15B', 'Allocation exceeds instalment remainder',
            format($sql$INSERT INTO repayment_allocations(repayment_id,instalment_id,allocated_amount) VALUES(%s,%s,105001)$sql$, rep_large, inst_a), '23514', NULL, 'Obligation ceiling exceeded');
        PERFORM pg_temp.lb_expect_error('TEST-16', 'Delete borrower with financial history',
            format($sql$DELETE FROM borrowers WHERE borrower_id=%s$sql$, b1),
            '23001|23503', 'fk_kyc_borrower|fk_applications_borrower', NULL);

        -- Separate clean loan for the positive repayment scenario.
        INSERT INTO loan_applications(borrower_id,product_id,requested_amount,purpose)
        VALUES(b1,p3,300000,'Synthetic positive lifecycle') RETURNING application_id INTO app_positive;
        CALL sp_approve_application(app_positive,k1,'Synthetic verified credit approval');
        CALL sp_disburse_loan(app_positive,'TEST-POS-'||tag,loan_positive);
        SELECT count(*),sum(principal_due),sum(total_due)
        INTO n,principal_sum,total FROM instalments WHERE loan_id=loan_positive;
        PERFORM pg_temp.lb_assert('POS-00','Complete three month repayment schedule',
            n=3 AND principal_sum=300000 AND total=318000
            AND (SELECT bool_and(total_due=106000) FROM instalments WHERE loan_id=loan_positive),
            format('Instalments=%s; principal=%s; total due=%s',n,principal_sum,total));

        CALL sp_process_repayment(loan_positive,'POS1-'||tag,'POS1-KEY-'||tag,120000,
            r1,allocated,unapplied,status_message);
        SELECT coalesce(sum(ra.allocated_amount) FILTER(WHERE i.instalment_no=1),0),
               coalesce(sum(ra.allocated_amount) FILTER(WHERE i.instalment_no=2),0)
        INTO s1,s2 FROM repayment_allocations ra
        JOIN instalments i USING(instalment_id) WHERE ra.repayment_id=r1;
        PERFORM pg_temp.lb_assert('POS-01','120000 split payment',
            allocated=120000 AND unapplied=0 AND s1=106000 AND s2=14000,
            format('Instalment 1=%s; instalment 2=%s; unapplied=%s',s1,s2,unapplied));

        CALL sp_process_repayment(loan_positive,'POS2-'||tag,'POS2-KEY-'||tag,92000,
            r2,allocated,unapplied,status_message);
        SELECT coalesce(sum(ra.allocated_amount),0) INTO s2
        FROM repayment_allocations ra JOIN instalments i USING(instalment_id)
        WHERE ra.repayment_id=r2 AND i.instalment_no=2;
        PERFORM pg_temp.lb_assert('POS-02','92000 settles second instalment remainder',
            allocated=92000 AND unapplied=0 AND s2=92000,
            format('Applied to instalment 2=%s; unapplied=%s',s2,unapplied));

        CALL sp_process_repayment(loan_positive,'POS3-'||tag,'POS3-KEY-'||tag,150000,
            r3,allocated,unapplied,status_message);
        SELECT coalesce(sum(ra.allocated_amount),0) INTO s3
        FROM repayment_allocations ra JOIN instalments i USING(instalment_id)
        WHERE ra.repayment_id=r3 AND i.instalment_no=3;
        PERFORM pg_temp.lb_assert('POS-03','150000 overpayment leaves 44000 unapplied',
            allocated=106000 AND unapplied=44000 AND s3=106000,
            format('Applied to instalment 3=%s; unapplied=%s',s3,unapplied));

        SELECT count(*) INTO saved_count FROM repayments WHERE loan_id=loan_positive;
        SELECT coalesce(sum(ra.allocated_amount),0) INTO saved_sum
        FROM repayment_allocations ra JOIN repayments r USING(repayment_id)
        WHERE r.loan_id=loan_positive;
        CALL sp_process_repayment(loan_positive,'POS1-'||tag,'POS1-KEY-'||tag,120000,
            retry_id,allocated,unapplied,status_message);
        PERFORM pg_temp.lb_assert('POS-04','Idempotent retry leaves receipts and allocations unchanged',
            retry_id=r1 AND status_message LIKE 'IDEMPOTENT_RETRY_ACKNOWLEDGED%'
            AND saved_count=(SELECT count(*) FROM repayments WHERE loan_id=loan_positive)
            AND saved_sum=(SELECT coalesce(sum(ra.allocated_amount),0)
                FROM repayment_allocations ra JOIN repayments r USING(repayment_id)
                WHERE r.loan_id=loan_positive),status_message);

        SELECT sum(amount) INTO total FROM repayments WHERE loan_id=loan_positive;
        SELECT sum(ra.allocated_amount) INTO s1 FROM repayment_allocations ra
        JOIN repayments r USING(repayment_id) WHERE r.loan_id=loan_positive;
        SELECT sum(total_due) INTO s2 FROM instalments WHERE loan_id=loan_positive;
        PERFORM pg_temp.lb_assert('POS-05','Independent contract receipt and allocation totals',
            total=362000 AND s1=318000 AND s2=318000 AND total-s1=44000 AND s2-s1=0,
            format('Received=%s; allocated=%s; contractual due=%s; unapplied=%s; debt=%s',
                total,s1,s2,total-s1,s2-s1));
        PERFORM pg_temp.lb_assert('POS-06','Every instalment fully settled without over allocation',
            NOT EXISTS(SELECT 1 FROM instalments i
                LEFT JOIN repayment_allocations ra USING(instalment_id)
                WHERE i.loan_id=loan_positive GROUP BY i.instalment_id,i.total_due
                HAVING coalesce(sum(ra.allocated_amount),0)<>i.total_due),
            'Each positive scenario instalment must have exactly 106000 allocated.');

        -- Preserve the report in a PL/pgSQL variable before rolling back fixtures.
        -- PL/pgSQL variables survive an exception rollback; database changes do not.
        SELECT jsonb_agg(to_jsonb(r) ORDER BY test_id) INTO results_json
        FROM pg_temp.lb_corrected_results r;
        RAISE EXCEPTION USING ERRCODE='ZL002', MESSAGE='Intentional rollback of test fixtures';
    EXCEPTION WHEN SQLSTATE 'ZL002' THEN
        NULL;
    END;

    -- Reinsert ONLY the captured report after the fixture subtransaction rolls back.
    INSERT INTO pg_temp.lb_corrected_results
    SELECT * FROM jsonb_populate_recordset(NULL::pg_temp.lb_corrected_results,results_json);
    RAISE NOTICE 'Test fixtures rolled back. Existing seed rows retained. Identity sequences may have gaps.';
END $suite$;

-- This final query is the report displayed by pgAdmin. It remains available
-- in the SAME Query Tool session; no fixtures or financial records are retained.
SELECT test_id,test_name,actual_status,
    count(*) FILTER(WHERE actual_status='PASS') OVER() AS passed_tests,
    count(*) FILTER(WHERE actual_status='FAIL') OVER() AS failed_tests,
    details
FROM pg_temp.lb_corrected_results
ORDER BY test_id;

-- To redisplay the report later in this same tab, run:
-- SELECT * FROM pg_temp.lb_corrected_results ORDER BY test_id;
-- These tests do NOT certify concurrent direct writes, production security,
-- complete double-entry accounting, or all possible mutation paths.
