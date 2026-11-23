#!/bin/bash
set -euo pipefail

echo "================================================================="
echo "[ATCSDL - De tai 19] Cau hinh AUDIT_TRAIL, ARCHIVELOG & Schema"
echo "================================================================="

ARCHIVE_DIR="/opt/oracle/oradata/archivelog"
mkdir -p "${ARCHIVE_DIR}"

echo "[1/4] Bat AUDIT_TRAIL=DB,EXTENDED va chuyen sang che do ARCHIVELOG..."
sqlplus -S / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET ECHO ON

ALTER SYSTEM SET AUDIT_TRAIL=DB,EXTENDED SCOPE=SPFILE;
ALTER SYSTEM SET AUDIT_SYS_OPERATIONS=TRUE SCOPE=SPFILE;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1='LOCATION=${ARCHIVE_DIR} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=XE' SCOPE=SPFILE;
ALTER SYSTEM SET LOG_ARCHIVE_FORMAT='arch_%t_%s_%r.arc' SCOPE=SPFILE;

SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE OPEN;

DECLARE
  v_mode VARCHAR2(30);
BEGIN
  SELECT open_mode INTO v_mode FROM v\$pdbs WHERE name = 'XEPDB1';
  IF v_mode <> 'READ WRITE' THEN
    EXECUTE IMMEDIATE 'ALTER PLUGGABLE DATABASE XEPDB1 OPEN';
  END IF;
END;
/

ALTER PLUGGABLE DATABASE XEPDB1 SAVE STATE;
ALTER SYSTEM REGISTER;

EXIT;
EOF

echo "[2/4] Tao schema/bang STUDENTS, GRADES va du lieu mau trong XEPDB1..."
sqlplus -S / as sysdba @/opt/sql/01_schema_and_data.sql \
  "${APP_USER:-UNI_APP}" \
  "${APP_USER_PASSWORD:-UniApp123}" \
  "${BRUTEFORCE_USER:-GV_USER}" \
  "${BRUTEFORCE_PASSWORD:-oracle123}"

echo "[3/4] Cau hinh cac luat AUDIT trong XEPDB1 va CDB\$ROOT..."
sqlplus -S / as sysdba @/opt/sql/02_audit_rules.sql "${APP_USER:-UNI_APP}"
sqlplus -S / as sysdba @/opt/sql/03_audit_cdb_rules.sql

echo "[4/4] Tao Archive Log dau tien de kiem chung LogMiner..."
sqlplus -S / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SYSTEM SWITCH LOGFILE;
ARCHIVE LOG LIST;
EXIT;
EOF

echo "================================================================="
echo "[ATCSDL - De tai 19] Hoan tat khoi tao Oracle ha tang Phan 1!"
echo "================================================================="
