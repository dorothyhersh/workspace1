#!/usr/bin/env python3
"""Write login STATUS and uploaded backup names back into the Mega sheet.

Usage: update-sheet-backup-names.py <sheet.xlsx> <results.tsv> [status.tsv]

results.tsv lines: <FB_IDENTIFIER> TAB <main backup name> TAB <dated copy name>
                   (only accounts whose backup really reached Mega)
status.tsv  lines: <FB_IDENTIFIER> TAB <status>
                   status = active | suspended | wrong_password | needs_attention | login_failed

Per account row in the sheet:
  - uploaded backup  -> BACKUP_FILE_NAME = main backup name, STATUS = active
  - suspended        -> BACKUP_FILE_NAME = EMPTY (no usable backup), STATUS = suspended
  - any other status -> STATUS = that status, BACKUP_FILE_NAME is left untouched
                        (an older good backup is never erased by a failed login)
A STATUS column is added (at the end) when the sheet does not have one yet.
Every change is also appended to the sheet "BackupLog" (UTC time, account, backup, dated copy, status).
"""
import datetime, os, sys
import openpyxl

xlsx = sys.argv[1]
results_tsv = sys.argv[2]
status_tsv = sys.argv[3] if len(sys.argv) > 3 else ""

wb = openpyxl.load_workbook(xlsx)
ws = wb.worksheets[0]

hdr = {}
for c in ws[1]:
    if c.value is not None and str(c.value).strip():
        hdr[str(c.value).strip().upper().replace(" ", "_")] = c.column
if "FB_IDENTIFIER" not in hdr:
    sys.exit("FB_IDENTIFIER column not found")
for name in ("BACKUP_FILE_NAME", "STATUS"):
    if name not in hdr:
        col = max(list(hdr.values()) + [ws.max_column]) + 1
        ws.cell(1, col, name)
        hdr[name] = col

if "BackupLog" in wb.sheetnames:
    log = wb["BackupLog"]
else:
    log = wb.create_sheet("BackupLog")
    log.append(["UTC_TIME", "FB_IDENTIFIER", "BACKUP_FILE_NAME", "DATED_COPY", "STATUS"])
    for col, w in zip("ABCDE", (20, 34, 52, 60, 18)):
        log.column_dimensions[col].width = w
if not log.cell(1, 5).value:
    log.cell(1, 5, "STATUS")


def read_tsv(path):
    rows = []
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            parts = line.rstrip("\n").split("\t")
            if parts and parts[0].strip():
                rows.append(parts)
    return rows


ident_col = hdr["FB_IDENTIFIER"]
rows_by_email = {}
for r in range(2, ws.max_row + 1):
    v = ws.cell(r, ident_col).value
    if v is not None and str(v).strip():
        rows_by_email.setdefault(str(v).strip().lower(), r)

uploaded = {}   # email -> (main, dated)
for p in read_tsv(results_tsv):
    if len(p) >= 2 and p[1]:
        uploaded[p[0].strip().lower()] = (p[1], p[2] if len(p) > 2 else "")
status = {p[0].strip().lower(): p[1].strip().lower() for p in read_tsv(status_tsv) if len(p) >= 2}
# an account that was uploaded but has no status line is active by definition
for e in uploaded:
    status.setdefault(e, "active")

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
done = 0
for email in sorted(set(uploaded) | set(status)):
    row = rows_by_email.get(email)
    if row is None:
        print(f"WARNING: {email} not found in the sheet, not updated")
        continue
    st = status.get(email, "")
    main, dated = uploaded.get(email, ("", ""))
    if st:
        ws.cell(row, hdr["STATUS"]).value = st
    if main:
        ws.cell(row, hdr["BACKUP_FILE_NAME"]).value = main
    elif st == "suspended":
        ws.cell(row, hdr["BACKUP_FILE_NAME"]).value = None   # suspended: no backup name
    log.append([now, email, main, dated, st])
    done += 1
    print(f"row {row}: STATUS = {st or '-'} | BACKUP_FILE_NAME = {main or ('(emptied)' if st == 'suspended' else '(unchanged)')}")
wb.save(xlsx)
print(f"sheet updated for {done} account(s)")
