-- ==============================================================================
-- Portfolio 1: LendBridge Advanced Relational Database Design
-- Script: 05_seed_data.sql
-- Description: Inserts realistic synthetic seed data for commercial products,
--              Nigerian MSME borrowers, identity documents, and initial applications.
-- Author: Senior Database Engineer & MIT 8103 Project Contributor
-- Target Engine: PostgreSQL 14+
-- ==============================================================================
--
-- EXECUTION INSTRUCTIONS FOR pgAdmin:
-- 1. Ensure you are connected to 'lendbridge_db' in pgAdmin Query Tool.
-- 2. Execute the entire script (F5).
-- ==============================================================================

BEGIN;

-- ------------------------------------------------------------------------------
-- 1. SEED LOAN PRODUCTS
-- ------------------------------------------------------------------------------
INSERT INTO loan_products (product_name, min_amount, max_amount, term_months, flat_rate, active)
VALUES 
    ('Nano Working Capital 1M', 20000.00, 100000.00, 1, 0.030000, TRUE),
    ('Micro Trader 3M',          50000.00, 500000.00, 3, 0.060000, TRUE),
    ('SME Growth 6M',           200000.00, 2000000.00, 6, 0.120000, TRUE),
    ('Commercial Enterprise 12M', 1000000.00, 10000000.00, 12, 0.200000, TRUE);

-- ------------------------------------------------------------------------------
-- 2. SEED BORROWERS (Nigerian MSME Enterprise Profiles)
-- ------------------------------------------------------------------------------
INSERT INTO borrowers (first_name, last_name, business_name, email, phone)
VALUES 
    ('Amina', 'Bello', 'Amina Provisions & Wholesale', 'amina.bello@example.test', '+2348012345671'),
    ('Chukwudi', 'Eze', 'Chukwudi Auto Spares Ltd', 'chukwudi.eze@example.test', '+2348023456782'),
    ('Olumide', 'Adeyemi', 'Lagos Island Textiles', 'olumide.adeyemi@example.test', '+2348034567893'),
    ('Fatima', 'Dahiru', 'Arewa Grain Millers', 'fatima.dahiru@example.test', '+2348045678904'),
    ('Babatunde', 'Lawal', 'Lawal Logistics & Haulage', 'babatunde.lawal@example.test', '+2348056789015');

-- ------------------------------------------------------------------------------
-- 3. SEED KYC RECORDS (Synthetic Verification Documents)
-- ------------------------------------------------------------------------------
-- Amina Bello (ID 1): Verified BVN and Verified CAC
INSERT INTO kyc_records (borrower_id, document_type, document_reference, status, submitted_at, decided_at)
VALUES 
    (1, 'BVN', 'BVN-22233344401', 'VERIFIED', CURRENT_TIMESTAMP - INTERVAL '10 days', CURRENT_TIMESTAMP - INTERVAL '9 days'),
    (1, 'CAC_CERT', 'RC-99887701', 'VERIFIED', CURRENT_TIMESTAMP - INTERVAL '9 days', CURRENT_TIMESTAMP - INTERVAL '8 days');

-- Chukwudi Eze (ID 2): Verified NIN, Pending CAC
INSERT INTO kyc_records (borrower_id, document_type, document_reference, status, submitted_at, decided_at)
VALUES 
    (2, 'NIN', 'NIN-11223344552', 'VERIFIED', CURRENT_TIMESTAMP - INTERVAL '5 days', CURRENT_TIMESTAMP - INTERVAL '4 days'),
    (2, 'CAC_CERT', 'RC-44556602', 'PENDING', CURRENT_TIMESTAMP - INTERVAL '2 days', NULL);

-- Olumide Adeyemi (ID 3): Rejected Document (Illegible Scan)
INSERT INTO kyc_records (borrower_id, document_type, document_reference, status, submitted_at, decided_at)
VALUES 
    (3, 'DRIVERS_LICENSE', 'DL-NG-99881103', 'REJECTED', CURRENT_TIMESTAMP - INTERVAL '4 days', CURRENT_TIMESTAMP - INTERVAL '3 days');

-- Fatima Dahiru (ID 4): Pending BVN
INSERT INTO kyc_records (borrower_id, document_type, document_reference, status, submitted_at, decided_at)
VALUES 
    (4, 'BVN', 'BVN-55566677704', 'PENDING', CURRENT_TIMESTAMP - INTERVAL '1 day', NULL);

-- Babatunde Lawal (ID 5): Verified BVN
INSERT INTO kyc_records (borrower_id, document_type, document_reference, status, submitted_at, decided_at)
VALUES 
    (5, 'BVN', 'BVN-88899900005', 'VERIFIED', CURRENT_TIMESTAMP - INTERVAL '7 days', CURRENT_TIMESTAMP - INTERVAL '6 days');

-- ------------------------------------------------------------------------------
-- 4. SEED INITIAL LOAN APPLICATIONS
-- ------------------------------------------------------------------------------
-- Application 1: Amina Bello requests NGN 300,000 for 3 months (Micro Trader 3M)
INSERT INTO loan_applications (borrower_id, product_id, requested_amount, purpose, status)
VALUES 
    (1, 2, 300000.00, 'Working capital restocking for seasonal commodity trading', 'SUBMITTED');

-- Application 2: Chukwudi Eze requests NGN 1,500,000 for 6 months (SME Growth 6M)
INSERT INTO loan_applications (borrower_id, product_id, requested_amount, purpose, status)
VALUES 
    (2, 3, 1500000.00, 'Direct container importation of engine components', 'SUBMITTED');

-- Application 3: Olumide Adeyemi requests NGN 80,000 for 1 month (Nano Working Capital 1M)
INSERT INTO loan_applications (borrower_id, product_id, requested_amount, purpose, status)
VALUES 
    (3, 1, 80000.00, 'Fabric purchase for bulk corporate uniform contract', 'SUBMITTED');

COMMIT;
