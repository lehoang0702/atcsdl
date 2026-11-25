# Phần 1: Thiết lập Hạ tầng CSDL Oracle 21c XE, Audit Trail, ARCHIVELOG và Baseline Siêu dữ liệu

**Đề tài 19:** *Tìm hiểu về điều tra số phát hiện tấn công cơ sở dữ liệu dựa trên vai trò của siêu dữ liệu dựa trên nhật ký.*  
**Phụ trách Phần 1:** Hạ tầng & Audit Trail.

---

## 1. Mục tiêu của Phần 1

Để phục vụ quá trình thực nghiệm tấn công (Phần 2) và điều tra số đối chiếu nhật ký – siêu dữ liệu (Phần 3), hạ tầng cơ sở dữ liệu mục tiêu cần đáp ứng 4 yêu cầu cốt lõi:

1. **Triển khai hệ quản trị CSDL Oracle 21c XE ổn định trên Docker** kèm dữ liệu giả lập (bảng `STUDENTS` và `GRADES`) có thể tái lập nhanh và lưu trữ bền vững qua volume.
2. **Kích hoạt kiểm toán chuẩn mở rộng (`AUDIT_TRAIL=DB,EXTENDED`)** và bộ luật `AUDIT` phù hợp với cả 4 kịch bản tấn công (SQL Injection, Brute-force, Leo thang đặc quyền, Xóa/vô hiệu hóa dấu vết kiểm toán).
3. **Kích hoạt chế độ `ARCHIVELOG` và `SUPPLEMENTAL LOG DATA`** nhằm bảo toàn toàn bộ lịch sử thay đổi (DML/DDL) trong Redo/Archive Log phục vụ công cụ **Oracle LogMiner (`DBMS_LOGMNR`)**, kể cả khi kẻ tấn công xóa bảng `SYS.AUD$` hoặc chạy `NOAUDIT`.
4. **Xuất siêu dữ liệu cơ sở (Baseline Metadata) và tính mã băm SHA-256** (`baseline_sha256.txt`) làm điểm neo toàn vẹn (Forensic Integrity Anchor) trước khi xảy ra tấn công.

---

## 2. Kiến trúc triển khai hạ tầng

Hệ thống được đóng gói bằng Docker Compose (`docker-compose.yml` và `.env`):

- **Image:** `gvenzl/oracle-xe:21` (Oracle Database 21c Express Edition, kiến trúc Multitenant gồm `CDB$ROOT` SID `XE` và Pluggable Database `XEPDB1`).
- **Cổng kết nối:** TCP `1521`.
- **Lưu trữ bền vững:** Volume `atcsdl_oracle_data` gắn vào `/opt/oracle/oradata` (chứa datafiles, spfile, mật khẩu, và thư mục Archive Log tại `/opt/oracle/oradata/archivelog`).
- **Tự động hóa khởi tạo:** Script `init/01_init_oracle.sh` chạy tự động trong lần khởi tạo đầu tiên, phối hợp với 3 file SQL trong thư mục `sql/`.

### 2.1. Thiết kế tài khoản & lược đồ dữ liệu (`sql/01_schema_and_data.sql`)

Trong PDB `XEPDB1`, hạ tầng khởi tạo các tài khoản và bảng phục vụ thực nghiệm:

| Tài khoản / Đối tượng | Vai trò trong thực nghiệm | Cấu hình chi tiết |
|---|---|---|
| `UNI_APP` | Tài khoản ứng dụng web (KB1 – SQLi) | Sở hữu bảng `STUDENTS` và `GRADES`; chỉ có quyền cơ bản (`CREATE SESSION`, `CREATE TABLE`, `CREATE SEQUENCE`), **không có quyền `DBA`**. |
| `GV_USER` | Tài khoản mục tiêu Brute-force (KB2 – Hydra) | Gán profile `LAB_BF_PROFILE` với `FAILED_LOGIN_ATTEMPTS UNLIMITED` để Hydra thử mật khẩu nhiều lần mà không khóa tài khoản ứng dụng; có quyền `SELECT` trên `STUDENTS`, `GRADES`. |
| `SYSTEM` / `SYS` | Tài khoản quản trị (KB3 & KB4) | Dùng cho mô phỏng leo thang (`CREATE USER`, `GRANT DBA`), vô hiệu hóa kiểm toán (`NOAUDIT`) và xóa nhật ký (`DELETE FROM SYS.AUD$` dưới quyền `SYS AS SYSDBA`). |
| `UNI_APP.STUDENTS` | Bảng thông tin sinh viên (8 bản ghi mẫu) | Các cột: `student_id`, `student_code`, `full_name`, `class_name`, `email`, `username`, `password`, `gpa`. Có `PUBLIC SYNONYM STUDENTS`. |
| `UNI_APP.GRADES` | Bảng điểm nhạy cảm (11 bản ghi mẫu) | Các cột: `grade_id`, `student_id` (FK), `course_code`, `course_name`, `midterm_score`, `final_score`, `total_score`, `letter_grade`, `semester`. Có `PUBLIC SYNONYM GRADES`. |

---

## 3. Cấu hình Audit Trail và ARCHIVELOG cho LogMiner

### 3.1. Tham số hệ thống (`init/01_init_oracle.sh`)

Các tham số tĩnh được ghi vào `SPFILE` trước khi khởi động lại instance sang trạng thái `MOUNT` để bật `ARCHIVELOG`:

```sql
ALTER SYSTEM SET AUDIT_TRAIL=DB,EXTENDED SCOPE=SPFILE;
ALTER SYSTEM SET AUDIT_SYS_OPERATIONS=TRUE SCOPE=SPFILE;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1='LOCATION=/opt/oracle/oradata/archivelog VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=XE' SCOPE=SPFILE;
ALTER SYSTEM SET LOG_ARCHIVE_FORMAT='arch_%t_%s_%r.arc' SCOPE=SPFILE;

SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE OPEN;
```

- **`AUDIT_TRAIL=DB,EXTENDED`:** Ngoài siêu dữ liệu sự kiện (tài khoản, thời gian, hành động, mã trả về `RETURNCODE`), Oracle ghi đầy đủ câu truy vấn thực thi vào cột `SQL_TEXT` (và `SQL_BIND`) trong `SYS.AUD$` / `DBA_AUDIT_TRAIL`, giúp nhận diện trực tiếp payload SQLi (`OR 1=1`, `UNION SELECT`), lệnh `CREATE USER`, `GRANT DBA`, `NOAUDIT`.
- **`AUDIT_SYS_OPERATIONS=TRUE`:** Ghi nhận thao tác của quản trị viên `SYSDBA` ra OS audit trail.
- **`ARCHIVELOG` + `SUPPLEMENTAL LOG DATA`:** Đảm bảo Online Redo Logs được lưu trữ liên tục thành các file `.arc` thay vì bị ghi đè, đồng thời bổ sung ngữ cảnh cần thiết để `DBMS_LOGMNR` tái dựng đầy đủ câu lệnh `SQL_REDO` và mốc `SCN`.

### 3.2. Các luật kiểm toán (`sql/02_audit_rules.sql`, `sql/03_audit_cdb_rules.sql`)

| Kịch bản mục tiêu | Luật `AUDIT` được cấu hình | Tác dụng điều tra số |
|---|---|---|
| KB2 – Brute-force (Hydra) | `AUDIT CREATE SESSION BY ACCESS;` | Ghi nhận các phiên đăng nhập sai (`RETURNCODE = 1017`) và phiên đăng nhập thành công (`RETURNCODE = 0`). |
| KB1 – SQLi & KB4 – Trích xuất `GRADES` | `AUDIT SELECT, INSERT, UPDATE, DELETE ON UNI_APP.STUDENTS BY ACCESS;` và tương tự cho `UNI_APP.GRADES` | Ghi lại mọi truy vấn đọc/sửa/xóa trên 2 bảng mục tiêu kèm `SQL_TEXT`. |
| KB3 – Leo thang đặc quyền | `AUDIT USER`, `AUDIT ROLE`, `AUDIT SYSTEM GRANT`, `AUDIT GRANT ANY PRIVILEGE`, `AUDIT GRANT ANY ROLE` (`BY ACCESS`) | Bắt trực tiếp hành vi `CREATE USER`, `ALTER USER`, `GRANT DBA`. |
| KB4 – Che giấu dấu vết | `AUDIT AUDIT SYSTEM`, `AUDIT DELETE ANY TABLE`, `AUDIT UPDATE ANY TABLE` (trong `XEPDB1`) và `AUDIT DELETE, UPDATE ON SYS.AUD$` (trong `CDB$ROOT`) | Phát hiện hành vi `NOAUDIT` và nỗ lực sửa/xóa bảng nhật ký `SYS.AUD$`. |

---

## 4. Xuất Siêu dữ liệu cơ sở (Baseline Metadata) và Mã băm SHA-256

Script `scripts/export_baseline.sh` trích xuất có sắp xếp (`ORDER BY` cố định, loại trừ cột biến động theo thời gian như `LAST_LOGIN` và các đối tượng cache nội bộ) thành 11 tệp CSV trong `baseline_metadata/`:

1. `01_dba_users.csv` — Danh sách tài khoản, trạng thái khóa, tablespace, profile (`DBA_USERS`).
2. `02_dba_sys_privs.csv` — Quyền hệ thống đã cấp (`DBA_SYS_PRIVS`).
3. `03_dba_role_privs.csv` — Role đã cấp cho từng tài khoản (`DBA_ROLE_PRIVS`).
4. `04_schema_tables.csv` — Bảng thuộc schema `UNI_APP` (`DBA_TABLES`).
5. `05_schema_columns.csv` — Cấu trúc cột của `STUDENTS` và `GRADES` (`DBA_TAB_COLUMNS`).
6. `06_schema_objects.csv` — Danh sách đối tượng trong schema `UNI_APP` (`DBA_OBJECTS`).
7. `07_public_synonyms.csv` — Public synonyms trỏ tới `STUDENTS` và `GRADES` (`DBA_SYNONYMS`).
8. `08_audit_stmt_opts.csv` — Luật audit cấp câu lệnh (`DBA_STMT_AUDIT_OPTS`).
9. `09_audit_priv_opts.csv` — Luật audit cấp đặc quyền (`DBA_PRIV_AUDIT_OPTS`).
10. `10_audit_obj_opts.csv` — Luật audit cấp đối tượng trên các schema không thuộc hệ thống (PDB) và `SYS.AUD$` (CDB).
11. `11_db_security_config.csv` — Tham số bảo mật (`audit_trail`, `audit_sys_operations`, `log_archive_dest_1`, `log_archive_format`, `log_mode`, `supplemental_log_data_min`).

Toàn bộ 11 tệp được băm bằng `sha256sum` vào **`baseline_sha256.txt`**, đồng thời mốc thời gian và `CURRENT_SCN` tại thời điểm chốt baseline được lưu riêng trong **`baseline_info.txt`** (`CURRENT_SCN=3103280`, thời điểm `2026-11-23 12:40:14.720 +07:00`) để Thành viên 3 nạp vào `DBMS_LOGMNR.START_LOGMNR`.

---

## 5. Kết quả kiểm thử nghiệm thu

Chạy script kiểm tra tự động `./scripts/verify_infra.sh` và kiểm thử đối chiếu lặp lại sau khi khởi động lại máy cho kết quả:

- **Trạng thái container:** `Status=running Health=healthy`, lắng nghe trên cổng `1521`.
- **Tham số Audit & Log:** `audit_trail = DB, EXTENDED`, `audit_sys_operations = TRUE`, `log_mode = ARCHIVELOG`, `supplemental_log_data_min = YES`.
- **Kiểm thử LogMiner:** Package `SYS.DBMS_LOGMNR` ở trạng thái `VALID`; đọc thử trực tiếp file `.arc` mới nhất qua `DBMS_LOGMNR.START_LOGMNR` thành công (`LogMiner smoke test OK`).
- **Kiểm thử dữ liệu & truy cập:** Kết nối thành công vào `XEPDB1` bằng cả `UNI_APP` và `GV_USER`, xác nhận `STUDENTS` có 8 dòng, `GRADES` có 11 dòng, và `DBA_AUDIT_TRAIL` ghi nhận đầy đủ câu truy vấn trong `SQL_TEXT`.
- **Kiểm thử tính toàn vẹn và độ ổn định SHA-256:** Chạy `sha256sum -c baseline_sha256.txt` và đối chiếu trực tiếp với bản chụp mới (`./scripts/export_baseline.sh --current`) qua nhiều ngày và sau restart đều đạt **11/11 `OK`**, đảm bảo không phát sinh dương tính giả trước khi Thành viên 2 thực hiện tấn công.

*(Ghi chú trình bày báo cáo: Chèn ảnh chụp màn hình đầu ra của lệnh `./scripts/verify_infra.sh` và nội dung `baseline_sha256.txt` ngay sau mục này làm minh chứng thực nghiệm.)*
