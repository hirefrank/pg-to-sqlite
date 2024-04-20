# PostgreSQL to SQLite3 Data Conversion

This Bash script allows you to migrate data from a PostgreSQL database into a SQLite3 database file. It creates a PostgreSQL dump file (if it doesn't already exist), converts the dump file into SQLite3-compatible SQL statements, and imports the data into a new or existing SQLite3 database file.

## Prerequisites

Before running the script, ensure that the following tools are installed on your system:

- `pg_dump` (PostgreSQL client utility)
- `sed` (Stream Editor for filtering and transforming text)
- `sqlite3` (SQLite3 command-line tool)

## Usage
`./migrate.sh <sqlite_database_file> [postgres_connection_string] [sqlite_schema_file]`
- `<sqlite_database_file>`: The path to the SQLite3 database file to create or update.
- `[postgres_connection_string]` (optional): The connection string for the PostgreSQL database. If not provided, the script will skip creating the PostgreSQL dump file.
- `[sqlite_schema_file]` (optional): The path to the SQLite3 schema file. If not provided, the script will use `./schema.sql` by default.

## Script Behavior

1. If the PostgreSQL dump file doesn't exist and the PostgreSQL connection string is provided, the script will create a new dump file using `pg_dump`. The dump file name is derived from the SQLite database file name with the extension `.dump`.
2. If the SQLite3 database file doesn't exist, the script will create a new one.
3. If the SQLite3 database file already exists, the script will prompt you to recreate it or use the existing one.
4. The script converts the PostgreSQL dump file into SQLite3-compatible SQL statements using `sed`.
5. It wraps the SQL statements with `BEGIN TRANSACTION` and `COMMIT` statements.
6. It creates the schema in the SQLite3 database using the provided SQLite3 schema file (or `./schema.sql` if not provided).
7. It disables foreign key checks temporarily for the import process.
8. It imports the converted SQL statements into the SQLite3 database.
9. It re-enables foreign key checks after the import is complete.
10. It cleans up the temporary SQL file.

## Notes

- The script excludes the `_drizzle_migrations` table from the PostgreSQL dump. You can modify the `EXCLUDE_TABLES` array in the script to include or exclude different tables.
- If the PostgreSQL connection string is not provided, the script will skip creating the PostgreSQL dump file.
- The script displays the total execution time at the end.

## License

This project is licensed under the [MIT License](LICENSE).
