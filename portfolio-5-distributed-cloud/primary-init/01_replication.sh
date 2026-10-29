#!/usr/bin/env bash
set -Eeuo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE lb_replicator WITH REPLICATION LOGIN PASSWORD 'lendbridge_replication_demo';
SELECT pg_create_physical_replication_slot('replica1_slot');
SQL

printf '\nhost replication lb_replicator 0.0.0.0/0 scram-sha-256\n' >> "$PGDATA/pg_hba.conf"