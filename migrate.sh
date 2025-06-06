#!/bin/bash
set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: $0 <sqlite_database_file> [postgres_connection_string] [--reset] [--d1 [name]]

  --reset        Remove existing dump and database files before running
  --d1 [name]    Run the Cloudflare D1 flow. Optionally supply the D1 database
                 name or provide it via the D1_DATABASE_NAME environment variable.
EOF
    exit 1
}

if [ "$#" -lt 1 ]; then
    usage
fi

START_TIME=$(date +%s)
LOG_FILE="migrate_postgres_to_sqlite3.log"
SQLITE_SCHEMA_FILE="./schema.sql"
echo "Starting migration process..." > "$LOG_FILE" # Create or overwrite log file

# Define an array of tables to exclude for the SQLite flow
EXCLUDE_TABLES=("__drizzle_migrations" "ar_internal_metadata" "schema_migrations" "pg_catalog")

# Required argument
SQLITE_DATABASE_FILE="$1"
shift

# Option defaults
POSTGRES_CONN_STRING=""
RESET_FLAG=false
D1_MODE=false
D1_DATABASE_NAME="${D1_DATABASE_NAME:-}"

# Parse remaining arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        --reset)
            RESET_FLAG=true
            shift
            ;;
        --d1)
            D1_MODE=true
            if [ -n "${2:-}" ] && [[ ${2} != --* ]]; then
                D1_DATABASE_NAME="$2"
                shift 2
            else
                shift
            fi
            ;;
        *)
            if [ -z "$POSTGRES_CONN_STRING" ]; then
                POSTGRES_CONN_STRING="$1"
                shift
            else
                usage
            fi
            ;;
    esac
done

POSTGRES_DUMP_FILE="$(basename "$SQLITE_DATABASE_FILE" .sqlite).dump"

if $RESET_FLAG; then
    echo "Resetting environment (removing existing files)..." >> "$LOG_FILE"
    rm -f "$POSTGRES_DUMP_FILE" "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1
fi

# Determine required commands
CMDS=(pg_dump sed sqlite3)
if $D1_MODE; then
    CMDS+=(npx pnpm)
fi
for cmd in "${CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd is not installed." >&2
        exit 1
    fi
done

if $D1_MODE; then
    # --- Cloudflare D1 flow ---
    POSTGRES_DUMP_FILE="pgdb.dump.sql"
    TEMP_SQL_FILE="converted_to_sqlite.sql"
    rm -f "$POSTGRES_DUMP_FILE" "$TEMP_SQL_FILE"
    touch "$TEMP_SQL_FILE"
    rm -rf ../.wrangler
    echo "Deleted directory .wrangler to ensure a clean start."

    EXCLUDE_TABLES_OPTIONS=""
    for TABLE in public._prisma_migrations; do
        EXCLUDE_TABLES_OPTIONS+="--exclude-table=$TABLE --exclude-table-data=$TABLE "
    done

    echo "Creating PostgreSQL dump file '$POSTGRES_DUMP_FILE'..."
    pg_dump -n public --data-only --attribute-inserts $EXCLUDE_TABLES_OPTIONS \
        "$POSTGRES_CONN_STRING" > "$POSTGRES_DUMP_FILE"

    echo "Converting PostgreSQL dump file to SQLite3 compatible SQL..."
    sed -E \
        -e 's/\\\\:/\:/g' \
        -e 's/\\\\//g' \
        -e 's/\\\\;/;/g' \
        -e '/^SET /d' \
        -e '/setval/d' \
        -e "s/'true'/1/g" \
        -e "s/'false'/0/g" \
        -e 's/public\.//' \
        -e '/^[[:space:]]*SELECT/d' \
        -e "s/'([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]+)\\+[0-9]{2}'/'\1T\2Z'/g" \
        "$POSTGRES_DUMP_FILE" > "$TEMP_SQL_FILE"

    sed -i '1i\
PRAGMA foreign_keys = OFF;\
PRAGMA defer_foreign_keys = on;\
' "$TEMP_SQL_FILE"
    echo "PRAGMA defer_foreign_keys = off;" >> "$TEMP_SQL_FILE"
    echo "Conversion to SQLite3 compatible SQL completed."

    if [ -z "$D1_DATABASE_NAME" ]; then
        echo "Error: D1 database name not provided." >&2
        exit 1
    fi

    DB_EXISTS=$(npx wrangler d1 list | grep -c "$D1_DATABASE_NAME" || true)
    if [[ "$DB_EXISTS" -eq 0 ]]; then
        echo "D1 database '$D1_DATABASE_NAME' does not exist. Creating it now..."
        npx wrangler d1 create "$D1_DATABASE_NAME"
        echo "D1 database '$D1_DATABASE_NAME' created successfully."
        echo -e "\033[1;31m\033[1m\033[48;5;15m\n======================================================================\n  Before continuing, update wrangler config file with the DB binding.\n======================================================================\n\033[0m"
        read -p "Update your wrangler config file with the DB binding, then press [Enter] to continue..."
    else
        echo "D1 database '$D1_DATABASE_NAME' already exists."
        echo "Checking if D1 database '$D1_DATABASE_NAME' has any tables..."
        TABLE_NAMES=$(npx wrangler d1 execute "$D1_DATABASE_NAME" --remote --command='PRAGMA table_list' \
            | grep -o '"name": *"[^"\n]*"' | grep -o '"[^"\n]*"$' | tr -d '"' \
            | grep -Ev '(_cf_KV|sqlite_schema|sqlite_sequence|d1_migrations|sqlite_temp_schema)')
        TABLE_COUNT=$(echo "$TABLE_NAMES" | grep -c .)
        if [[ "$TABLE_COUNT" -gt 0 ]]; then
            echo -e "\033[1;33mWARNING: D1 database '$D1_DATABASE_NAME' already contains tables ($TABLE_COUNT found).\033[0m"
            read -p $'\033[1;33mWill need to delete and recreate your DB. Ok to proceed? > (Y/n): \033[0m' USER_CHOICE
            USER_CHOICE=${USER_CHOICE:-y}
            USER_CHOICE=$(echo "$USER_CHOICE" | tr '[:upper:]' '[:lower:]')
            if [[ "$USER_CHOICE" == "n" ]]; then
                echo "Aborting migration as requested by user."
                exit 0
            else
                echo "Resetting D1 database: $D1_DATABASE_NAME"
                npx wrangler d1 delete "$D1_DATABASE_NAME" -y
                npx wrangler d1 create "$D1_DATABASE_NAME"
                echo -e "\033[1;31m\033[1m\033[48;5;15m\n===========================================================================\nBefore continuing, update wrangler config file with the new database ID.\n===========================================================================\n\033[0m"
                read -p "Update your wrangler config file with the new database ID, then press [Enter] to continue..."
            fi
        fi
    fi

    echo "Creating and then running an init Prisma migration to create tables in D1 database..."
    mkdir -p ../migrations
    find ../migrations -mindepth 1 -delete
    echo y | pnpm --dir .. run migrate:dev
    pnpm --dir .. run migrate:new init --no-apply
    echo y | pnpm --dir .. run migrate:dev
    echo y | pnpm --dir .. run migrate:prd

    echo "Importing SQL statements into D1 database..."
    npx wrangler d1 execute "$D1_DATABASE_NAME" --remote --file "$TEMP_SQL_FILE" -y
    npx wrangler d1 execute "$D1_DATABASE_NAME" --local --file "$TEMP_SQL_FILE" -y
else
    # --- SQLite flow ---
    EXCLUDE_TABLES_OPTIONS=""
    for TABLE in "${EXCLUDE_TABLES[@]}"; do
        EXCLUDE_TABLES_OPTIONS+="--exclude-table=$TABLE "
    done

    if [ -f "$POSTGRES_DUMP_FILE" ]; then
        echo "Using existing PostgreSQL dump file: $POSTGRES_DUMP_FILE" >> "$LOG_FILE"
    else
        if [ -n "$POSTGRES_CONN_STRING" ]; then
            echo "PostgreSQL dump file '$POSTGRES_DUMP_FILE' not found, creating a new one." >> "$LOG_FILE"
            pg_dump --data-only --attribute-inserts $EXCLUDE_TABLES_OPTIONS "$POSTGRES_CONN_STRING" > "$POSTGRES_DUMP_FILE" 2>> "$LOG_FILE"
        else
            echo "Skipping PostgreSQL dump file creation (no connection string provided)." >> "$LOG_FILE"
        fi
    fi

    TEMP_SQL_FILE="$(mktemp)"
    trap 'rm -f "$TEMP_SQL_FILE"' EXIT
    echo "Converting PostgreSQL dump file to SQLite3 compatible SQL..."
    sed \
        -e 's/\\\\:/\:/g' \
        -e 's/\\\\//g' \
        -e 's/\\\\;/;/g' \
        -e '/^SET /d' \
        -e '/setval/d' \
        -e "s/'true'/1/g" \
        -e "s/'false'/0/g" \
        -e 's/public\.//' \
        -e '/^[[:space:]]*SELECT/d' \
        "$POSTGRES_DUMP_FILE" > "$TEMP_SQL_FILE"
    echo "Conversion to SQLite3 compatible SQL completed."
    echo "BEGIN TRANSACTION;" > "$TEMP_SQL_FILE.converted"
    cat "$TEMP_SQL_FILE" >> "$TEMP_SQL_FILE.converted"
    echo "COMMIT;" >> "$TEMP_SQL_FILE.converted"
    mv "$TEMP_SQL_FILE.converted" "$TEMP_SQL_FILE"

    echo "Creating SQLite3 database: $SQLITE_DATABASE_FILE" >> "$LOG_FILE"
    rm -f "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1
    touch "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1
    if [ ! -f "$SQLITE_SCHEMA_FILE" ]; then
        echo "SQLite schema file '$SQLITE_SCHEMA_FILE' not found."
        exit 1
    fi
    echo "Creating schema in SQLite3 database from file: $SQLITE_SCHEMA_FILE"
    sqlite3 "$SQLITE_DATABASE_FILE" < "$SQLITE_SCHEMA_FILE"
    echo "Disabling foreign key checks for the import..."
    sqlite3 "$SQLITE_DATABASE_FILE" "PRAGMA foreign_keys=OFF;"
    echo "Importing SQL statements into SQLite3 database..."
    sqlite3 "$SQLITE_DATABASE_FILE" < "$TEMP_SQL_FILE"
    echo "Re-enabling foreign key checks..."
    sqlite3 "$SQLITE_DATABASE_FILE" "PRAGMA foreign_keys=ON;"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo "Import completed successfully in $((DURATION / 60)) minutes and $((DURATION % 60)) seconds."
