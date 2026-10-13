#!/bin/sh
# Creates the timeline's database (Utopia's) on the node's Postgres, with the
# vector extension, if it does not exist yet. Run once per start by the
# timeline-db service; safe to run any number of times.
set -eu
db="${TIMELINE_DB:-tradera_timeline}"
export PGOPTIONS="-c client_min_messages=warning" PGHOST="${PGHOST:-postgres}" PGUSER="${POSTGRES_USER:-tradera}" PGPASSWORD="${POSTGRES_PASSWORD:-tradera}"
admin="${POSTGRES_DB:-tradera}"
until pg_isready -q -d "$admin"; do sleep 1; done
if ! psql -d "$admin" -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
  psql -v ON_ERROR_STOP=1 -d "$admin" -c "CREATE DATABASE \"$db\""
  echo "created database $db"
fi
psql -v ON_ERROR_STOP=1 -d "$db" -c "CREATE EXTENSION IF NOT EXISTS vector" >/dev/null
echo "database $db ready"
