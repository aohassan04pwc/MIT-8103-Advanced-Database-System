-- ==============================================================================
-- Portfolio 1: LendBridge Advanced Relational Database Design
-- Script: 01_verify_setup.sql
-- Description: Verifies connection environment, PostgreSQL version, encoding, and user privileges.
-- Author: Senior Database Engineer & MIT 8103 Project Contributor
-- ==============================================================================
--
-- EXECUTION INSTRUCTIONS FOR pgAdmin:
-- 1. Ensure you are connected to 'lendbridge_db' in the Query Tool.
-- 2. Execute the script below (F5).
-- 3. Review the output grid to verify correct database and user environment.
-- ==============================================================================

SELECT 
    version() AS postgresql_version,
    current_database() AS connected_database,
    current_user AS session_user,
    inet_server_addr() AS server_address,
    inet_server_port() AS server_port,
    current_setting('server_encoding') AS server_encoding,
    current_setting('client_encoding') AS client_encoding,
    current_setting('TimeZone') AS current_timezone,
    CURRENT_TIMESTAMP AS system_timestamp;

-- Validate schema search path
SHOW search_path;
