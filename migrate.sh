#!/bin/bash

# Check if the minimum required arguments are provided
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <sqlite_database_file> [postgres_connection_string] [sqlite_schema_file]"
    exit 1
fi

START_TIME=$(date +%s)

# Assign the provided arguments to variables
SQLITE_DATABASE_FILE="$1"
POSTGRES_CONN_STRING="${2:-}"
POSTGRES_DUMP_FILE="$(basename "$SQLITE_DATABASE_FILE" .sqlite).dump"  # Derive from the database name
SQLITE_SCHEMA_FILE="${3:-./schema.sql}"  # Default to ./schema.sql if not provided

# Check for pg_dump, sed, sqlite3
for cmd in pg_dump sed sqlite3; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed." >&2
        exit 1
    fi
done

# Define an array of tables to exclude
EXCLUDE_TABLES=("_drizzle_migrations")

# Build the exclude-table options
EXCLUDE_TABLES_OPTIONS=""
for TABLE in "${EXCLUDE_TABLES[@]}"; do
    EXCLUDE_TABLES_OPTIONS+="--exclude-table=$TABLE "
done

# Check if the PostgreSQL dump file exists
if [ -f "$POSTGRES_DUMP_FILE" ]; then
    while true; do
        read -p "PostgreSQL dump file '$POSTGRES_DUMP_FILE' already exists. Do you want to use it or create a new one? [u/C] " uc
        case $uc in
            [Uu]* ) 
                echo "Using existing PostgreSQL dump file: $POSTGRES_DUMP_FILE"
                break
                ;;
            [Cc]* ) 
                echo "Creating a new PostgreSQL dump file: $POSTGRES_DUMP_FILE"
                pg_dump --data-only --inserts $EXCLUDE_TABLES_OPTIONS "$POSTGRES_CONN_STRING" > "$POSTGRES_DUMP_FILE"                break
                ;;
            * ) 
                echo "Please answer use (u) or create (c)."
                ;;
        esac
    done
else
    echo "PostgreSQL dump file '$POSTGRES_DUMP_FILE' not found, creating a new one."
    pg_dump --data-only --inserts $EXCLUDE_TABLES_OPTIONS "$POSTGRES_CONN_STRING" > "$POSTGRES_DUMP_FILE"
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

# Wrap the SQL statements with BEGIN and END transactions
echo "BEGIN TRANSACTION;" > "$TEMP_SQL_FILE"
cat "$POSTGRES_DUMP_FILE" >> "$TEMP_SQL_FILE"
echo "COMMIT;" >> "$TEMP_SQL_FILE"

# Create the SQLite3 database if it doesn't exist or recreate it if the user agrees
if [ -f "$SQLITE_DATABASE_FILE" ]; then
    while true; do
        read -p "The SQLite database '$SQLITE_DATABASE_FILE' already exists. Do you want to recreate it? [y/N] " yn
        case $yn in
            [Yy]* ) 
                echo "Recreating SQLite3 database: $SQLITE_DATABASE_FILE"
                rm "$SQLITE_DATABASE_FILE"
                touch "$SQLITE_DATABASE_FILE"
                break
                ;;
            [Nn]* ) 
                echo "Using existing database."
                break
                ;;
            * ) 
                echo "Please answer yes or no."
                ;;
        esac
    done
else
    echo "Creating SQLite3 database: $SQLITE_DATABASE_FILE"
    touch "$SQLITE_DATABASE_FILE"
fi

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
