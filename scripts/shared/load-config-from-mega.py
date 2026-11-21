#!/usr/bin/env python3
"""Read login_Setup_Setting_workflow_conf.xlsx (downloaded from Mega) and export account
settings so the workflows use them instead of GitHub secrets.

Every column header (row 1) becomes an environment variable of the same name, so extra
per-account settings (FB_PAGE_NAME, REEL_COUNT, ...) only need a new column.
Used columns: FB_IDENTIFIER, FB_PASSWORD, TS_OAUTH_CLIENT_ID, TS_OAUTH_SECRET, BACKUP_FILE_NAME.

Usage: load-config-from-mega.py <file.xlsx> [selector] [--json accounts.json]
  selector  ""                 -> first row (single account)
            "a@x.com"          -> that row only
            "a@x.com,b@x.com"  -> those rows
            "all"              -> every row that has an FB_IDENTIFIER
  --json    also write ALL selected rows (every column, plus MEGA_FILE) to this file; used by
            login-backup.sh to log in several accounts in one run.
The first selected row is exported to $GITHUB_ENV (Tailscale keys come from it).
"""
import json, os, re, sys, uuid
import openpyxl

args = sys.argv[1:]
json_path = None
if "--json" in args:
    i = args.index("--json"); json_path = args[i + 1]; del args[i:i + 2]
path = args[0]
sel = (args[1] if len(args) > 1 else "").strip()

ws = openpyxl.load_workbook(path, data_only=True).worksheets[0]
rows = list(ws.iter_rows(values_only=True))
if not rows:
    sys.exit("config sheet is empty")

header = {}
for i, h in enumerate(rows[0]):
    if h is not None and str(h).strip():
        header[str(h).strip().upper().replace(" ", "_")] = i
for need in ("FB_IDENTIFIER", "FB_PASSWORD"):
    if need not in header:
        sys.exit(f"column {need} not found in header row (found: {sorted(header)})")

BLOCK = {"PATH", "HOME", "SHELL", "USER", "CI", "IFS", "BASH_ENV", "ENV", "LD_PRELOAD",
         "LD_LIBRARY_PATH", "NODE_OPTIONS", "PYTHONPATH", "MEGA_FILE", "ACCOUNTS_JSON"}
SECRET = re.compile(r"PASS|SECRET|TOKEN|KEY|CLIENT_ID", re.I)

def valid(k):
    return bool(re.fullmatch(r"[A-Z][A-Z0-9_]*", k)) and k not in BLOCK \
        and not k.startswith(("GITHUB_", "RUNNER_", "INPUT_", "ACTIONS_"))

def make(row, rownum):
    d = {}
    for k, i in header.items():
        v = "" if i >= len(row) or row[i] is None else str(row[i]).strip()
        if v and valid(k):
            d[k] = v
    ident = d.get("FB_IDENTIFIER", "")
    name = d.get("BACKUP_FILE_NAME", "")
    if not name:
        name = "fb-session-" + re.sub(r"[^a-z0-9._@-]", "_", ident.lower()) + ".tgz.enc"
    elif not name.endswith(".tgz.enc"):
        name += ".tgz.enc"
    name = re.sub(r"[^A-Za-z0-9._@-]", "_", name)
    d["BACKUP_FILE_NAME"] = name
    d["MEGA_FILE"] = name
    d["SHEET_ROW"] = str(rownum)
    return d

everyone = []
for n, row in enumerate(rows[1:], start=2):
    d = make(row, n)
    if d.get("FB_IDENTIFIER"):
        everyone.append(d)

multi = sel.lower() == "all" or "," in sel
if sel.lower() == "all":
    chosen = list(everyone)
elif sel:
    wants = [x.strip().lower() for x in sel.split(",") if x.strip()]
    chosen = [d for d in everyone if d["FB_IDENTIFIER"].lower() in wants]
    missing = [w for w in wants if w not in [d["FB_IDENTIFIER"].lower() for d in chosen]]
    if missing:
        sys.exit("not found in the sheet: " + ", ".join(missing))
else:
    chosen = everyone[:1]
if not chosen:
    sys.exit("no data row found - fill row 2 of the sheet (row 1 is the header)")

ready = []
for d in chosen:
    if not d.get("FB_PASSWORD"):
        if multi:
            print(f"skipping {d['FB_IDENTIFIER']}: FB_PASSWORD is empty"); continue
        sys.exit("FB_PASSWORD is empty in the selected row")
    ready.append(d)
if not ready:
    sys.exit("no account with a password")

# hide every secret of every selected row in the logs
for d in ready:
    for k, v in d.items():
        if SECRET.search(k):
            for line in v.splitlines():
                if line.strip():
                    print(f"::add-mask::{line}")

first = ready[0]
exported = []
with open(os.environ["GITHUB_ENV"], "a") as f:
    for k, v in first.items():
        if k in ("SHEET_ROW",):
            continue
        d = "EOF_" + uuid.uuid4().hex
        f.write(f"{k}<<{d}\n{v}\n{d}\n")
        exported.append(k)
    if json_path:
        f.write(f"ACCOUNTS_JSON={json_path}\n")

if json_path:
    with open(json_path, "w") as jf:
        json.dump(ready, jf)
    os.chmod(json_path, 0o600)

print(f"accounts loaded: {len(ready)} -> " + ", ".join(f"{d['FB_IDENTIFIER']} => {d['MEGA_FILE']}" for d in ready))
print("columns exported (first row):", ", ".join(exported))
