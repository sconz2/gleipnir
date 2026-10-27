#!/usr/bin/env bash
# Gleipnir: Claude's instructions. Turns claude-instructions.md (in the Gleipnir
# folder) into /etc/claude-code/CLAUDE.md, keeping only the sections that apply
# to this machine. Runs last, so it knows how everything else was set up.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

TEMPLATE="$GLEIPNIR_SRC/claude-instructions.md"
OUT=/etc/claude-code/CLAUDE.md
[ -f "$TEMPLATE" ] || fail "claude-instructions.md is missing from the Gleipnir folder"

# The facts the template can test
WIP_BRANCH="$(cfg claude.wip_branch "$(cfg claude.autocommit true)")"
NETWORK="$(cfg claude.network allowlist)"
PLAYWRIGHT="$(cfg playwright.enabled false)"
DEVSERVER_COMMAND="$(cat /etc/gleipnir/devserver-command 2>/dev/null || true)"

install -d -m 0755 /etc/claude-code
trap 'rm -f "$OUT.new"' EXIT
python3 -I - "$TEMPLATE" "$WIP_BRANCH" "$NETWORK" "$PLAYWRIGHT" "$DEVSERVER_COMMAND" > "$OUT.new" <<'PY'
import re, sys
template, wip_branch, network, playwright, devserver_command = sys.argv[1:6]
facts = {
    "wip_branch": wip_branch == "true",
    "network=allowlist": network == "allowlist",
    "network=open": network == "open",
    "playwright": playwright == "true",
    "devserver": devserver_command != "",
}

with open(template) as fh:
    text = fh.read()

lines = text.splitlines()

# The explanation at the top is for whoever edits the file, not for Claude
start = 0
if lines and lines[0].strip() == "<!--":
    start = next((i + 1 for i, line in enumerate(lines) if line.strip() == "-->"), 0)

out, keep, current = [], True, None
for number, line in enumerate(lines[start:], start + 1):
    stripped = line.strip()
    match = re.fullmatch(r"\{\{\s*if\s+(not\s+)?([\w=]+)\s*\}\}", stripped)
    if match:
        if current:
            sys.exit(f"claude-instructions.md line {number}: {{{{if}}}} inside another; close the first with {{{{end}}}}")
        negate, name = bool(match.group(1)), match.group(2)
        if name not in facts:
            sys.exit(f"claude-instructions.md line {number}: unknown condition \"{name}\" (use: {', '.join(facts)})")
        current, keep = name, facts[name] != negate
        continue
    if re.fullmatch(r"\{\{\s*end\s*\}\}", stripped):
        if not current:
            sys.exit(f"claude-instructions.md line {number}: {{{{end}}}} without an {{{{if}}}}")
        current, keep = None, True
        continue
    if keep:
        out.append(line.replace("{{devserver_command}}", devserver_command))
if current:
    sys.exit(f"claude-instructions.md: {{{{if {current}}}}} is never closed with {{{{end}}}}")

result = "\n".join(out).strip("\n") + "\n"
result = re.sub(r"\n{3,}", "\n\n", result)
sys.stdout.write(result)
PY
chmod 0644 "$OUT.new"
mv "$OUT.new" "$OUT"
log "Claude's instructions written to $OUT"