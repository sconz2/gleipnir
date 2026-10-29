#!/usr/bin/env bash
# Gleipnir: Claude's instructions and skills. Turns claude-instructions.md (in the
# Gleipnir folder) into /etc/claude-code/CLAUDE.md, keeping only the sections that
# apply to this machine, and installs the skills in skills/ for the claude user.
# Runs last, so it knows how everything else was set up.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

TEMPLATE="$GLEIPNIR_SRC/claude-instructions.md"
OUT=/etc/claude-code/CLAUDE.md
[ -f "$TEMPLATE" ] || fail "claude-instructions.md is missing from the Gleipnir folder"

# The facts the template can test
WIP_BRANCH="$(cfg claude.wip_branch "$(cfg claude.autocommit true)")"
NETWORK="$(cfg claude.network allowlist)"
PLAYWRIGHT="$(cfg playwright.enabled false)"
PHP="$(cfg php.enabled false)"
PHP_VERSION="$(cfg php.version 8.4)"
if [ -n "${GLEIPNIR_CONTEXT:-}" ]; then CONTEXT=true; else CONTEXT=false; fi
if [ -n "$(cfg apps '')" ]; then APPS_MODE=true; else APPS_MODE=false; fi

install -d -m 0755 /etc/claude-code
apps_file="$(mktemp)"
trap 'rm -f "$OUT.new" "$apps_file"' EXIT
apps > "$apps_file"

python3 -I - "$TEMPLATE" "$WIP_BRANCH" "$NETWORK" "$PLAYWRIGHT" "$CONTEXT" "$PHP" "$PHP_VERSION" \
  "$APPS_MODE" "$apps_file" /etc/gleipnir/devservers > "$OUT.new" <<'PY'
import re, sys
(template, wip_branch, network, playwright, context, php, php_version,
 apps_mode, apps_file, devservers_file) = sys.argv[1:11]

def rows(path):
    try:
        with open(path) as fh:
            return [line.rstrip("\n").split("\t") for line in fh if line.strip()]
    except OSError:
        return []

apps = rows(apps_file)          # name, folder, port, devserver, command
devservers = rows(devservers_file)  # name, folder, port, command

facts = {
    "wip_branch": wip_branch == "true",
    "network=allowlist": network == "allowlist",
    "network=open": network == "open",
    "playwright": playwright == "true",
    "devserver": bool(devservers),
    "context": context == "true",
    "php": php == "true",
    "apps": apps_mode == "true",
}

# Lines that stand for a generated list
def apps_list():
    return [f"- `{a[1]}/`: the {a[0]} app, on port {a[2]}" for a in apps]

def devservers_list():
    if len(devservers) == 1 and devservers[0][1] == ".":
        name, _, port, command = devservers[0]
        return [f"- The dev server runs `{command}` on port {port}."]
    return [f"- {d[0]} (`{d[1]}/`): `{d[3]}` on port {d[2]}" for d in devservers]

generated = {"{{apps}}": apps_list, "{{devservers}}": devservers_list}

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
    if not keep:
        continue
    if stripped in generated:
        out += generated[stripped]()
    else:
        # {{devserver_command}} is from earlier versions, which had one dev server
        first_command = devservers[0][3] if devservers else ""
        out.append(line.replace("{{php_version}}", php_version).replace("{{devserver_command}}", first_command))
if current:
    sys.exit(f"claude-instructions.md: {{{{if {current}}}}} is never closed with {{{{end}}}}")

result = "\n".join(out).strip("\n") + "\n"
result = re.sub(r"\n{3,}", "\n\n", result)
sys.stdout.write(result)
PY
chmod 0644 "$OUT.new"
mv "$OUT.new" "$OUT"
log "Claude's instructions written to $OUT"

# --- Skills: commands like /project-init, from the Gleipnir folder's skills/ ---------
# Copied into the claude user's ~/.claude/skills on every provision, replacing any skill
# of the same name; skills Claude made itself are left alone. The copying is done as
# claude, not root, because claude controls its own home folder.
SKILLS_IN="$GLEIPNIR_SRC/skills"
if [ -d "$SKILLS_IN" ]; then
  stage="$(mktemp -d)"
  cp -R "$SKILLS_IN"/. "$stage"/
  chown -R claude:claude "$stage"
  sudo -u claude -H bash -s "$stage" <<'SH'
set -euo pipefail
stage="$1"
out="$HOME/.claude/skills"
mkdir -p "$out"
for skill in "$stage"/*/; do
  [ -f "$skill/SKILL.md" ] || continue
  name="$(basename "$skill")"
  rm -rf "${out:?}/$name"
  cp -R "$skill" "$out/$name"
  echo "    Skill: /$name"
done
SH
  rm -rf "$stage"
fi