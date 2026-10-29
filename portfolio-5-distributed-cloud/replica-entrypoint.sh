#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" = '0' ]; then
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  exec gosu postgres bash "$0"
fi

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  if [ -n "$(ls -A "$PGDATA")" ]; then
    echo 'Replica directory is nonempty without PG_VERSION; inspect failed initialisation.' >&2
    exit 1
  fi

  until pg_isready -h primary -p 5432 -U lb_replicator; do
    sleep 2
  done

  pg_basebackup -d 'host=primary port=5432 user=lb_replicator application_name=lendbridge_replica' \
    -D "$PGDATA" -Fp -Xs -P -R -S replica1_slot
fi

exec postgres -D "$PGDATA" -c hot_standby=on