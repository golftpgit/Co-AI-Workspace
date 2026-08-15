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
# **No `-g`.** The first version of this used `security find-generic-password -g`
# to list what was stored, which was wrong twice over: `-g` asks for the
# *password*, so it raises an authorisation prompt and the script hangs forever
# in a terminal nobody is watching — and when granted it prints the secret to
# stderr, which is the one thing this script promises never to do. Found by
# running it after the first real key was stored (U33-2).
#
# So it asks a narrower question that needs no authorisation: for each name the
# config files reference, is there an item under it? That is also the question
# worth answering — "this endpoint names a key that was never entered".
SERVICE="com.coaiworkspace.app.secrets"
CHECKED=0
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  # The four fields that hold a secret's *name* (§9.3, §8.2, §12.2, §6.2).
  NAMES=$(grep -rhoE '"(apiKeyEnvironmentVariable|tokenVariable|signingSecretVariable|secretVariable)" *: *"[^"]+"' \
    "$root" 2>/dev/null | sed 's/.*: *"\(.*\)"/\1/' | sort -u)
  for name in $NAMES; do
    CHECKED=$((CHECKED + 1))
    if security find-generic-password -s "$SERVICE" -a "$name" >/dev/null 2>&1; then
      note "“$name” มีค่าเก็บไว้ใน Keychain แล้ว"
    else
      hit "“$name” ถูกอ้างถึงในไฟล์ตั้งค่า แต่ยังไม่มีค่าใน Keychain — ฟีเจอร์ที่ใช้ชื่อนี้จะไม่ทำงาน"
    fi
  done
done
[ "$CHECKED" -eq 0 ] && note "ยังไม่มีไฟล์ตั้งค่าไหนอ้างถึงความลับ"
note "สคริปต์นี้ไม่ถามค่าของความลับ และไม่พิมพ์ออกมาไม่ว่ากรณีใด — ถามแค่ว่ามีหรือไม่มี"

echo ""
if [ "$FOUND" -eq 0 ]; then
  echo "ไม่พบความลับในไฟล์ที่ตรวจ"
else
  echo "พบสิ่งที่ต้องไปดู — ดูรายการด้านบน"
fi
# Reporting, not gating: see the header.
exit 0
