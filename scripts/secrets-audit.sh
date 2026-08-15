#!/bin/bash
# P9.3 — the other half of the secrets audit: the one that looks at *this*
# machine rather than at a temporary directory.
#
# `SecretsAuditTests` proves that the stores, driven normally, write no secret
# to disk. That is the stronger claim, and it runs in CI. It cannot answer a
# different question a person actually has after months of use: **is there a
# credential sitting in my real data directory right now** — left by an older
# build, by a hand-edited file, by a crash log, by a database that was written
# before the rule existed.
#
# So this walks the live directories and looks for credential-shaped strings.
# It reports rather than fails: a hit here is something to go and look at, not
# a broken build, and the patterns are shapes rather than proof.
#
#   scripts/secrets-audit.sh            # the app's data directories
#   scripts/secrets-audit.sh <path>…    # anywhere else
set -uo pipefail

FOUND=0
note() { echo "   • $1"; }
hit()  { echo "   ⚠ $1"; FOUND=1; }

# Where the app keeps things: both the unsandboxed path and the container the
# signed `.app` actually uses. Checking only one is how an audit comes back
# clean because it was looking at the empty directory.
ROOTS=("$@")
if [ ${#ROOTS[@]} -eq 0 ]; then
  ROOTS=(
    "$HOME/Library/Application Support/CoAIWorkspace"
    "$HOME/Library/Containers/com.coaiworkspace.app/Data/Library/Application Support/CoAIWorkspace"
    "$HOME/Library/Logs/CoAIWorkspace"
  )
fi

# Shapes of real credentials from the services this app talks to, plus the
# generic "somebody wrote a password into a config" case. Deliberately narrow:
# a pattern that matches base64 in general would flag every embedding in the
# database and be switched off within a week.
declare -a PATTERNS=(
  'sk-[A-Za-z0-9]\{20,\}'                     # OpenAI-style API key
  'sk-ant-[A-Za-z0-9_-]\{20,\}'               # Anthropic
  '[0-9]\{8,10\}:AA[A-Za-z0-9_-]\{30,\}'      # Telegram bot token
  'xox[baprs]-[A-Za-z0-9-]\{10,\}'            # Slack
  'gh[pousr]_[A-Za-z0-9]\{20,\}'              # GitHub
  'AKIA[0-9A-Z]\{16\}'                        # AWS access key id
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'        # any private key
  'password=[^ "'"'"'&]\{6,\}'                # a password in a connection string
  'PRIVATE_TOKEN=[^ "'"'"']\{8,\}'
)

echo "── secrets audit ──"

for root in "${ROOTS[@]}"; do
  if [ ! -d "$root" ]; then
    note "ไม่มีโฟลเดอร์ $root (ข้าม)"
    continue
  fi
  echo ""
  echo "   ตรวจ $root"
  files=$(find "$root" -type f -size -20M 2>/dev/null | wc -l | tr -d ' ')
  note "ไฟล์ที่ตรวจ $files ไฟล์"
  for pattern in "${PATTERNS[@]}"; do
    # -a so SQLite pages, plists and logs are all searched as text; a secret
    # does not become safe by living in a binary file.
    matches=$(find "$root" -type f -size -20M -print0 2>/dev/null \
      | xargs -0 grep -lsa "$pattern" 2>/dev/null | head -20)
    if [ -n "$matches" ]; then
      while IFS= read -r file; do
        hit "พบข้อความที่มีรูปร่างเป็นความลับ ($pattern) ใน ${file#"$root"/}"
      done <<< "$matches"
    fi
  done
done

echo ""
echo "   ── Keychain ──"
# Names only. This script never prints a secret, for the same reason no screen
# in the app does.
NAMES=$(security find-generic-password -s com.coaiworkspace.app.secrets -g 2>&1 \
  | grep '"acct"' | sed 's/.*"acct"<blob>="\(.*\)"/\1/' || true)
if [ -n "$NAMES" ]; then
  note "มีความลับเก็บไว้ในชื่อ: $NAMES"
else
  note "ยังไม่มีความลับใน Keychain ของแอป (service com.coaiworkspace.app.secrets)"
fi
note "สคริปต์นี้ไม่พิมพ์ค่าของความลับออกมาไม่ว่ากรณีใด — พิมพ์แต่ชื่อ"

echo ""
if [ "$FOUND" -eq 0 ]; then
  echo "ไม่พบความลับในไฟล์ที่ตรวจ"
else
  echo "พบสิ่งที่ต้องไปดู — ดูรายการด้านบน"
fi
# Reporting, not gating: see the header.
exit 0
