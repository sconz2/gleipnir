#!/usr/bin/env bash
# Gleipnir: Claude Code, held in place by three parts of the binding:
#   Týr       managed settings, owned by root, that Claude can't change
#   Gjöll     a firewall for the claude user only
#   Heimdall  change checks after each turn and at the end of each session
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

FILES="$GLEIPNIR_SRC/scripts/files"

NETWORK="$(cfg claude.network allowlist)"
CHECKS="$(cfg claude.checks true)"
AUTOCOMMIT="$(cfg claude.autocommit true)"
PLAYWRIGHT="$(cfg playwright.enabled false)"
case "$NETWORK" in
  allowlist|open) ;;
  *) fail "claude.network must be \"allowlist\" or \"open\"" ;;
esac

# --- Claude Code, from Anthropic's signed apt repository (stable channel) -------
# Installed system-wide and owned by root, so the claude user can't modify it.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o /etc/apt/keyrings/claude-code.asc
key_info="$(gpg --show-keys --with-colons /etc/apt/keyrings/claude-code.asc 2>/dev/null || true)"
if ! grep -q '31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE' <<<"$key_info"; then
  fail "Claude Code's signing key fingerprint doesn't match; stopping"
fi
echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
  > /etc/apt/sources.list.d/claude-code.list
apt-get update -y >/dev/null
apt-get install -y claude-code >/dev/null

claude_bin="$(dpkg -L claude-code | grep -E '/bin/claude$' | head -n 1)"
[ -x "$claude_bin" ] || fail "couldn't find the claude program after installing it"
printf '%s\n' "$claude_bin" > /etc/gleipnir/claude-bin
log "Claude Code $("$claude_bin" --version 2>/dev/null | head -n 1)"

# --- The claude user's git identity, and npm install scripts off -----------------
git_name="$(cfg git.name '')"
git_email="$(cfg git.email '')"
if [ -n "$git_name" ]; then sudo -u claude -H git config --global user.name "$git_name"; fi
if [ -n "$git_email" ]; then sudo -u claude -H git config --global user.email "$git_email"; fi

printf 'ignore-scripts=true\n' > /home/claude/.npmrc
chown root:root /home/claude/.npmrc
chmod 0644 /home/claude/.npmrc

# --- Helpers ---------------------------------------------------------------------
install -m 0755 "$FILES/claude-launcher" /usr/local/bin/claude
install -m 0755 "$FILES/heimdall-check" /usr/local/bin/heimdall-check
install -m 0755 "$FILES/gleipnir-checkpoint" /usr/local/bin/gleipnir-checkpoint
install -m 0755 "$FILES/gjoll-firewall" /usr/local/sbin/gjoll-firewall
install -d -m 0755 /etc/gleipnir/git-hooks
install -m 0755 "$FILES/pre-commit" /etc/gleipnir/git-hooks/pre-commit

printf '%s\n' "$NETWORK" > /etc/gleipnir/claude-network
if [ "$CHECKS" = "true" ]; then touch /etc/gleipnir/heimdall; else rm -f /etc/gleipnir/heimdall; fi
if [ "$AUTOCOMMIT" = "true" ]; then touch /etc/gleipnir/claude-autocommit; else rm -f /etc/gleipnir/claude-autocommit; fi

# --- Týr: managed settings ---------------------------------------------------------
# /etc/claude-code is owned by root: Claude reads these but can't change them,
# and they take priority over any user or project settings.
install -d -m 0755 /etc/claude-code
python3 -I - "$CHECKS" "$AUTOCOMMIT" > /etc/claude-code/managed-settings.json <<'PY'
import json, sys
checks, autocommit = sys.argv[1] == "true", sys.argv[2] == "true"

env_files = [".env", ".env.local", ".env.*.local", ".env.development", ".env.production", ".env.test"]
settings = {
    "env": {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"},
    "includeCoAuthoredBy": False,
    "permissions": {"deny": [f"{verb}(**/{name})" for verb in ("Read", "Edit") for name in env_files]},
}

def hook(command):
    return {"type": "command", "command": command, "timeout": 60}

hooks = {}
if checks:
    hooks["SessionStart"] = [{"hooks": [hook("/usr/local/bin/heimdall-check --hook-start")]}]
stop = []
if autocommit:
    stop.append(hook("/usr/local/bin/gleipnir-checkpoint"))
if checks:
    stop.append(hook("/usr/local/bin/heimdall-check --hook"))
if stop:
    hooks["Stop"] = [{"hooks": stop}]
if hooks:
    settings["hooks"] = hooks

json.dump(settings, sys.stdout, indent=2)
print()
PY
chmod 0644 /etc/claude-code/managed-settings.json

# Instructions Claude reads at the start of every session, also owned by root.
# 09-devserver.sh adds a section about the dev server after this.
{
  cat <<'EOF'
# Gleipnir environment

You're running inside a Gleipnir VM, as the `claude` user.

- The project is in /srv/project. You have no sudo.
- The dev server, if one is running, belongs to the `dev` user. Don't start or restart it.
- The editor on port 8080 belongs to the user, and you can't connect to it.
EOF
  if [ "$NETWORK" = "allowlist" ]; then
    echo "- Your network access is limited to an allowlist. If you need a site that isn't reachable, say so rather than working around it."
  else
    echo "- Your network connections are logged."
  fi
  if [ "$PLAYWRIGHT" = "true" ]; then
    echo "- Playwright's browsers are installed in /opt/playwright. Don't run \`playwright install\`; if a browser is missing, say so."
  fi
  if [ "$AUTOCOMMIT" = "true" ]; then
    cat <<'EOF'

## Git

- Work on the current `wip/` branch. Never commit to `main`, and never push.
- Commit after each logical step, with a clear message that says what changed and why.
- Don't add Co-Authored-By lines or any other attribution to commit messages.
EOF
  fi
} > /etc/claude-code/CLAUDE.md
chmod 0644 /etc/claude-code/CLAUDE.md

# --- Gjöll: the firewall for the claude user ------------------------------------
{
  echo "# Managed by Gleipnir. Add sites with claude.allowed_domains in the machine's config."
  printf '%s\n' api.anthropic.com console.anthropic.com platform.claude.com claude.ai registry.npmjs.org
  cfg claude.allowed_domains ""
} > /etc/gleipnir/allowed-domains

cat > /etc/systemd/system/gjoll-firewall.service <<'EOF'
[Unit]
Description=Gleipnir: Gjöll, the firewall for the claude user
Wants=network-online.target
After=network-online.target systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gjoll-firewall

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/gjoll-firewall.timer <<'EOF'
[Unit]
Description=Gleipnir: refresh Gjöll's allowlist (sites' addresses change)

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable gjoll-firewall.service >/dev/null 2>&1
systemctl enable --now gjoll-firewall.timer >/dev/null 2>&1
/usr/local/sbin/gjoll-firewall --rebuild

/usr/local/sbin/gjoll-firewall --verify || fail "Gjöll didn't verify; Claude would not be contained"
if [ "$NETWORK" = "open" ]; then
  warn "claude.network is \"open\": Claude can reach any site. Its connections are logged (sudo journalctl -k | grep gjoll)."
fi

log "Claude Code ready. Run: vagrant ssh <machine>, then: claude"