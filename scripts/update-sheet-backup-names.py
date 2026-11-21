#!/usr/bin/env python3
"""Write uploaded backup names back into the Mega sheet.

Usage: update-sheet-backup-names.py <sheet.xlsx> <results.tsv>
results.tsv lines: <FB_IDENTIFIER> TAB <main backup name> TAB <dated copy name>

For every line: the row of that account gets BACKUP_FILE_NAME = main backup name, and a line is
appended to the sheet "BackupLog" (UTC time, account, main name, dated copy) so every upload is kept.
"""
import datetime, sys
import openpyxl

xlsx, tsv = sys.argv[1], sys.argv[2]
wb = openpyxl.load_workbook(xlsx)
ws = wb.worksheets[0]

hdr = {}
for c in ws[1]:
    if c.value is not None and str(c.value).strip():
        hdr[str(c.value).strip().upper().replace(" ", "_")] = c.column
if "FB_IDENTIFIER" not in hdr:
    sys.exit("FB_IDENTIFIER column not found")
if "BACKUP_FILE_NAME" not in hdr:
    col = ws.max_column + 1
    ws.cell(1, col, "BACKUP_FILE_NAME")
    hdr["BACKUP_FILE_NAME"] = col

if "BackupLog" in wb.sheetnames:
    log = wb["BackupLog"]
else:
    log = wb.create_sheet("BackupLog")
    log.append(["UTC_TIME", "FB_IDENTIFIER", "BACKUP_FILE_NAME", "DATED_COPY"])
    for col, w in zip("ABCD", (20, 34, 52, 60)):
        log.column_dimensions[col].width = w

ident_col = hdr["FB_IDENTIFIER"]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
done = 0
for line in open(tsv, encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 2 or not parts[0]:
        continue
    email, main = parts[0], parts[1]
    dated = parts[2] if len(parts) > 2 else ""
    row = None
    for r in range(2, ws.max_row + 1):
        v = ws.cell(r, ident_col).value
        if v is not None and str(v).strip().lower() == email.strip().lower():
            row = r
            break
    if row is None:
        print(f"WARNING: {email} not found in the sheet, not updated")
        continue
    ws.cell(row, hdr["BACKUP_FILE_NAME"]).value = main
    log.append([now, email, main, dated])
    done += 1
    print(f"row {row}: BACKUP_FILE_NAME = {main}")
wb.save(xlsx)
print(f"sheet updated for {done} account(s)")
