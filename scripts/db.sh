#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  db.sh — керування навчальною БД shop (Postgres.app)
#
#  Використання:
#    ./scripts/db.sh create   — DROP + CREATE бази shop
#    ./scripts/db.sh seed     — залити sandbox/schema.sql + sandbox/seed.sql
#    ./scripts/db.sh reset    — create + seed
#    ./scripts/db.sh psql     — інтерактивний psql -d shop (search_path = shop)
#    ./scripts/db.sh run FILE — виконати довільний .sql-файл проти shop
#    ./scripts/db.sh dump     — pg_dump shop у backups/shop_<timestamp>.sql
#    ./scripts/db.sh size     — розмір бази й топ-таблиць
# ---------------------------------------------------------------------------
set -euo pipefail

DB_NAME="${DB_NAME:-shop}"
DB_USER="${DB_USER:-$(whoami)}"
PGAPP_BIN="/Applications/Postgres.app/Contents/Versions/latest/bin"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# знайти psql: спершу PATH, потім Postgres.app
if command -v psql >/dev/null 2>&1; then
  PSQL="psql"; PGDUMP="pg_dump"; CREATEDB="createdb"; DROPDB="dropdb"
elif [ -x "$PGAPP_BIN/psql" ]; then
  PSQL="$PGAPP_BIN/psql"; PGDUMP="$PGAPP_BIN/pg_dump"
  CREATEDB="$PGAPP_BIN/createdb"; DROPDB="$PGAPP_BIN/dropdb"
else
  echo "psql не знайдено. Додай $PGAPP_BIN у PATH (див. plan/01-setup.md)." >&2
  exit 1
fi

PSQL_DB=("$PSQL" -v ON_ERROR_STOP=1 -d "$DB_NAME" -U "$DB_USER")

cmd="${1:-}"
case "$cmd" in
  create)
    echo ">> DROP + CREATE $DB_NAME"
    "$DROPDB" -U "$DB_USER" --if-exists "$DB_NAME"
    "$CREATEDB" -U "$DB_USER" "$DB_NAME"
    echo "   готово."
    ;;

  seed)
    echo ">> schema.sql"
    "${PSQL_DB[@]}" -f "$ROOT/sandbox/schema.sql"
    echo ">> seed.sql (може зайняти 1-2 хв)"
    time "${PSQL_DB[@]}" -f "$ROOT/sandbox/seed.sql"
    ;;

  reset)
    "$0" create
    "$0" seed
    ;;

  psql)
    exec "$PSQL" -d "$DB_NAME" -U "$DB_USER" \
      -c "SET search_path = shop, public;" -c "\echo search_path = shop, public" \
      --set=PROMPT1='%/%R%# ' -f <(echo "SET search_path = shop, public;") 2>/dev/null || \
    exec "$PSQL" -d "$DB_NAME" -U "$DB_USER"
    ;;

  run)
    file="${2:?вкажи шлях до .sql-файлу}"
    "${PSQL_DB[@]}" -c "SET search_path = shop, public;" -f "$file"
    ;;

  dump)
    mkdir -p "$ROOT/backups"
    out="$ROOT/backups/${DB_NAME}_$(date +%Y%m%d_%H%M%S).sql"
    "$PGDUMP" -U "$DB_USER" "$DB_NAME" > "$out"
    echo "збережено: $out"
    ;;

  size)
    "${PSQL_DB[@]}" <<'SQL'
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;
SELECT relname AS table,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_relation_size(c.oid))       AS heap,
       pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid)) AS idx_toast
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'shop' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;
SQL
    ;;

  *)
    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
