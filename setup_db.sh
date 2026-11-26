#!/usr/bin/env bash
# =====================================================================
#  ChargeMatch Lite — database setup
#
#    ./setup_db.sh            create/complete .env, sync the app user, and
#                             load schema + seed ONLY if the DB is empty.
#                             Existing data is never touched.
#    ./setup_db.sh --reset    same, then backup -> drop -> reload chargematch_lite
#
#  Touches ONLY the database `chargematch_lite` and the MySQL user
#  `cmlite_app`. Uses MySQL root (empty password on this Mac) — the app
#  itself never does. Secrets from .env are never printed.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"

# Hard-coded on purpose. Never read the DB name from anywhere else.
readonly DB_NAME="chargematch_lite"
readonly APP_USER="cmlite_app"
MYSQL=(mysql -u root --default-character-set=utf8mb4)

die() { echo "ERROR: $*" >&2; exit 1; }

RESET=0
[[ "${1:-}" == "--reset" ]] && RESET=1
[[ $# -eq 0 || $RESET -eq 1 ]] || die "unknown option '$1' (only --reset is supported)"

# =====================================================================
# 0. .env — ALWAYS create/complete it first (even if the DB already exists)
# =====================================================================
env_get() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# Replace KEY=... in place, or append it. Value goes through the environment,
# never through the command line, so it can't leak into `ps` output.
env_set() {
    if grep -qE "^$1=" .env; then
        K="$1" V="$2" awk 'BEGIN{FS=OFS="="} $1==ENVIRON["K"]{print ENVIRON["K"] "=" ENVIRON["V"]; next} {print}' \
            .env > .env.tmp && mv .env.tmp .env
    else
        printf '%s=%s\n' "$1" "$2" >> .env
    fi
}
env_del() { grep -vE "^$1=" .env > .env.tmp || true; mv .env.tmp .env; }
is_placeholder() { [[ -z "$1" || "$1" == change_me* ]]; }

if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then cp .env.example .env; else : > .env; fi
    echo "Created .env"
fi
chmod 600 .env

# Migrate older DB_* / APP_PORT names (from earlier versions) to MYSQL_* / PORT.
for pair in DB_HOST:MYSQL_HOST DB_PORT:MYSQL_PORT DB_SOCKET:MYSQL_SOCKET DB_NAME:MYSQL_DB \
            DB_USER:MYSQL_USER DB_PASSWORD:MYSQL_PASSWORD APP_PORT:PORT; do
    old="${pair%%:*}"; new="${pair##*:}"
    if grep -qE "^${old}=" .env; then
        oldval="$(env_get "$old")"
        if [[ -z "$(env_get "$new")" ]] || is_placeholder "$(env_get "$new")"; then
            is_placeholder "$oldval" || env_set "$new" "$oldval"
        fi
        env_del "$old"
    fi
done

# Fill in any missing plain settings with defaults.
[[ -n "$(env_get MYSQL_HOST)" ]] || env_set MYSQL_HOST 127.0.0.1
[[ -n "$(env_get MYSQL_PORT)" ]] || env_set MYSQL_PORT 3306
grep -qE '^MYSQL_SOCKET=' .env  || env_set MYSQL_SOCKET /tmp/mysql.sock
[[ -n "$(env_get MYSQL_DB)"   ]] || env_set MYSQL_DB "$DB_NAME"
[[ -n "$(env_get MYSQL_USER)" ]] || env_set MYSQL_USER "$APP_USER"
[[ -n "$(env_get PORT)"       ]] || env_set PORT 5060

# Generate secrets if missing or still placeholders (values are not printed).
if is_placeholder "$(env_get MYSQL_PASSWORD)"; then
    env_set MYSQL_PASSWORD "$(openssl rand -hex 16)"
    echo "Generated a new random MYSQL_PASSWORD in .env"
fi
if is_placeholder "$(env_get SECRET_KEY)"; then
    env_set SECRET_KEY "$(openssl rand -hex 32)"
    echo "Generated a new random SECRET_KEY in .env"
fi
chmod 600 .env

APP_PASSWORD="$(env_get MYSQL_PASSWORD)"
[[ "$APP_PASSWORD" =~ ^[A-Za-z0-9_]+$ ]] || die "MYSQL_PASSWORD may only contain letters, digits and _"
[[ "$(env_get MYSQL_DB)"   == "$DB_NAME"  ]] || die ".env MYSQL_DB must be $DB_NAME"
[[ "$(env_get MYSQL_USER)" == "$APP_USER" ]] || die ".env MYSQL_USER must be $APP_USER"
[[ "$(env_get PORT)" != "5050" ]] || die ".env PORT 5050 is reserved for another project"
echo ".env OK (MYSQL_DB=$DB_NAME, MYSQL_USER=$APP_USER, PORT=$(env_get PORT); secrets not shown)"

# =====================================================================
# 1. Safety: SQL files must not switch or create/drop databases
# =====================================================================
for f in schema.sql seed.sql; do
    [[ -f "$f" ]] || die "$f not found"
    if grep -inE '(DROP|CREATE)[[:space:]]+(DATABASE|SCHEMA)|^[[:space:]]*USE[[:space:]]' "$f"; then
        die "$f contains a forbidden statement (CREATE/DROP DATABASE or USE). Refusing."
    fi
done

"${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1 || die "cannot connect as MySQL root (is mysqld running?)"

# =====================================================================
# 2. Database (if missing) + least-privilege app user, password synced to .env
#    Runs every time, so a lost/regenerated .env password is repaired.
# =====================================================================
"${MYSQL[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`chargematch_lite\`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASSWORD}';
ALTER USER '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON \`chargematch_lite\`.* TO '${APP_USER}'@'localhost';
SQL
echo "User ${APP_USER}@localhost: password matches .env; grants SELECT/INSERT/UPDATE/DELETE/EXECUTE on ${DB_NAME}.* only."

table_count() {
    "${MYSQL[@]}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'"
}

# =====================================================================
# 3. Existing data: keep it (default) or --reset with confirmation + backup
# =====================================================================
EXISTING="$(table_count)"
if [[ "$EXISTING" -gt 0 && $RESET -eq 0 ]]; then
    echo "Database '${DB_NAME}' already has ${EXISTING} tables/views — data kept, nothing reloaded."
    echo "(To wipe and reload the demo data run:  ./setup_db.sh --reset)"
    echo "Done. Start the app with ./run.sh"
    exit 0
fi

if [[ $RESET -eq 1 ]]; then
    echo "================================================================"
    echo " RESET will DROP and recreate the database:  ${DB_NAME}"
    echo " (no other database is touched)"
    echo "================================================================"
    read -r -p "Type the database name to confirm: " answer
    [[ "$answer" == "$DB_NAME" ]] || die "confirmation did not match; nothing changed"

    # Safety net: refuse unless the name is exactly chargematch_lite
    [[ "$DB_NAME" == "chargematch_lite" ]] || die "safety check failed: DB_NAME is not chargematch_lite"

    if [[ "$EXISTING" -gt 0 ]]; then
        mkdir -p backups
        backup="backups/${DB_NAME}_$(date +%Y%m%d_%H%M%S).sql"
        mysqldump -u root --single-transaction --routines --triggers --set-gtid-purged=OFF \
                  --databases "$DB_NAME" > "$backup"
        echo "Backup written: $backup"
    fi
    "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`chargematch_lite\`"
    echo "Dropped ${DB_NAME}."
    "${MYSQL[@]}" -e "CREATE DATABASE \`chargematch_lite\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
fi

# =====================================================================
# 4. Load schema + seed (DB name given explicitly)
# =====================================================================
"${MYSQL[@]}" "$DB_NAME" < schema.sql
echo "Loaded schema.sql"
"${MYSQL[@]}" "$DB_NAME" < seed.sql
echo "Loaded seed.sql"

"${MYSQL[@]}" -t "$DB_NAME" <<'SQL'
SELECT
 (SELECT COUNT(*) FROM information_schema.tables   WHERE table_schema=DATABASE() AND table_type='BASE TABLE') AS tables_,
 (SELECT COUNT(*) FROM information_schema.tables   WHERE table_schema=DATABASE() AND table_type='VIEW')       AS views_,
 (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema=DATABASE())                           AS triggers_,
 (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema=DATABASE() AND routine_type='FUNCTION')  AS functions_,
 (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema=DATABASE() AND routine_type='PROCEDURE') AS procedures_;
SQL
echo "Done. Start the app with ./run.sh"
