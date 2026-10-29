#!/usr/bin/env bash
# Gleipnir: Claude Code, held in place by three parts of the binding:
#   Týr       managed settings, owned by root, that Claude can't change
#   Gjöll     a firewall and a proxy: Claude reaches only the sites on its list, by name
#   Heimdall  change checks after each turn and at the end of each session
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

FILES="$GLEIPNIR_SRC/scripts/files"
SQUID_DIR=/etc/squid/gleipnir
CLAUDE_ENV=/etc/gleipnir/claude-env   # the proxy settings, read by the claude launcher
RESOLVED_DROPIN=/etc/systemd/system/systemd-resolved.service.d/gleipnir.conf
DBUS_POLICY=/etc/dbus-1/system.d/gleipnir-resolve1.conf

NETWORK="$(cfg claude.network allowlist)"
CHECKS="$(cfg claude.checks true)"
# claude.wip_branch was called claude.autocommit; the old name still works
WIP_BRANCH="$(cfg claude.wip_branch "$(cfg claude.autocommit true)")"
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
rm -f /usr/local/bin/gleipnir-checkpoint   # no longer used: Claude commits only when you say
install -m 0755 "$FILES/gjoll-firewall" /usr/local/sbin/gjoll-firewall
install -m 0755 "$FILES/gjoll-log" /usr/local/sbin/gjoll-log
install -m 0755 "$FILES/gjoll-proxy-warmup" /usr/local/sbin/gjoll-proxy-warmup
install -d -m 0755 /etc/gleipnir/git-hooks
install -m 0755 "$FILES/pre-commit" /etc/gleipnir/git-hooks/pre-commit
install -m 0755 "$FILES/commit-msg" /etc/gleipnir/git-hooks/commit-msg

printf '%s\n' "$NETWORK" > /etc/gleipnir/claude-network
if [ "$CHECKS" = "true" ]; then touch /etc/gleipnir/heimdall; else rm -f /etc/gleipnir/heimdall; fi
if [ "$WIP_BRANCH" = "true" ]; then touch /etc/gleipnir/claude-autocommit; else rm -f /etc/gleipnir/claude-autocommit; fi

# --- The proxy settings for claude's tools ----------------------------------------------
# Both spellings, since tools disagree on which they read. NO_PROXY keeps localhost (the
# dev server, the database) direct. NODE_USE_ENV_PROXY makes Node's built-in fetch use them.
if [ "$NETWORK" = "allowlist" ]; then
  proxy=http://127.0.0.1:3128
  {
    echo "HTTPS_PROXY=$proxy"
    echo "https_proxy=$proxy"
    echo "HTTP_PROXY=$proxy"
    echo "http_proxy=$proxy"
    echo "NO_PROXY=localhost,127.0.0.1,::1"
    echo "no_proxy=localhost,127.0.0.1,::1"
    echo "NODE_USE_ENV_PROXY=1"
  } > "$CLAUDE_ENV"
  chmod 0644 "$CLAUDE_ENV"
else
  rm -f "$CLAUDE_ENV"
fi

# --- Týr: managed settings ---------------------------------------------------------
# /etc/claude-code is owned by root: Claude reads these but can't change them,
# and they take priority over any user or project settings. Their "env" applies to
# Claude Code and to every command it runs.
install -d -m 0755 /etc/claude-code
python3 -I - "$CHECKS" "$CLAUDE_ENV" > /etc/claude-code/managed-settings.json <<'PY'
import json, os, sys
checks = sys.argv[1] == "true"

env = {
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    # No session links in commits (as well as the attribution settings below)
    "CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION": "1",
    # Your claude.ai connectors (Drive, Gmail and so on) stay out of the sandbox
    "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
}
if os.path.exists(sys.argv[2]):
    with open(sys.argv[2]) as fh:
        for line in fh:
            name, _, value = line.strip().partition("=")
            if name:
                env[name] = value

env_files = [".env", ".env.local", ".env.*.local", ".env.development", ".env.production", ".env.test"]
settings = {
    "env": env,
    # No Claude attribution in commits or pull requests. includeCoAuthoredBy is the
    # older, deprecated setting, kept for older versions of Claude Code.
    "attribution": {"commit": "", "pr": "", "sessionUrl": False},
    "includeCoAuthoredBy": False,
    "disableClaudeAiConnectors": True,
    "permissions": {"deny": [f"{verb}(**/{name})" for verb in ("Read", "Edit") for name in env_files]},
}

def hook(command):
    return {"type": "command", "command": command, "timeout": 60}

if checks:
    settings["hooks"] = {
        "SessionStart": [{"hooks": [hook("/usr/local/bin/heimdall-check --hook-start")]}],
        "Stop": [{"hooks": [hook("/usr/local/bin/heimdall-check --hook")]}],
    }

json.dump(settings, sys.stdout, indent=2)
print()
PY
chmod 0644 /etc/claude-code/managed-settings.json
# Claude's instructions, /etc/claude-code/CLAUDE.md, are written by 10-claude-md.sh

# --- Gjöll's proxy: Squid ------------------------------------------------------------
# Every site is checked by name, twice, and nothing is decrypted. See scripts/files/squid.conf.
apt-get install -y squid-openssl >/dev/null
install -d -m 0755 "$SQUID_DIR"

# The sites each user may reach. "example.com" is that name only; ".example.com" or
# "*.example.com" is example.com and everything under it.
python3 -I - "$SQUID_DIR/claude-domains" "$(cfg claude.allowed_domains '')" <<'PY'
import re, sys
# What Claude Code needs (Anthropic's network requirements), and npm
builtin = ["api.anthropic.com", "claude.ai", "platform.claude.com", "registry.npmjs.org"]
extra = sys.argv[2].split("\n")
valid = re.compile(r"^\.?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
names = set()
for raw in builtin + extra:
    name = raw.strip().lower()
    if not name:
        continue
    if name.startswith("*."):
        name = name[1:]
    if not valid.match(name):
        sys.exit(f"claude.allowed_domains: \"{raw.strip()}\" isn't a site name (use e.g. docs.example.com or .example.com)")
    names.add(name)
# Squid refuses lists where one entry covers another, so keep only the widest
wide = {n[1:] for n in names if n.startswith(".")}
def covered(n):
    bare = n.lstrip(".")
    parts = bare.split(".")
    parents = {".".join(parts[i:]) for i in range(1, len(parts))}
    return (not n.startswith(".") and bare in wide) or bool(parents & wide)
kept = sorted(n for n in names if not covered(n))
with open(sys.argv[1], "w") as fh:
    fh.write("# Managed by Gleipnir: set claude.allowed_domains in the machine's config\n")
    fh.write("\n".join(kept) + "\n")
PY
# The dev servers' list: empty until they get their own user
echo "# Managed by Gleipnir" > "$SQUID_DIR/runner-domains"
chmod 0644 "$SQUID_DIR/claude-domains" "$SQUID_DIR/runner-domains"

# A throwaway certificate for the ports that read the hello. Nothing trusts it and
# nothing is signed with it: those ports only read, pass through or cut.
if [ ! -s "$SQUID_DIR/bump.pem" ]; then
  stage="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Gleipnir proxy (not trusted)" \
    -keyout "$stage/key.pem" -out "$stage/cert.pem" >/dev/null 2>&1
  cat "$stage/cert.pem" "$stage/key.pem" > "$SQUID_DIR/bump.pem"
  rm -rf "$stage"
fi
chown root:proxy "$SQUID_DIR/bump.pem"
chmod 0640 "$SQUID_DIR/bump.pem"

# Ubuntu's own config, kept once for reference
[ -f /etc/squid/squid.conf.ubuntu ] || cp /etc/squid/squid.conf /etc/squid/squid.conf.ubuntu
install -m 0644 "$FILES/squid.conf" /etc/squid/squid.conf
squid -k parse -f /etc/squid/squid.conf >/dev/null 2>&1 \
  || { squid -k parse -f /etc/squid/squid.conf 2>&1 | grep -iE 'error|fatal' >&2; fail "Squid's config didn't parse"; }

# After each start, nudge Squid to check its inner ports again (see gjoll-proxy-warmup)
install -d -m 0755 /etc/systemd/system/squid.service.d
cat > /etc/systemd/system/squid.service.d/gleipnir.conf <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/gjoll-proxy-warmup
Restart=on-failure
RestartSec=5
EOF

# --- No name lookups for claude through systemd-resolved ---------------------------------
# Gjöll blocks DNS on the network, but resolved also answers over D-Bus and a socket in
# /run/systemd/resolve. Close both to claude, in allowlist mode only (open mode needs DNS).
if [ "$NETWORK" = "allowlist" ]; then
  install -m 0644 "$FILES/gleipnir-resolve1.conf" "$DBUS_POLICY"
  install -d -m 0755 "$(dirname "$RESOLVED_DROPIN")"
  # Applied each time resolved starts (the folder is kept across restarts, so this matters
  # at boot). "+" runs it outside resolved's sandbox; "-" means a failure can't stop resolved.
  printf '[Service]\nExecStartPost=-+/usr/bin/setfacl -m u:claude:--- /run/systemd/resolve\n' > "$RESOLVED_DROPIN"
  [ -d /run/systemd/resolve ] && setfacl -m u:claude:--- /run/systemd/resolve
else
  rm -f "$DBUS_POLICY" "$RESOLVED_DROPIN"
  [ -d /run/systemd/resolve ] && setfacl -x u:claude /run/systemd/resolve 2>/dev/null || true
fi
systemctl reload dbus 2>/dev/null || true

# --- Gjöll: the firewall -----------------------------------------------------------------
# No longer needed: sites are checked by name in the proxy, not by address
systemctl disable --now gjoll-firewall.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/gjoll-firewall.timer /etc/gleipnir/allowed-domains

cat > /etc/systemd/system/gjoll-firewall.service <<'EOF'
[Unit]
Description=Gleipnir: Gjöll, the firewall for claude, the proxy and the database
Before=squid.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gjoll-firewall

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gjoll-firewall.service >/dev/null 2>&1
/usr/local/sbin/gjoll-firewall --rebuild

# Restart, never reload: a reload reopens the ports without the warm-up after it
systemctl enable squid >/dev/null 2>&1
systemctl restart squid

/usr/local/sbin/gjoll-firewall --verify || fail "Gjöll didn't verify; Claude would not be contained"
if [ "$NETWORK" = "open" ]; then
  warn "claude.network is \"open\": Claude can reach any site. Its connections are logged (sudo journalctl -k | grep gjoll)."
fi

log "Claude Code ready. Run: vagrant ssh <machine>, then: claude"