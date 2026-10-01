# Oracle to CockroachDB MOLT Subset Verify

A bash script for verifying data consistency between Oracle and CockroachDB databases using time-windowed "slice" tables with the [MOLT](https://www.cockroachlabs.com/docs/molt) verify tool.

## Overview

This tool creates temporary subset tables on both source (Oracle) and target (CockroachDB) databases based on time windows or custom filters, then runs MOLT verify to check data consistency without scanning entire tables.

### Key Features

- **Time-windowed verification**: Verify only recent data (e.g., last 24 hours)
- **Batch processing**: Verify multiple table mappings in a single run
- **Custom filters**: Support for time-based and range-based filters
- **Template placeholders**: `{{CUTOFF_UTC}}` automatically converts to database-specific timestamp syntax
- **Detailed reporting**: Generates human-readable summaries of mismatches
- **Clean up**: Optionally removes temporary slice tables after verification

## Requirements

### Software Dependencies

- **MOLT** (Oracle-enabled binary) - [Download from Cockroach Labs](https://www.cockroachlabs.com/docs/molt)
- **Oracle Instant Client** - Required for Oracle connectivity
- **Oracle CLI client**: 
  - `sql` (Oracle SQLcl) - Recommended
  - OR `sqlplus` (SQL*Plus)
- **CockroachDB CLI**: `cockroach` command
- **Standard Unix tools**: `jq`, `awk`, `date`, `sed`, `cut`, `tr`

### Oracle Setup

1. Download and extract Oracle Instant Client (23.3, 23.8, or 21.13)
2. Set `ORACLE_LIB_DIR` in config or place in a standard location:
   - `~/Downloads/instantclient_*`
   - `/opt/oracle/instantclient_*`
   - `/usr/lib/oracle/*/client64/lib`

## Installation

```bash
# Clone the repository
git clone https://github.com/ram-sankaran/oracle-crdb-molt-subset-verify.git
cd oracle-crdb-molt-subset-verify

# Make the script executable
chmod +x verify.sh

# Create your config file
cp params.conf.example params.conf
# Edit params.conf with your database credentials and table mappings
```

## Configuration

Edit `params.conf` with your environment settings:

### Required Settings

```bash
# Oracle source
SOURCE_HOST=oracle.example.com
SOURCE_PORT=1521
SOURCE_SERVICE=ORCL
SOURCE_USER=your_user
ORACLE_PASSWORD=your_password
SOURCE_BASE_SCHEMA=ADMIN          # Schema containing source tables
SOURCE_SLICE_SCHEMA=TEST          # Schema for temporary slice tables

# CockroachDB target
TARGET_HOST=localhost
TARGET_PORT=26257
TARGET_BASE_DB=defaultdb          # Database containing target tables
TARGET_SLICE_DB=test              # Database for temporary slice tables
TARGET_USER=root
CRDB_PASSWORD=                    # Optional
TARGET_SSLMODE=disable
TGT_SCHEMA=public

# Window configuration
WINDOW_HOURS=24                   # Time window for filtering

# Paths
ORACLE_LIB_DIR=/path/to/instantclient_23_3
ORACLE_CLIENT=/path/to/sqlcl/bin/sql
MOLT_BIN=/path/to/molt

# Behavior
KEEP_SLICE_TABLES=false           # Set to true to keep slice tables after verify
```

### Table Mappings

Define table mappings in the format: `SRC_TABLE:TGT_TABLE:PK_COLUMNS:FILTER_EXPR`

```bash
TABLE_MAPPINGS="
ORDERS:orders:id:last_updated_ts >= {{CUTOFF_UTC}}
CUSTOMERS:customers:id:last_updated_ts >= {{CUTOFF_UTC}}
LINE_ITEMS:line_items:order_id,line_id:last_updated_ts >= {{CUTOFF_UTC}}
EVENTS:events:event_id:event_time >= {{CUTOFF_UTC}}
"
```

**Filter Expression Examples:**

- Time-based: `last_updated_ts >= {{CUTOFF_UTC}}`
- Range-based: `id BETWEEN 1000 AND 2000`
- Custom: `status = 'ACTIVE' AND created_date >= {{CUTOFF_UTC}}`

The `{{CUTOFF_UTC}}` placeholder is automatically replaced with:
- **Oracle**: `TO_TIMESTAMP_TZ('2026-04-10 11:00:00 UTC','YYYY-MM-DD HH24:MI:SS TZR')`
- **CockroachDB**: `'2026-04-10 11:00:00+00:00'::timestamptz`

## Usage

### Basic Usage

```bash
./verify.sh --config params.conf
```

### Command-line Options

```bash
./verify.sh --config params.conf [options]

Options:
  --config FILE           Path to params.conf (required)
  --window-hours N        Override window size in hours
  --oracle-lib-dir PATH   Override Oracle client library directory
  --keep-slice-tables     Do not drop slice tables after verify
  --molt-bin PATH         Path to molt binary
  --oracle-client CMD     Oracle client command (sql or sqlplus)
  --molt-extra-flags "F"  Extra flags passed to molt verify
  -h, --help             Show help
```

### Example

```bash
# Verify last 48 hours of data, keeping slice tables
./verify.sh --config params.conf --window-hours 48 --keep-slice-tables

# Use custom molt binary
./verify.sh --config params.conf --molt-bin /usr/local/bin/molt
```

## How It Works

1. **Load Configuration**: Reads database credentials and table mappings from `params.conf`

2. **Calculate Cutoff Time**: Computes UTC timestamp for the time window (e.g., 24 hours ago)

3. **Create Slice Tables**: For each table mapping:
   - Oracle: `SOURCE_SLICE_SCHEMA.TABLE_LAST24H`
   - CockroachDB: `TARGET_SLICE_DB.SCHEMA.table_last24h`
   - Applies filter expressions to subset data
   - Adds primary key constraints

4. **Generate Transforms File**: Creates `molt_transforms_all_LAST24H.json` mapping Oracle slices to CockroachDB slices

5. **Run MOLT Verify**: Executes single MOLT verify command for all table pairs

6. **Generate Reports**:
   - `verify_output_all_LAST24_<timestamp>.jsonl` - Detailed JSONL log
   - `verify_summary_all_LAST24_<timestamp>.txt` - Human-readable summary

7. **Cleanup**: Optionally drops temporary slice tables

## Output Files

### Transform File
```json
{
  "transforms": [
    {
      "id": 1,
      "resource_specifier": {
        "schema": "TEST",
        "table": "ORDERS_LAST24H"
      },
      "table_rename_opts": { "value": "orders_last24h" },
      "schema_rename_opts": { "value": "public" }
    }
  ]
}
```

### JSONL Verify Log
One JSON object per line with verification details:
```jsonl
{"level":"info","table":"orders","message":"starting verify"}
{"level":"warn","type":"data","table":"orders","primary_key":["123"],"message":"missing row"}
```

### Summary Report
Grouped by table with mismatch details:
```
VERIFY SUMMARY
Generated UTC: 20260410T110000Z
Window Hours: 24

TABLE: TEST.ORDERS_LAST24H
pk=123 | kind=MISSING_ON_TARGET | source_values={"id":123,"amount":100.50}

TABLE: TEST.CUSTOMERS_LAST24H
No row-level data mismatches found.
```

## Troubleshooting

### Oracle Client Issues

```bash
# Check Oracle environment
echo $ORACLE_LIB_DIR
echo $LD_LIBRARY_PATH   # Linux
echo $DYLD_LIBRARY_PATH # macOS

# Test Oracle connection
sql user/password@host:port/service
```

### MOLT Issues

```bash
# Test MOLT binary
./molt --version

# Test Oracle connectivity
./molt verify --source "oracle://user:pass@host:port/service" --help
```

### Common Errors

- **"Oracle client library not found"**: Set `ORACLE_LIB_DIR` correctly
- **"MOLT binary not found"**: Update `MOLT_BIN` path
- **"Missing required config"**: Ensure all required variables in `params.conf` are set
- **"Table not found"**: Verify `SOURCE_BASE_SCHEMA` and `TARGET_BASE_DB` settings

## Performance Tips

1. **Use appropriate time windows**: Smaller windows = faster verification
2. **Index filter columns**: Ensure filter columns (e.g., `last_updated_ts`) are indexed
3. **Run during off-peak hours**: Slice table creation can be resource-intensive
4. **Batch related tables**: Group tables with similar data volume

## License

MIT License - see LICENSE file for details

## Contributing

Contributions welcome! Please open an issue or pull request.

## Related Resources

- [MOLT Documentation](https://www.cockroachlabs.com/docs/molt)
- [CockroachDB Migration Overview](https://www.cockroachlabs.com/docs/stable/migration-overview.html)
- [Oracle Instant Client Downloads](https://www.oracle.com/database/technologies/instant-client/downloads.html)
