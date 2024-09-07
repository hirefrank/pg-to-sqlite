#!/bin/bash

# Check if the minimum required arguments are provided
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <sqlite_database_file> [postgres_connection_string] [--reset]" >&2
    exit 1
fi

START_TIME=$(date +%s)
LOG_FILE="migrate_postgres_to_sqlite3.log"
SQLITE_SCHEMA_FILE="./schema.sql"
echo "Starting migration process..." > "$LOG_FILE" # This line will create a new log file or overwrite an existing one

# Define an array of tables to exclude
EXCLUDE_TABLES=("__drizzle_migrations", "ar_internal_metadata", "schema_migrations", "pg_catalog")

# Assign the provided arguments to variables
SQLITE_DATABASE_FILE="$1"
POSTGRES_CONN_STRING="${2:-}"
POSTGRES_DUMP_FILE="$(basename "$SQLITE_DATABASE_FILE" .sqlite).dump"
RESET_FLAG="${3:-}"

if [ "$RESET_FLAG" == "--reset" ]; then
    echo "Resetting environment (cleaning up existing files and recreating SQLite3 database)..." >> "$LOG_FILE"
    rm -f "$POSTGRES_DUMP_FILE" "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1
    touch "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1
fi

# Check for pg_dump, sed, sqlite3
for cmd in pg_dump sed sqlite3; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed." >&2
        exit 1
    fi
done

# Define an array of tables to exclude
EXCLUDE_TABLES=("__drizzle_migrations")

# Build the exclude-table options
EXCLUDE_TABLES_OPTIONS=""
for TABLE in "${EXCLUDE_TABLES[@]}"; do
    EXCLUDE_TABLES_OPTIONS+="--exclude-table=$TABLE "
done

# Create or recreate the SQLite3 database file
if [ -f "$SQLITE_DATABASE_FILE" ]; then
    echo "Recreating SQLite3 database: $SQLITE_DATABASE_FILE" >> "$LOG_FILE"
    rm "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1
fi
echo "Creating SQLite3 database: $SQLITE_DATABASE_FILE" >> "$LOG_FILE"
touch "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1

# Check if the PostgreSQL dump file exists
if [ -f "$POSTGRES_DUMP_FILE" ]; then 
    --attribute-inserts echo "Using existing PostgreSQL dump file: $POSTGRES_DUMP_FILE" >> "$LOG_FILE"
else
    if [ -n "$POSTGRES_CONN_STRING" ]; then
        echo "PostgreSQL dump file '$POSTGRES_DUMP_FILE' not found, creating a new one." >> "$LOG_FILE"
        pg_dump --data-only --attribute-inserts $EXCLUDE_TABLES_OPTIONS "$POSTGRES_CONN_STRING" > "$POSTGRES_DUMP_FILE" 2>> "$LOG_FILE"
    else
        echo "Skipping PostgreSQL dump file creation (no connection string provided)." >> "$LOG_FILE"
    fi
fi

# Create a temporary SQL file and ensure it gets deleted on script exit
TEMP_SQL_FILE="$(mktemp)"
trap 'rm -f "$TEMP_SQL_FILE"' EXIT

# Convert the PostgreSQL dump file to SQL statements compatible with SQLite3
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

# Wrap the SQL statements with BEGIN and COMMIT transactions
echo "BEGIN TRANSACTION;" > "$TEMP_SQL_FILE.converted"
cat "$TEMP_SQL_FILE" >> "$TEMP_SQL_FILE.converted"
echo "COMMIT;" >> "$TEMP_SQL_FILE.converted"

# Now move the fully prepared SQL file into place
mv "$TEMP_SQL_FILE.converted" "$TEMP_SQL_FILE"

# Create or recreate the SQLite3 database file
if [ -f "$SQLITE_DATABASE_FILE" ]; then
    echo "Recreating SQLite3 database: $SQLITE_DATABASE_FILE" >> "$LOG_FILE"
    rm "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1
fi
echo "Creating SQLite3 database: $SQLITE_DATABASE_FILE" >> "$LOG_FILE"
touch "$SQLITE_DATABASE_FILE" >> "$LOG_FILE" 2>&1

# Check if the SQLite schema file exists
if [ ! -f "$SQLITE_SCHEMA_FILE" ]; then
    echo "SQLite schema file '$SQLITE_SCHEMA_FILE' not found."
    exit 1
fi

# Create the schema in the SQLite database
echo "Creating schema in SQLite3 database from file: $SQLITE_SCHEMA_FILE"
sqlite3 "$SQLITE_DATABASE_FILE" < "$SQLITE_SCHEMA_FILE"

# Disable foreign key checks for the import
echo "Disabling foreign key checks for the import..."
sqlite3 "$SQLITE_DATABASE_FILE" "PRAGMA foreign_keys=OFF;"

# Import the SQL statements into SQLite3
echo "Importing SQL statements into SQLite3 database..."
sqlite3 "$SQLITE_DATABASE_FILE" < "$TEMP_SQL_FILE"

# Re-enable foreign key checks after the import
echo "Re-enabling foreign key checks..."
sqlite3 "$SQLITE_DATABASE_FILE" "PRAGMA foreign_keys=ON;"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo "Import completed successfully in $((DURATION / 60)) minutes and $((DURATION % 60)) seconds."
