# Đề tài 19 – Phần 1: Hạ tầng Oracle 21c XE, Audit Trail, ARCHIVELOG & Baseline Metadata

Thư mục này triển khai toàn bộ hạ tầng **Thành viên 1 – Hạ tầng & Audit Trail** cho đề tài:
> *Tìm hiểu về điều tra số phát hiện tấn công cơ sở dữ liệu dựa trên vai trò của siêu dữ liệu dựa trên nhật ký.*

---

## 1. Cấu trúc thư mục

- `docker-compose.yml`, `.env`: Triển khai Oracle Database 21c XE (`gvenzl/oracle-xe:21`) kèm volume bền vững `atcsdl_oracle_data`.
- `init/01_init_oracle.sh`: Script tự động chạy lần đầu khi khởi tạo DB để:
  - Bật `AUDIT_TRAIL=DB,EXTENDED` (`SCOPE=SPFILE`).
  - Bật `ARCHIVELOG` (lưu tại `/opt/oracle/oradata/archivelog`) và `SUPPLEMENTAL LOG DATA` phục vụ **LogMiner**.
  - Khởi tạo schema, bảng `STUDENTS`, `GRADES`, dữ liệu mẫu và các luật `AUDIT`.
- `sql/`:
  - `01_schema_and_data.sql`: Tạo tài khoản ứng dụng `UNI_APP`, tài khoản thử nghiệm `GV_USER`, bảng `STUDENTS`, `GRADES`, public synonym và dữ liệu mẫu.
  - `02_audit_rules.sql`: Bật luật kiểm toán chuẩn (`AUDIT`) trong `XEPDB1` cho cả 4 kịch bản (SQLi, Brute-force, Leo thang đặc quyền, Xóa/tắt Audit).
  - `03_audit_cdb_rules.sql`: Bật luật kiểm toán cơ bản trên `CDB$ROOT`.
- `scripts/`:
  - `export_baseline.sh`: Xuất siêu dữ liệu cơ sở (users, sys privs, role privs, tables, columns, objects, synonyms, audit options, security parameters) ra `baseline_metadata/*.csv`, ghi mốc `CURRENT_SCN` vào `baseline_info.txt`, và tính mã băm SHA-256 vào `baseline_sha256.txt`.
  - `verify_infra.sh`: Kiểm tra tình trạng hoạt động, chế độ `ARCHIVELOG`, `AUDIT_TRAIL`, `DBMS_LOGMNR`, dữ liệu mẫu và xác thực `baseline_sha256.txt`.
- `baseline_sha256.txt`, `baseline_metadata/`, `baseline_info.txt`: Sản phẩm bàn giao cho Thành viên 3.

---

## 2. Cách vận hành (Thành viên 1)

1. Khởi động Oracle 21c XE:
   ```bash
   docker compose up -d
   ```
   *(Theo dõi tiến trình khởi tạo lần đầu bằng `docker logs -f atcsdl-oracle21c` đến khi thấy `DATABASE IS READY TO USE!`.)*

2. Xuất siêu dữ liệu cơ sở & tạo `baseline_sha256.txt`:
   ```bash
   ./scripts/export_baseline.sh
   ```

3. Kiểm tra toàn bộ hạ tầng trước khi bàn giao:
   ```bash
   ./scripts/verify_infra.sh
   ```

*(Lưu ý: Nếu cần reset làm lại từ đầu, chạy `docker compose down -v` rồi `docker compose up -d`. Nếu TV2/TV3 clone repo này về dựng trên máy khác, **bắt buộc chạy lại `./scripts/export_baseline.sh` trước khi tấn công** để chốt lại `baseline_sha256.txt` và `CURRENT_SCN` khớp với chính container vừa khởi tạo.)*

---

## 3. Thông tin bàn giao cho Thành viên 2 (Kịch bản tấn công)

| Hạng mục | Giá trị mặc định (trong `.env`) | Ghi chú |
|---|---|---|
| **Host / Port** | `localhost` (hoặc IP máy chủ) / `1521` | Cổng TCP Oracle Listener |
| **Service Name (PDB)** | `XEPDB1` | Nơi chứa `STUDENTS`, `GRADES`, `UNI_APP`, `GV_USER` |
| **SID (CDB)** | `XE` | Container Database gốc |
| **Tài khoản Web SQLi (KB1)** | `UNI_APP` / `UniApp123` | Sở hữu bảng `STUDENTS` và `GRADES`, không có quyền `DBA` |
| **Tài khoản Brute-force (KB2)** | `GV_USER` / `oracle123` | Dùng profile `LAB_BF_PROFILE` (`FAILED_LOGIN_ATTEMPTS UNLIMITED`), phù hợp chạy Hydra |
| **Tài khoản quản trị (KB3/KB4)** | `SYSTEM` / `OracleAdmin123` | Dùng nếu mô phỏng leo thang / xóa `SYS.AUD$` / `NOAUDIT` |
| **Bảng mục tiêu** | `STUDENTS`, `GRADES` | Có `PUBLIC SYNONYM`, truy vấn được cả `STUDENTS` lẫn `UNI_APP.STUDENTS` |

---

## 4. Thông tin bàn giao cho Thành viên 3 (Phân tích & Điều tra số)

- **File kiểm tra toàn vẹn**: `baseline_sha256.txt` (kiểm tra bằng `sha256sum -c baseline_sha256.txt`).
- **Siêu dữ liệu cơ sở sạch**: Thư mục `baseline_metadata/*.csv` (dùng `diff` để đối chiếu user mới, quyền `DBA` mới, luật audit bị `NOAUDIT`, v.v.).
- **Mốc SCN & thời gian ban đầu**: File `baseline_info.txt` (chứa `CURRENT_SCN` tại thời điểm chốt baseline để nạp vào `DBMS_LOGMNR.START_LOGMNR(STARTSCN => ...)`).
- **Chụp lại siêu dữ liệu sau khi bị tấn công để đối chiếu toàn vẹn & xem diff**:
  ```bash
  ./scripts/export_baseline.sh --current
  # Đối chiếu trực tiếp mã băm baseline với các file vừa chụp trong current_metadata/
  sed 's|baseline_metadata|current_metadata|g' baseline_sha256.txt | sha256sum -c -
  # Xem chi tiết các dòng bị thay đổi
  diff -u baseline_metadata/01_dba_users.csv current_metadata/01_dba_users.csv
  diff -u baseline_metadata/03_dba_role_privs.csv current_metadata/03_dba_role_privs.csv
  diff -u baseline_metadata/08_audit_stmt_opts.csv current_metadata/08_audit_stmt_opts.csv
  ```
