#!/usr/bin/env python3
"""Read login_Setup_Setting_workflow_conf.xlsx (downloaded from Mega) and export
its values to $GITHUB_ENV so later steps can use them instead of GitHub secrets.

Columns (header row 1, case-insensitive):
  FB_IDENTIFIER, FB_PASSWORD, TS_OAUTH_CLIENT_ID, TS_OAUTH_SECRET, BACKUP_FILE_NAME (optional)

Usage: load-config-from-mega.py <file.xlsx> [identifier_to_select]
  - no identifier -> first row that has a FB_IDENTIFIER
  - identifier    -> the row whose FB_IDENTIFIER matches (case-insensitive)
"""
import os, re, sys, uuid
import openpyxl

path = sys.argv[1]
want = (sys.argv[2] if len(sys.argv) > 2 else "").strip().lower()

wb = openpyxl.load_workbook(path, data_only=True)
ws = wb.worksheets[0]
rows = list(ws.iter_rows(values_only=True))
if not rows:
    sys.exit("config sheet is empty")

header = {}
for i, h in enumerate(rows[0]):
    if h is not None and str(h).strip():
        header[str(h).strip().upper()] = i

def cell(row, name):
    i = header.get(name)
    if i is None or i >= len(row) or row[i] is None:
        return ""
    return str(row[i]).strip()

for need in ("FB_IDENTIFIER", "FB_PASSWORD"):
    if need not in header:
        sys.exit(f"column {need} not found in header row (found: {sorted(header)})")

chosen = None
for row in rows[1:]:
    ident = cell(row, "FB_IDENTIFIER")
    if not ident:
        continue
    if not want or ident.lower() == want:
        chosen = row
        break
if chosen is None:
    sys.exit("no data row found" + (f" for {want}" if want else "") +
             " - fill row 2 of the sheet (row 1 is the header)")

vals = {k: cell(chosen, k) for k in
        ("FB_IDENTIFIER", "FB_PASSWORD", "TS_OAUTH_CLIENT_ID", "TS_OAUTH_SECRET", "BACKUP_FILE_NAME")}

if not vals["FB_PASSWORD"]:
    sys.exit("FB_PASSWORD is empty in the selected row")

# Backup file name: from the sheet if given, otherwise derived from the email.
if not vals["BACKUP_FILE_NAME"]:
    safe = re.sub(r"[^a-z0-9._@-]", "_", vals["FB_IDENTIFIER"].lower())
    vals["BACKUP_FILE_NAME"] = f"fb-session-{safe}.tgz.enc"
elif not vals["BACKUP_FILE_NAME"].endswith(".tgz.enc"):
    vals["BACKUP_FILE_NAME"] += ".tgz.enc"
vals["BACKUP_FILE_NAME"] = re.sub(r"[^A-Za-z0-9._@-]", "_", vals["BACKUP_FILE_NAME"])

env_path = os.environ["GITHUB_ENV"]
with open(env_path, "a") as f:
    for k in ("FB_IDENTIFIER", "FB_PASSWORD", "TS_OAUTH_CLIENT_ID", "TS_OAUTH_SECRET"):
        v = vals[k]
        if not v:
            continue
        if k != "FB_IDENTIFIER":
            for line in v.splitlines():
                if line.strip():
                    print(f"::add-mask::{line}")   # hide in logs
        d = "EOF_" + uuid.uuid4().hex
        f.write(f"{k}<<{d}\n{v}\n{d}\n")
    f.write(f"MEGA_FILE={vals['BACKUP_FILE_NAME']}\n")

print(f"config loaded for {vals['FB_IDENTIFIER']} -> backup file {vals['BACKUP_FILE_NAME']}")
print("tailscale creds in sheet:", bool(vals["TS_OAUTH_CLIENT_ID"] and vals["TS_OAUTH_SECRET"]))
