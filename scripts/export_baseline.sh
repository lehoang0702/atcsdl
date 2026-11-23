#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${PROJECT_DIR}/.env" ]; then
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
fi

CONTAINER_NAME="${CONTAINER_NAME:-atcsdl-oracle21c}"
APP_USER="${APP_USER:-UNI_APP}"
MODE="baseline"
META_DIR_REL="baseline_metadata"
HASH_FILE_REL="baseline_sha256.txt"
INFO_FILE_REL="baseline_info.txt"

if [ "${1:-}" = "--current" ]; then
  MODE="current"
  META_DIR_REL="current_metadata"
  HASH_FILE_REL="current_sha256.txt"
  INFO_FILE_REL="current_info.txt"
fi

META_DIR="${PROJECT_DIR}/${META_DIR_REL}"
HASH_FILE="${PROJECT_DIR}/${HASH_FILE_REL}"
INFO_FILE="${PROJECT_DIR}/${INFO_FILE_REL}"

mkdir -p "${META_DIR}"

run_pdb_query() {
  local sql_body="$1"
  local out_file="$2"
  docker exec -i "${CONTAINER_NAME}" sqlplus -S / as sysdba <<EOF | tr -d '\r' | sed '/^$/d' > "${out_file}"
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 32767
SET TRIMSPOOL ON
SET TRIMOUT ON
SET VERIFY OFF
SET ECHO OFF
ALTER SESSION SET CONTAINER = XEPDB1;
${sql_body}
EXIT;
EOF
}

run_cdb_query() {
  local sql_body="$1"
  local out_file="$2"
  docker exec -i "${CONTAINER_NAME}" sqlplus -S / as sysdba <<EOF | tr -d '\r' | sed '/^$/d' > "${out_file}"
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 32767
SET TRIMSPOOL ON
SET TRIMOUT ON
SET VERIFY OFF
SET ECHO OFF
${sql_body}
EXIT;
EOF
}

echo "[*] Dang xuat sieu du lieu (${MODE}) tu container '${CONTAINER_NAME}'..."

run_pdb_query "
SELECT username || '|' || account_status || '|' || NVL(TO_CHAR(lock_date, 'YYYY-MM-DD HH24:MI:SS'), 'NULL') || '|' || default_tablespace || '|' || temporary_tablespace || '|' || profile || '|' || authentication_type || '|' || oracle_maintained
FROM dba_users
ORDER BY username;
" "${META_DIR}/01_dba_users.csv"

run_pdb_query "
SELECT grantee || '|' || privilege || '|' || admin_option || '|' || common
FROM dba_sys_privs
ORDER BY grantee, privilege;
" "${META_DIR}/02_dba_sys_privs.csv"

run_pdb_query "
SELECT grantee || '|' || granted_role || '|' || admin_option || '|' || default_role || '|' || common
FROM dba_role_privs
ORDER BY grantee, granted_role;
" "${META_DIR}/03_dba_role_privs.csv"

run_pdb_query "
SELECT owner || '|' || table_name || '|' || NVL(tablespace_name, 'NULL') || '|' || status
FROM dba_tables
WHERE owner = UPPER('${APP_USER}')
ORDER BY owner, table_name;
" "${META_DIR}/04_schema_tables.csv"

run_pdb_query "
SELECT owner || '|' || table_name || '|' || column_id || '|' || column_name || '|' || data_type || '|' || data_length || '|' || nullable
FROM dba_tab_columns
WHERE owner = UPPER('${APP_USER}')
ORDER BY owner, table_name, column_id;
" "${META_DIR}/05_schema_columns.csv"

run_pdb_query "
SELECT owner || '|' || object_name || '|' || object_type || '|' || status
FROM dba_objects
WHERE owner = UPPER('${APP_USER}')
ORDER BY owner, object_name, object_type;
" "${META_DIR}/06_schema_objects.csv"

run_pdb_query "
SELECT synonym_name || '|' || table_owner || '|' || table_name
FROM dba_synonyms
WHERE owner = 'PUBLIC' AND table_owner = UPPER('${APP_USER}')
ORDER BY synonym_name;
" "${META_DIR}/07_public_synonyms.csv"

run_pdb_query "
SELECT NVL(user_name, 'ALL') || '|' || NVL(proxy_name, 'NULL') || '|' || audit_option || '|' || success || '|' || failure
FROM dba_stmt_audit_opts
ORDER BY NVL(user_name, 'ALL'), audit_option;
" "${META_DIR}/08_audit_stmt_opts.csv"

run_pdb_query "
SELECT NVL(user_name, 'ALL') || '|' || NVL(proxy_name, 'NULL') || '|' || privilege || '|' || success || '|' || failure
FROM dba_priv_audit_opts
ORDER BY NVL(user_name, 'ALL'), privilege;
" "${META_DIR}/09_audit_priv_opts.csv"

run_pdb_query "
SELECT 'PDB|' || owner || '|' || object_name || '|' || object_type || '|' || alt || '|' || aud || '|' || com || '|' || del || '|' || gra || '|' || ind || '|' || ins || '|' || loc || '|' || ren || '|' || sel || '|' || upd || '|' || exe || '|' || cre || '|' || rea || '|' || wri || '|' || fbk
FROM dba_obj_audit_opts
WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N')
ORDER BY owner, object_name, object_type;
" "${META_DIR}/10_audit_obj_opts.csv"

run_cdb_query "
SELECT 'CDB|' || owner || '|' || object_name || '|' || object_type || '|' || alt || '|' || aud || '|' || com || '|' || del || '|' || gra || '|' || ind || '|' || ins || '|' || loc || '|' || ren || '|' || sel || '|' || upd || '|' || exe || '|' || cre || '|' || rea || '|' || wri || '|' || fbk
FROM dba_obj_audit_opts
WHERE owner = 'SYS' AND object_name = 'AUD\$'
ORDER BY owner, object_name, object_type;
" "${META_DIR}/10_audit_obj_opts.cdb.tmp"
cat "${META_DIR}/10_audit_obj_opts.cdb.tmp" >> "${META_DIR}/10_audit_obj_opts.csv"
rm -f "${META_DIR}/10_audit_obj_opts.cdb.tmp"

run_cdb_query "
SELECT name || '|' || NVL(value, 'NULL')
FROM v\$parameter
WHERE name IN ('audit_trail', 'audit_sys_operations', 'log_archive_dest_1', 'log_archive_format')
UNION ALL
SELECT 'log_mode|' || log_mode FROM v\$database
UNION ALL
SELECT 'supplemental_log_data_min|' || supplemental_log_data_min FROM v\$database
ORDER BY 1;
" "${META_DIR}/11_db_security_config.csv"

# Xuất thông tin neo mốc thời gian và SCN cho TV3 (không đưa vào file hash để tránh biến động SCN làm sai lệch so sánh cấu trúc)
run_cdb_query "
SELECT 'CAPTURED_AT=' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM') FROM dual;
SELECT 'CURRENT_SCN=' || current_scn FROM v\$database;
SELECT 'LOG_MODE=' || log_mode FROM v\$database;
SELECT 'SUPPLEMENTAL_LOG_DATA_MIN=' || supplemental_log_data_min FROM v\$database;
SELECT 'AUDIT_TRAIL=' || value FROM v\$parameter WHERE name = 'audit_trail';
" "${INFO_FILE}"

run_pdb_query "
SELECT 'STUDENTS_ROWS=' || COUNT(*) FROM ${APP_USER}.STUDENTS;
SELECT 'GRADES_ROWS=' || COUNT(*) FROM ${APP_USER}.GRADES;
SELECT 'AUD\$_ROWS=' || COUNT(*) FROM sys.aud\$;
" "${INFO_FILE}.pdb.tmp"
cat "${INFO_FILE}.pdb.tmp" >> "${INFO_FILE}"
rm -f "${INFO_FILE}.pdb.tmp"

# Tính SHA-256 trên toàn bộ các file siêu dữ liệu
(
  cd "${PROJECT_DIR}"
  LC_ALL=C sha256sum "${META_DIR_REL}"/*.csv > "${HASH_FILE_REL}"
)

echo "[+] Da xuat sieu du lieu vao: ${META_DIR}"
echo "[+] Da luu thong tin moc SCN vao: ${INFO_FILE}"
echo "[+] Da tao file ma bam SHA-256: ${HASH_FILE}"
cat "${HASH_FILE}"
