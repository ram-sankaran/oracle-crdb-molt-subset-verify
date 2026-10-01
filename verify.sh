#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# verify_sliced_tables_batch.sh
#
# Oracle -> CockroachDB sliced-table verify helper (Option B: full filter expr)
#
# - Loads all settings from one config file (params.conf)
# - For each mapping:
#     SRC_TABLE:TGT_TABLE:PK_COLUMNS:FILTER_EXPR
#   where FILTER_EXPR is a FULL WHERE expression (without the "WHERE" keyword),
#   for example:
#       last_updated_ts >= {{CUTOFF_UTC}}
#       event_time >= {{CUTOFF_UTC}}
#       id BETWEEN 1000 AND 2000
#
# - {{CUTOFF_UTC}} is replaced by:
#       Oracle: TO_TIMESTAMP_TZ('<UTC_TS> UTC','YYYY-MM-DD HH24:MI:SS TZR')
#       CRDB:   '<UTC_TS>+00:00'::timestamptz
#
# - Creates slice tables on BOTH source and target:
#       Oracle:  SOURCE_SLICE_SCHEMA.SRC_LAST${WINDOW_HOURS}H
#       CRDB:    TARGET_SLICE_DB.TGT_SCHEMA.tgt_last${WINDOW_HOURS}h
#
# - Builds a combined transforms file mapping all Oracle slices -> CRDB slices
# - Runs ONE molt verify
# - Writes:
#     * transforms JSON
#     * JSONL verify log
#     * human summary grouped by table (pk, kind, source/target values)
#
# REQUIREMENTS:
#   - molt (Oracle-enabled) binary in MOLT_BIN
#   - Oracle Instant Client, ORACLE_LIB_DIR set or auto-detectable
#   - Oracle client CLI (sqlcl "sql" or sqlplus) in ORACLE_CLIENT
#   - cockroach CLI
#   - jq, awk, date, sed, cut, tr
#
# CONFIG FILE (params.conf) must define at least:
#
#   SOURCE_HOST=...
#   SOURCE_PORT=1521
#   SOURCE_SERVICE=ORCL
#   SOURCE_USER=...
#   ORACLE_PASSWORD=...
#   SOURCE_BASE_SCHEMA=ADMIN
#   SOURCE_SLICE_SCHEMA=TEST
#
#   TARGET_HOST=localhost
#   TARGET_PORT=26257
#   TARGET_USER=root
#   CRDB_PASSWORD=        # optional, can be empty
#   TARGET_SSLMODE=disable
#   TARGET_BASE_DB=defaultdb
#   TARGET_SLICE_DB=test
#   TGT_SCHEMA=public
#
#   WINDOW_HOURS=24
#
#   ORACLE_LIB_DIR=/path/to/instantclient_23_3
#   ORACLE_CLIENT=/path/to/sqlcl/bin/sql
#   MOLT_BIN=/path/to/molt-latest/molt
#
#   KEEP_SLICE_TABLES=false
#
#   TABLE_MAPPINGS="
#   ORDERS:orders:id:last_updated_ts >= {{CUTOFF_UTC}}
#   CUSTOMERS:customers:id:last_updated_ts >= {{CUTOFF_UTC}}
#   EVENTS:events:event_id:event_time >= {{CUTOFF_UTC}}
#   "
#
###############################################################################

MOLT_BIN="${MOLT_BIN:-molt}"
ORACLE_CLIENT="${ORACLE_CLIENT:-sql}"   # or sqlplus
CONFIG_FILE=""
WINDOW_HOURS="${WINDOW_HOURS:-}"
KEEP_SLICE_TABLES="${KEEP_SLICE_TABLES:-false}"

# Core config variables – default empty, filled by load_config
SOURCE_HOST="${SOURCE_HOST:-}"
SOURCE_PORT="${SOURCE_PORT:-1521}"
SOURCE_SERVICE="${SOURCE_SERVICE:-}"
SOURCE_USER="${SOURCE_USER:-}"
ORACLE_PASSWORD="${ORACLE_PASSWORD:-}"
SOURCE_BASE_SCHEMA="${SOURCE_BASE_SCHEMA:-}"
SOURCE_SLICE_SCHEMA="${SOURCE_SLICE_SCHEMA:-}"

TARGET_HOST="${TARGET_HOST:-}"
TARGET_PORT="${TARGET_PORT:-26257}"
TARGET_USER="${TARGET_USER:-root}"
CRDB_PASSWORD="${CRDB_PASSWORD:-}"
TARGET_SSLMODE="${TARGET_SSLMODE:-disable}"
TARGET_BASE_DB="${TARGET_BASE_DB:-}"
TARGET_SLICE_DB="${TARGET_SLICE_DB:-}"
TGT_SCHEMA="${TGT_SCHEMA:-}"

TABLE_MAPPINGS="${TABLE_MAPPINGS:-}"
MOLT_EXTRA_FLAGS="${MOLT_EXTRA_FLAGS:-}"
ORACLE_LIB_DIR="${ORACLE_LIB_DIR:-}"

ORACLE_CONNECT=""
SOURCE_URI=""
TARGET_URL=""
CUTOFF_UTC=""
SOURCE_SLICE_SCHEMA_MOLT=""
ALL_TRANSFORMS_FILE=""
ALL_VERIFY_OUTPUT_FILE=""
SUMMARY_OUTPUT_FILE=""
RUN_TS_UTC=""
TRANSFORM_ENTRIES_FILE=""
SLICE_REGISTRY_FILE=""
VERIFY_EXIT_CODE=0

usage() {
  cat <<EOF
Usage: $0 --config params.conf [optional overrides]

Options:
  --config FILE           Path to params.conf
  --window-hours N        Window size in hours (used only in slice naming)
  --oracle-lib-dir PATH   Override Oracle client library dir
  --keep-slice-tables     Do not drop slice tables after verify
  --molt-bin PATH         Path to molt binary
  --oracle-client CMD     Oracle client command (sql or sqlplus)
  --molt-extra-flags "F"  Extra flags passed to molt verify
  -h, --help              Show this help

FILTER_EXPR (4th field) semantics:
  - Full SQL expression without "WHERE"
  - Applied as:
      Oracle:  WHERE <FILTER_EXPR_ORACLE>
      CRDB:    WHERE <FILTER_EXPR_CRDB>
  - {{CUTOFF_UTC}} placeholder is supported and substituted per DB.
EOF
  exit 1
}

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Required command not found in PATH: $cmd"
    exit 1
  fi
}

trim_spaces() {
  awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print}'
}

to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

normalize_csv_columns() {
  echo "$1" | awk -F',' '
    {
      for (i = 1; i <= NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        if ($i != "") {
          if (out != "") out = out ","
          out = out $i
        }
      }
      print out
    }'
}

csv_to_oracle_modify_clause() {
  echo "$1" | awk -F',' '
    {
      for (i = 1; i <= NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        if ($i != "") {
          if (out != "") out = out ", "
          out = out $i " NOT NULL"
        }
      }
      print out
    }'
}

str_to_bool() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

load_config() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    err "Config file not found: $file"
    exit 1
  fi
  log "Loading config file: $file"
  set -o allexport
  # shellcheck disable=SC1090
  source "$file"
  set +o allexport
}

validate_positive_integer() {
  local value="$1"
  local name="$2"
  case "$value" in
    ''|*[!0-9]*)
      err "$name must be a positive integer. Got: $value"
      exit 1
      ;;
  esac
  if [[ "$value" -le 0 ]]; then
    err "$name must be greater than zero. Got: $value"
    exit 1
  fi
}

validate_required() {
  local missing=0
  local vars="
SOURCE_HOST
SOURCE_PORT
SOURCE_SERVICE
SOURCE_USER
ORACLE_PASSWORD
SOURCE_BASE_SCHEMA
SOURCE_SLICE_SCHEMA
TARGET_HOST
TARGET_PORT
TARGET_USER
TARGET_SSLMODE
TARGET_BASE_DB
TARGET_SLICE_DB
TGT_SCHEMA
WINDOW_HOURS
TABLE_MAPPINGS
"
  local v
  while IFS= read -r v; do
    v="$(printf '%s' "$v" | trim_spaces)"
    [[ -z "$v" ]] && continue
    if [[ -z "${!v:-}" ]]; then
      err "Missing required config or override: $v"
      missing=1
    fi
  done <<EOF
${vars}
EOF
  if [[ "$missing" -eq 1 ]]; then
    exit 1
  fi
}

get_cutoff_utc() {
  local hours="$1"
  # macOS BSD date
  if date -u -v-"${hours}"H '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
    date -u -v-"${hours}"H '+%Y-%m-%d %H:%M:%S'
    return
  fi
  # GNU date
  if date -u -d "${hours} hours ago" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
    date -u -d "${hours} hours ago" '+%Y-%m-%d %H:%M:%S'
    return
  fi
  err "Unable to compute UTC cutoff: unsupported 'date' implementation."
  exit 1
}

detect_oracle_lib_dir() {
  if [[ -n "${ORACLE_LIB_DIR}" ]]; then
    return
  fi
  local candidates=""
  candidates="${candidates}
${HOME}/Downloads/instantclient_23_3
${HOME}/Downloads/instantclient_23_8
${HOME}/Downloads/instantclient_21_13
${HOME}/instantclient_23_3
${HOME}/instantclient_23_8
${HOME}/instantclient_21_13
/opt/oracle/instantclient_23_3
/opt/oracle/instantclient_23_8
/opt/oracle/instantclient_21_13
/opt/oracle/instantclient
/usr/local/lib
/usr/lib/oracle/23/client64/lib
/usr/lib/oracle/21/client64/lib
/usr/lib/oracle/19.*/client64/lib
"
  local path expanded
  while IFS= read -r path; do
    path="$(printf '%s' "$path" | trim_spaces)"
    [[ -z "$path" ]] && continue
    if [[ "$path" == *"*"* ]]; then
      for expanded in $path; do
        if [[ -d "$expanded" ]]; then
          ORACLE_LIB_DIR="$expanded"
          return
        fi
      done
    else
      if [[ -d "$path" ]]; then
        ORACLE_LIB_DIR="$path"
        return
      fi
    fi
  done <<EOF
${candidates}
EOF
}

setup_oracle_lib_env() {
  detect_oracle_lib_dir
  if [[ -n "${ORACLE_LIB_DIR}" ]]; then
    if [[ ! -d "${ORACLE_LIB_DIR}" ]]; then
      err "Oracle client directory does not exist: ${ORACLE_LIB_DIR}"
      exit 1
    fi
    case "$(uname -s)" in
      Linux)
        export LD_LIBRARY_PATH="${ORACLE_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
        ;;
      Darwin)
        export DYLD_LIBRARY_PATH="${ORACLE_LIB_DIR}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
        ;;
      *)
        warn "Unrecognized OS for Oracle client library setup: $(uname -s)"
        ;;
    esac
    export PATH="${ORACLE_LIB_DIR}:${PATH}"
  else
    warn "ORACLE_LIB_DIR not set and not auto-detected. Oracle may still work if client libs are on loader path."
  fi
}

print_oracle_env_debug() {
  log "Oracle client env:"
  printf '  ORACLE_LIB_DIR=%s\n' "${ORACLE_LIB_DIR:-<not set>}"
  printf '  LD_LIBRARY_PATH=%s\n' "${LD_LIBRARY_PATH:-<not set>}"
  printf '  DYLD_LIBRARY_PATH=%s\n' "${DYLD_LIBRARY_PATH:-<not set>}"
}

escape_password() {
  local raw_password="$1"
  local encoded_password
  if [[ -z "$raw_password" ]]; then
    printf ''
    return
  fi
  encoded_password="$(
    "${MOLT_BIN}" escape-password --password "${raw_password}" 2>&1 \
      | awk 'NF { last=$0 } END { print last }'
  )"
  if [[ -z "${encoded_password}" ]]; then
    encoded_password="${raw_password}"
  fi
  printf '%s' "${encoded_password}"
}

build_source_uri() {
  local encoded_oracle_password
  encoded_oracle_password="$(escape_password "${ORACLE_PASSWORD}")"
  SOURCE_URI="oracle://${SOURCE_USER}:${encoded_oracle_password}@${SOURCE_HOST}:${SOURCE_PORT}/${SOURCE_SERVICE}"
}

build_target_url() {
  local encoded_crdb_password=""
  if [[ -n "${CRDB_PASSWORD:-}" ]]; then
    encoded_crdb_password="$(escape_password "${CRDB_PASSWORD}")"
  fi
  if [[ -n "${encoded_crdb_password}" ]]; then
    TARGET_URL="postgresql://${TARGET_USER}:${encoded_crdb_password}@${TARGET_HOST}:${TARGET_PORT}/${TARGET_SLICE_DB}?sslmode=${TARGET_SSLMODE}"
  else
    TARGET_URL="postgresql://${TARGET_USER}@${TARGET_HOST}:${TARGET_PORT}/${TARGET_SLICE_DB}?sslmode=${TARGET_SSLMODE}"
  fi
}

init_artifacts() {
  RUN_TS_UTC="$(date -u '+%Y%m%dT%H%M%SZ')"
  ALL_TRANSFORMS_FILE="molt_transforms_all_LAST${WINDOW_HOURS}H.json"
  ALL_VERIFY_OUTPUT_FILE="verify_output_all_LAST${WINDOW_HOURS}_${RUN_TS_UTC}.jsonl"
  SUMMARY_OUTPUT_FILE="verify_summary_all_LAST${WINDOW_HOURS}_${RUN_TS_UTC}.txt"
  TRANSFORM_ENTRIES_FILE="$(mktemp)"
  SLICE_REGISTRY_FILE="$(mktemp)"
  rm -f "${ALL_TRANSFORMS_FILE}" "${ALL_VERIFY_OUTPUT_FILE}" "${SUMMARY_OUTPUT_FILE}"
}

# Replace {{CUTOFF_UTC}} in a filter expr with DB-specific literal
subst_cutoff_in_expr_oracle() {
  local expr="$1"
  local ts_literal="TO_TIMESTAMP_TZ('${CUTOFF_UTC} UTC', 'YYYY-MM-DD HH24:MI:SS TZR')"
  printf '%s' "${expr//\{\{CUTOFF_UTC\}\}/${ts_literal}}"
}

subst_cutoff_in_expr_crdb() {
  local expr="$1"
  local ts_literal="'${CUTOFF_UTC}+00:00'::timestamptz"
  printf '%s' "${expr//\{\{CUTOFF_UTC\}\}/${ts_literal}}"
}

create_source_slice_table() {
  local src_table="$1"
  local src_slice_table_sql="$2"
  local pk_not_null_clause="$3"
  local pk_constraint_name="$4"
  local pk_columns_normalized="$5"
  local filter_expr_template="$6"

  local filter_expr_oracle
  filter_expr_oracle="$(subst_cutoff_in_expr_oracle "${filter_expr_template}")"

  log "Creating Oracle source slice table ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql} from ${SOURCE_BASE_SCHEMA}.${src_table} ..."
  "${ORACLE_CLIENT}" "${ORACLE_CONNECT}" <<SQL
SET FEEDBACK ON
WHENEVER SQLERROR EXIT FAILURE
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql} CASCADE CONSTRAINTS';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN
      RAISE;
    END IF;
END;
/
CREATE TABLE ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql} AS
SELECT *
FROM ${SOURCE_BASE_SCHEMA}.${src_table}
WHERE ${filter_expr_oracle};
ALTER TABLE ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql}
  MODIFY (${pk_not_null_clause});
ALTER TABLE ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql}
  ADD CONSTRAINT ${pk_constraint_name} PRIMARY KEY (${pk_columns_normalized});
COMMIT;
EXIT
SQL
  log "Oracle source slice table ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql} created."
}

create_target_slice_table() {
  local tgt_table="$1"
  local tgt_slice_table_sql="$2"
  local filter_expr_template="$3"

  local filter_expr_crdb
  filter_expr_crdb="$(subst_cutoff_in_expr_crdb "${filter_expr_template}")"

  log "Creating CockroachDB target slice table ${TARGET_SLICE_DB}.${TGT_SCHEMA}.${tgt_slice_table_sql} from ${TARGET_BASE_DB}.${TGT_SCHEMA}.${tgt_table} ..."
  local sql
  sql=$(cat <<SQL
DROP TABLE IF EXISTS ${TARGET_SLICE_DB}.${TGT_SCHEMA}.${tgt_slice_table_sql};
CREATE TABLE ${TARGET_SLICE_DB}.${TGT_SCHEMA}.${tgt_slice_table_sql} (
  LIKE ${TARGET_BASE_DB}.${TGT_SCHEMA}.${tgt_table} INCLUDING ALL
);
INSERT INTO ${TARGET_SLICE_DB}.${TGT_SCHEMA}.${tgt_slice_table_sql}
SELECT *
FROM ${TARGET_BASE_DB}.${TGT_SCHEMA}.${tgt_table}
WHERE ${filter_expr_crdb};
SQL
)
  cockroach sql --url "${TARGET_URL}" --execute "$sql" >/dev/null
  log "CockroachDB target slice table ${TARGET_SLICE_DB}.${TGT_SCHEMA}.${tgt_slice_table_sql} created."
}

drop_source_slice_table() {
  local src_slice_table_sql="$1"
  "${ORACLE_CLIENT}" "${ORACLE_CONNECT}" <<SQL
SET FEEDBACK ON
WHENEVER SQLERROR CONTINUE
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql} CASCADE CONSTRAINTS';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -942 THEN
      RAISE;
    END IF;
END;
/
EXIT
SQL
  log "Dropped Oracle source slice table ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql}"
}

drop_target_slice_table() {
  local tgt_slice_table_sql="$1"
  local sql="DROP TABLE IF EXISTS ${TARGET_SLICE_DB}.${TGT_SCHEMA}.${tgt_slice_table_sql};"
  cockroach sql --url "${TARGET_URL}" --execute "$sql" >/dev/null 2>&1 || true
  log "Dropped CockroachDB target slice table ${TARGET_SLICE_DB}.${TGT_SCHEMA}.${tgt_slice_table_sql}"
}

append_transform_entry() {
  local id="$1"
  local src_slice_table_molt="$2"
  local tgt_slice_table_sql="$3"
  cat >> "${TRANSFORM_ENTRIES_FILE}" <<JSON
    {
      "id": ${id},
      "resource_specifier": {
        "schema": "${SOURCE_SLICE_SCHEMA_MOLT}",
        "table": "${src_slice_table_molt}"
      },
      "table_rename_opts": {
        "value": "${tgt_slice_table_sql}"
      },
      "schema_rename_opts": {
        "value": "${TGT_SCHEMA}"
      }
    },
JSON
}

build_all_transforms_file() {
  if [[ ! -s "${TRANSFORM_ENTRIES_FILE}" ]]; then
    err "No transform entries were generated."
    exit 1
  fi
  sed '$ s/,$//' "${TRANSFORM_ENTRIES_FILE}" > "${TRANSFORM_ENTRIES_FILE}.trimmed"
  cat > "${ALL_TRANSFORMS_FILE}" <<JSON
{
  "transforms": [
$(cat "${TRANSFORM_ENTRIES_FILE}.trimmed")
  ]
}
JSON
  log "Wrote combined transforms file: ${ALL_TRANSFORMS_FILE}"
}

prepare_all_slices_and_transforms() {
  local mapping_id=1
  log "Preparing slices for configured table mappings"
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | trim_spaces)"
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    local src tgt pk filter_expr
    src="$(printf '%s' "$line" | cut -d: -f1 | trim_spaces)"
    tgt="$(printf '%s' "$line" | cut -d: -f2 | trim_spaces)"
    pk="$(printf '%s' "$line" | cut -d: -f3 | trim_spaces)"
    filter_expr="$(printf '%s' "$line" | cut -d: -f4- | trim_spaces)"
    if [[ -z "$src" || -z "$tgt" || -z "$pk" || -z "$filter_expr" ]]; then
      warn "Skipping invalid mapping: $line"
      continue
    fi

    local src_slice_table_sql src_slice_table_molt tgt_slice_table_sql
    local pk_columns_normalized pk_not_null_clause pk_constraint_name
    src_slice_table_sql="${src}_LAST${WINDOW_HOURS}H"
    src_slice_table_molt="$(to_upper "${src_slice_table_sql}")"
    tgt_slice_table_sql="${tgt}_last${WINDOW_HOURS}h"
    pk_columns_normalized="$(normalize_csv_columns "${pk}")"
    pk_not_null_clause="$(csv_to_oracle_modify_clause "${pk_columns_normalized}")"
    pk_constraint_name="${src_slice_table_molt}_PK"

    echo
    echo "=================================================="
    echo "PREPARING: ${SOURCE_BASE_SCHEMA}.${src} -> ${TARGET_BASE_DB}.${TGT_SCHEMA}.${tgt}"
    echo "WINDOW NAME SUFFIX: LAST${WINDOW_HOURS}H"
    echo "SOURCE BASE: ${SOURCE_BASE_SCHEMA}.${src}"
    echo "SOURCE SLICE: ${SOURCE_SLICE_SCHEMA}.${src_slice_table_sql}"
    echo "TARGET BASE: ${TARGET_BASE_DB}.${TGT_SCHEMA}.${tgt}"
    echo "TARGET SLICE: ${TARGET_SLICE_DB}.${TGT_SCHEMA}.${tgt_slice_table_sql}"
    echo "PK COLUMNS: ${pk_columns_normalized}"
    echo "FILTER EXPR (template): ${filter_expr}"
    echo "=================================================="

    create_source_slice_table "${src}" "${src_slice_table_sql}" \
      "${pk_not_null_clause}" "${pk_constraint_name}" \
      "${pk_columns_normalized}" "${filter_expr}"

    create_target_slice_table "${tgt}" "${tgt_slice_table_sql}" \
      "${filter_expr}"

    append_transform_entry "${mapping_id}" "${src_slice_table_molt}" "${tgt_slice_table_sql}"

    printf '%s:%s:%s:%s\n' "${src}" "${tgt}" "${src_slice_table_sql}" "${tgt_slice_table_sql}" \
      >> "${SLICE_REGISTRY_FILE}"

    mapping_id=$((mapping_id + 1))
  done <<< "${TABLE_MAPPINGS}"

  build_all_transforms_file
}

run_verify_all() {
  log "Running one MOLT Verify for all sliced tables..."
  set +e
  # shellcheck disable=SC2086
  "${MOLT_BIN}" verify \
    --source "${SOURCE_URI}" \
    --target "${TARGET_URL}" \
    --schema-filter "^${SOURCE_SLICE_SCHEMA_MOLT}$" \
    --table-filter ".*_LAST${WINDOW_HOURS}H$" \
    --transformations-file "${ALL_TRANSFORMS_FILE}" \
    --allow-tls-mode-disable \
    --log-file "${ALL_VERIFY_OUTPUT_FILE}" \
    --logging info \
    --non-interactive \
    ${MOLT_EXTRA_FLAGS}
  VERIFY_EXIT_CODE=$?
  set -e
  if [[ ${VERIFY_EXIT_CODE} -ne 0 ]]; then
    warn "MOLT Verify exited with code ${VERIFY_EXIT_CODE}"
  else
    log "MOLT Verify completed."
  fi
}

write_grouped_summary() {
  {
    echo "VERIFY SUMMARY"
    echo "Generated UTC: ${RUN_TS_UTC}"
    echo "Window Hours (name only): ${WINDOW_HOURS}"
    echo "Source Slice Schema: ${SOURCE_SLICE_SCHEMA}"
    echo "Target Slice DB: ${TARGET_SLICE_DB}"
    echo "Target Schema: ${TGT_SCHEMA}"
    echo
    jq -r '
      select(.level == "warn" and .type == "data")
      | select(
          (.message | contains("missing row")) or
          (.message | contains("extraneous row")) or
          (.message | contains("mismatching row value"))
        )
      | [
          (.table_schema + "." + .table_name),
          ((.primary_key // []) | join(",")),
          (if (.message | contains("missing row")) then "MISSING_ON_TARGET"
           elif (.message | contains("extraneous row")) then "EXTRANEOUS_ON_TARGET"
           elif (.message | contains("mismatching row value")) then "MISMATCH"
           else .message end),
          (if .source_values then (.source_values | tojson) else "" end),
          (if .target_values then (.target_values | tojson) else "" end)
        ]
      | @tsv
    ' "${ALL_VERIFY_OUTPUT_FILE}" | awk -F'\t' '
      {
        table=$1
        if (!seen_line[$0]++) {
          if (!(table in seen_table)) {
            order[++count]=table
            seen_table[table]=1
          }
          line="pk=" $2 " | kind=" $3
          if ($4 != "") line = line " | source_values=" $4
          if ($5 != "") line = line " | target_values=" $5
          details[table] = details[table] line "\n"
        }
      }
      END {
        if (count == 0) {
          print "No row-level data mismatches found."
        } else {
          for (i = 1; i <= count; i++) {
            t = order[i]
            print "TABLE: " t
            printf "%s", details[t]
            print ""
          }
        }
      }
    '
  } > "${SUMMARY_OUTPUT_FILE}"
  log "Summary file written: ${SUMMARY_OUTPUT_FILE}"
}

cleanup_all_slices() {
  if str_to_bool "${KEEP_SLICE_TABLES}"; then
    log "Keeping all slice tables as requested."
    return
  fi
  if [[ ! -f "${SLICE_REGISTRY_FILE}" ]]; then
    return
  fi
  log "Cleaning up all slice tables..."
  while IFS=: read -r src tgt src_slice tgt_slice; do
    [[ -z "${src_slice}" || -z "${tgt_slice}" ]] && continue
    drop_source_slice_table "${src_slice}" || true
    drop_target_slice_table "${tgt_slice}" || true
  done < "${SLICE_REGISTRY_FILE}"
}

cleanup_tmp_files() {
  [[ -n "${TRANSFORM_ENTRIES_FILE:-}" && -f "${TRANSFORM_ENTRIES_FILE}" ]] && rm -f "${TRANSFORM_ENTRIES_FILE}"
  [[ -n "${TRANSFORM_ENTRIES_FILE:-}" && -f "${TRANSFORM_ENTRIES_FILE}.trimmed" ]] && rm -f "${TRANSFORM_ENTRIES_FILE}.trimmed"
  [[ -n "${SLICE_REGISTRY_FILE:-}" && -f "${SLICE_REGISTRY_FILE}" ]] && rm -f "${SLICE_REGISTRY_FILE}"
}

###############################################################################
# Parse CLI
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)            CONFIG_FILE="$2"; shift 2 ;;
    --window-hours)      WINDOW_HOURS="$2"; shift 2 ;;
    --oracle-lib-dir)    ORACLE_LIB_DIR="$2"; shift 2 ;;
    --keep-slice-tables) KEEP_SLICE_TABLES="true"; shift 1 ;;
    --molt-bin)          MOLT_BIN="$2"; shift 2 ;;
    --oracle-client)     ORACLE_CLIENT="$2"; shift 2 ;;
    --molt-extra-flags)  MOLT_EXTRA_FLAGS="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

[[ -n "${CONFIG_FILE}" ]] || usage
load_config "${CONFIG_FILE}"

###############################################################################
# Validate and preflight
###############################################################################
validate_required
validate_positive_integer "${WINDOW_HOURS}" "WINDOW_HOURS"

if command -v "${MOLT_BIN}" >/dev/null 2>&1; then
  MOLT_BIN="$(command -v "${MOLT_BIN}")"
fi
if [[ ! -f "${MOLT_BIN}" || ! -x "${MOLT_BIN}" ]]; then
  err "MOLT binary not found or not executable: ${MOLT_BIN}"
  exit 1
fi

require_cmd "${ORACLE_CLIENT}"
require_cmd awk
require_cmd date
require_cmd tr
require_cmd uname
require_cmd jq
require_cmd sed
require_cmd cut
require_cmd cockroach

setup_oracle_lib_env
print_oracle_env_debug

CUTOFF_UTC="$(get_cutoff_utc "${WINDOW_HOURS}")"
log "Using UTC cutoff for last ${WINDOW_HOURS}h: ${CUTOFF_UTC}"

SOURCE_SLICE_SCHEMA_MOLT="$(to_upper "${SOURCE_SLICE_SCHEMA}")"
ORACLE_CONNECT="${SOURCE_USER}/${ORACLE_PASSWORD}@${SOURCE_HOST}:${SOURCE_PORT}/${SOURCE_SERVICE}"

build_source_uri
build_target_url
init_artifacts

log "DEBUG SOURCE_URI: oracle://${SOURCE_USER}:***@${SOURCE_HOST}:${SOURCE_PORT}/${SOURCE_SERVICE}"
if [[ -n "${CRDB_PASSWORD:-}" ]]; then
  log "DEBUG TARGET_URL: postgresql://${TARGET_USER}:***@${TARGET_HOST}:${TARGET_PORT}/${TARGET_SLICE_DB}?sslmode=${TARGET_SSLMODE}"
else
  log "DEBUG TARGET_URL: postgresql://${TARGET_USER}@${TARGET_HOST}:${TARGET_PORT}/${TARGET_SLICE_DB}?sslmode=${TARGET_SSLMODE}"
fi

###############################################################################
# Main batch flow
###############################################################################
prepare_all_slices_and_transforms
run_verify_all
write_grouped_summary
cleanup_all_slices
cleanup_tmp_files

log "Artifacts:"
log "  Transforms file: ${ALL_TRANSFORMS_FILE}"
log "  Verify log file: ${ALL_VERIFY_OUTPUT_FILE}"
log "  Summary file: ${SUMMARY_OUTPUT_FILE}"

if [[ ${VERIFY_EXIT_CODE} -ne 0 ]]; then
  err "Batch verify finished with errors."
  exit "${VERIFY_EXIT_CODE}"
fi

log "Done."
