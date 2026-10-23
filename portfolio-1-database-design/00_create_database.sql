-- ==============================================================================
-- Portfolio 1: LendBridge Advanced Relational Database Design
-- Script: 00_create_database.sql
-- Description: Creates the authoritative database 'lendbridge_db'.
-- Author: Senior Database Engineer & MIT 8103 Project Contributor
-- Target Engine: PostgreSQL 14+
-- ==============================================================================
--
-- EXECUTION INSTRUCTIONS FOR pgAdmin:
-- 1. Open pgAdmin 4.
-- 2. Connect to your PostgreSQL server instance.
-- 3. Right-click on the default 'postgres' database and select 'Query Tool'.
-- 4. Execute the SQL below (press F5).
--    (Note: PostgreSQL does not permit CREATE DATABASE inside a transaction block.)
-- 5. After execution, right-click 'Databases' in the Object Browser and select 'Refresh'.
-- 6. Disconnect from 'postgres', right-click 'lendbridge_db', and open a new Query Tool.
-- ==============================================================================

-- Terminate any existing connections to lendbridge_db before dropping if recreating (optional utility):
/*
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity 
WHERE datname = 'lendbridge_db' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS lendbridge_db;
*/

CREATE DATABASE lendbridge_db
    WITH OWNER = postgres;

COMMENT ON DATABASE lendbridge_db IS 'Authoritative relational database for LendBridge fintech working capital lending, loan servicing, and atomic payment allocation.';
