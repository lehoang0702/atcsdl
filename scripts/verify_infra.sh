#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${PROJECT_DIR}/.env" ]; then
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
fi

CONTAINER_NAME="${CONTAINER_NAME:-atcsdl-oracle21c}"
ORACLE_PASSWORD="${ORACLE_PASSWORD:-OracleAdmin123}"
APP_USER="${APP_USER:-UNI_APP}"
APP_USER_PASSWORD="${APP_USER_PASSWORD:-UniApp123}"
BRUTEFORCE_USER="${BRUTEFORCE_USER:-GV_USER}"
BRUTEFORCE_PASSWORD="${BRUTEFORCE_PASSWORD:-oracle123}"

echo "=== [1/6] Kiem tra trang thai container & healthcheck ==="
docker inspect --format 'Status={{.State.Status}} Health={{.State.Health.Status}}' "${CONTAINER_NAME}"

echo ""
echo "=== [2/6] Kiem tra AUDIT_TRAIL, ARCHIVELOG, SUPPLEMENTAL LOG & LogMiner ==="
docker exec -i "${CONTAINER_NAME}" sqlplus -S / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET SERVEROUTPUT ON
SET LINESIZE 200
SET PAGESIZE 50
COLUMN name FORMAT A25
COLUMN value FORMAT A80
SELECT name, value FROM v\$parameter WHERE name IN ('audit_trail', 'audit_sys_operations', 'log_archive_dest_1') ORDER BY name;
SELECT log_mode, supplemental_log_data_min, current_scn FROM v\$database;
SELECT count(*) AS archived_logs_count FROM v\$archived_log WHERE deleted = 'NO';
SELECT status AS logmnr_pkg_status FROM dba_objects WHERE owner = 'SYS' AND object_name = 'DBMS_LOGMNR' AND object_type = 'PACKAGE';
DECLARE
  v_log VARCHAR2(512);
  v_cnt NUMBER;
BEGIN
  SELECT name INTO v_log FROM (SELECT name FROM v\$archived_log WHERE deleted = 'NO' ORDER BY sequence# DESC) WHERE ROWNUM = 1;
  DBMS_LOGMNR.ADD_LOGFILE(logfilename => v_log, options => DBMS_LOGMNR.NEW);
  DBMS_LOGMNR.START_LOGMNR(options => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG);
  SELECT COUNT(*) INTO v_cnt FROM v\$logmnr_contents WHERE ROWNUM <= 10;
  DBMS_LOGMNR.END_LOGMNR;
  DBMS_OUTPUT.PUT_LINE('LogMiner smoke test OK (sampled rows=' || v_cnt || ')');
END;
/
EXIT;
EOF

echo ""
echo "=== [3/6] Kiem tra PDB XEPDB1, du lieu STUDENTS & GRADES ==="
docker exec -i "${CONTAINER_NAME}" sqlplus -S "${APP_USER}/${APP_USER_PASSWORD}@localhost:1521/XEPDB1" <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET LINESIZE 200
COLUMN student_code FORMAT A12
COLUMN full_name FORMAT A22
COLUMN class_name FORMAT A10
SELECT 'STUDENTS_COUNT=' || COUNT(*) AS info FROM STUDENTS;
SELECT 'GRADES_COUNT='   || COUNT(*) AS info FROM GRADES;
SELECT student_code, full_name, class_name, gpa FROM STUDENTS ORDER BY student_id FETCH FIRST 3 ROWS ONLY;
EXIT;
EOF

echo ""
echo "=== [4/6] Kiem tra cac luat AUDIT dang kich hoat trong XEPDB1 ==="
docker exec -i "${CONTAINER_NAME}" sqlplus -S / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET SERVEROUTPUT ON
SET LINESIZE 200
SET PAGESIZE 100
COLUMN owner FORMAT A15
COLUMN object_name FORMAT A22
COLUMN audit_option FORMAT A25
COLUMN privilege FORMAT A25
ALTER SESSION SET CONTAINER = XEPDB1;
SELECT audit_option, success, failure FROM dba_stmt_audit_opts ORDER BY audit_option;
SELECT privilege, success, failure FROM dba_priv_audit_opts ORDER BY privilege;
SELECT owner, object_name, sel, ins, upd, del FROM dba_obj_audit_opts WHERE owner IN (UPPER('${APP_USER}'), 'SYS') ORDER BY owner, object_name;
EXIT;
EOF

echo ""
echo "=== [5/6] Kiem tra ket noi tai khoan Brute-force (${BRUTEFORCE_USER}) ==="
docker exec -i "${CONTAINER_NAME}" sqlplus -S "${BRUTEFORCE_USER}/${BRUTEFORCE_PASSWORD}@localhost:1521/XEPDB1" <<EOF
SELECT USER AS connected_user, COUNT(*) AS visible_grades FROM GRADES;
EXIT;
EOF

echo ""
echo "=== [6/6] Kiem tra toan ven SHA-256 baseline ==="
if [ -f "${PROJECT_DIR}/baseline_sha256.txt" ]; then
  (cd "${PROJECT_DIR}" && sha256sum -c baseline_sha256.txt)
else
  echo "[!] Chua tim thay baseline_sha256.txt. Hay chay ./scripts/export_baseline.sh"
fi
