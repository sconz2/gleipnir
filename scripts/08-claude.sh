#!/usr/bin/env bash
# Gleipnir: Claude Code, held in place by three parts of the binding:
#   Týr       managed settings, owned by root, that Claude can't change
#   Gjöll     a firewall and a proxy: Claude reaches only the sites on its list, by name,
#             and only downloads from the package sites (npm, and Composer's)
#   Heimdall  change checks after each turn and at the end of each session
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

FILES="$GLEIPNIR_SRC/scripts/files"
SQUID_DIR=/etc/squid/gleipnir
SSL_DB=/var/spool/squid/ssl_db
CLAUDE_ENV=/etc/gleipnir/claude-env   # the proxy settings, read by the claude launcher
RUNNER_ENV=/etc/gleipnir/runner-env   # the same for the dev servers, read by their service
PROXY_CA=/etc/gleipnir/proxy-ca.crt   # the proxy's certificate authority (public part)
CA_BUNDLE=/etc/gleipnir/ca-bundle.pem # what claude's tools trust: the system's, plus that
CA_HOOK=/etc/ca-certificates/update.d/gleipnir-ca-bundle
RESOLVED_DROPIN=/etc/systemd/system/systemd-resolved.service.d/gleipnir.conf
DBUS_POLICY=/etc/dbus-1/system.d/gleipnir-resolve1.conf

NETWORK="$(cfg claude.network allowlist)"
CHECKS="$(cfg claude.checks true)"
PHP="$(cfg php.enabled false)"
# claude.wip_branch was called claude.autocommit; the old name still works
WIP_BRANCH="$(cfg claude.wip_branch "$(cfg claude.autocommit true)")"
case "$NETWORK" in
  allowlist|open) ;;
  *) fail "claude.network must be \"allowlist\" or \"open\"" ;;
esac

# --- Claude Code, from Anthropic's signed apt repository (stable channel) -------
# Installed system-wide and owned by root, so the claude user can't modify it.
# The signing key is checked by its fingerprint (scripts/versions.sh), and apt trusts only that key.
trusted_key https://downloads.claude.ai/keys/claude-code.asc "$CLAUDE_CODE_KEY_FINGERPRINT" /etc/apt/keyrings/claude-code.gpg
echo "deb [signed-by=/etc/apt/keyrings/claude-code.gpg] https://downloads.claude.ai/claude-code/apt/stable stable main" \
  > /etc/apt/sources.list.d/claude-code.list
rm -f /etc/apt/keyrings/claude-code.asc   # the whole download, as earlier versions kept it
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

# npm's install scripts off. Claude's sessions get the same setting in their environment
# (the managed settings, below), which a project's .npmrc can't override; this file covers
# anything else. Owned by root so claude can't change it. Written with install, which
# replaces anything claude left in its place (such as a link) rather than writing through it.
npmrc="$(mktemp)"
printf 'ignore-scripts=true\n' > "$npmrc"
install -o root -g root -m 0644 "$npmrc" /home/claude/.npmrc
rm -f "$npmrc"

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

# --- Gjöll's proxy: Squid ------------------------------------------------------------
# Every site is checked by name, twice. Most are never decrypted; the package sites are,
# so only downloads get through. See scripts/files/squid.conf.
apt-get install -y squid-openssl >/dev/null
install -d -m 0755 "$SQUID_DIR"

# The package sites: decrypted, downloads only. npm's always; Composer's with PHP
# (Packagist's catalogue, and GitHub, where the packages themselves are downloaded from).
packages=(registry.npmjs.org)
if [ "$PHP" = "true" ]; then
  packages+=(repo.packagist.org packagist.org api.github.com codeload.github.com)
fi
{
  echo "# Managed by Gleipnir: the package sites, decrypted so only downloads get through"
  printf '%s\n' "${packages[@]}"
} > "$SQUID_DIR/package-domains"

# The sites each user may reach. "example.com" is that name only; ".example.com" or
# "*.example.com" is example.com and everything under it.
#   site_list <config key> <file> [built-in sites...]
site_list() {
  local key="$1" file="$2"; shift 2
  python3 -I - "$key" "$file" "$(cfg "$key" '')" "${packages[*]}" "$@" <<'PY'
import re, sys
key, path, extra, packages = sys.argv[1], sys.argv[2], sys.argv[3].split("\n"), sys.argv[4].split()
builtin = sys.argv[5:]
# Names only: the last part must have a letter in it, so addresses like 1.2.3.4 don't count
valid = re.compile(r"^\.?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]([a-z0-9-]*[a-z0-9])?$")
names = set()
for raw in builtin + extra:
    name = raw.strip().lower()
    if not name:
        continue
    if name.startswith("*."):
        name = name[1:]
    if not valid.match(name):
        sys.exit(f"{key}: \"{raw.strip()}\" isn't a site name (use e.g. docs.example.com or .example.com)")
    names.add(name)
    # A wildcard over a package site lets its neighbours through without the downloads-only
    # check (".github.com" lets uploads.github.com through, for example). Allowed, but said.
    if raw not in builtin and name.startswith("."):
        covered_packages = [p for p in packages if p.endswith(name)]
        if covered_packages:
            print(f"    WARNING: {key}: {raw.strip()} also allows sites next to "
                  f"{', '.join(covered_packages)}, which aren't limited to downloads", file=sys.stderr)
# Squid refuses lists where one entry covers another, so keep only the widest
wide = {n[1:] for n in names if n.startswith(".")}
def covered(n):
    bare = n.lstrip(".")
    parts = bare.split(".")
    parents = {".".join(parts[i:]) for i in range(1, len(parts))}
    return (not n.startswith(".") and bare in wide) or bool(parents & wide)
kept = sorted(n for n in names if not covered(n))
with open(path, "w") as fh:
    fh.write(f"# Managed by Gleipnir: set {key} in the machine's config\n")
    if kept:
        fh.write("\n".join(kept) + "\n")
PY
}
# Claude's: what Claude Code needs (Anthropic's network requirements), and the package sites
site_list claude.allowed_domains "$SQUID_DIR/claude-domains" api.anthropic.com claude.ai platform.claude.com "${packages[@]}"
# The dev servers': only what you list. They run the project's code, so by default they
# reach nothing outside the machine.
site_list runner.allowed_domains "$SQUID_DIR/runner-domains"
chmod 0644 "$SQUID_DIR/claude-domains" "$SQUID_DIR/runner-domains" "$SQUID_DIR/package-domains"

# The proxy's own certificate authority, made once per machine. Squid signs a certificate
# with it for each package site it decrypts. Its private key is readable only by root and
# Squid; only claude's tools trust it (through CA_BUNDLE below), never the system as a whole.
rm -f "$SQUID_DIR/bump.pem"   # the previous throwaway certificate, replaced by this
new_ca=no
if [ ! -s "$SQUID_DIR/ca.pem" ] || [ ! -s "$PROXY_CA" ]; then
  stage="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Gleipnir package proxy ($(hostname))" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$stage/key.pem" -out "$stage/cert.pem" >/dev/null 2>&1
  (umask 077; cat "$stage/cert.pem" "$stage/key.pem" > "$SQUID_DIR/ca.pem")
  install -m 0644 "$stage/cert.pem" "$PROXY_CA"
  rm -rf "$stage"
  new_ca=yes
fi
chown root:proxy "$SQUID_DIR/ca.pem"
chmod 0640 "$SQUID_DIR/ca.pem"

# Squid's helper that makes those certificates, and the folder it keeps them in. Emptied
# whenever the authority is new, so no certificate signed by an old one is reused.
certgen="$(dpkg -L squid-openssl 2>/dev/null | grep -E '/security_file_certgen$' | head -n 1 || true)"
[ -x "$certgen" ] || fail "Squid's certificate helper (security_file_certgen) wasn't found in squid-openssl"
if [ "$new_ca" = yes ] || [ ! -d "$SSL_DB" ]; then
  install -d -o proxy -g proxy -m 0750 "$(dirname "$SSL_DB")"
  rm -rf "$SSL_DB"
  sudo -u proxy "$certgen" -c -s "$SSL_DB" -M 4MB >/dev/null
fi

# The bundle claude's tools trust, rebuilt whenever the system's certificates are updated
install -d -m 0755 "$(dirname "$CA_HOOK")"
cat > "$CA_HOOK" <<EOF
#!/bin/sh
# Managed by Gleipnir: the certificates claude's tools trust (the system's, plus the
# proxy's own for the package sites). Run by update-ca-certificates.
[ -f $PROXY_CA ] || exit 0
cat /etc/ssl/certs/ca-certificates.crt $PROXY_CA > $CA_BUNDLE.new && chmod 0644 $CA_BUNDLE.new && mv $CA_BUNDLE.new $CA_BUNDLE
EOF
chmod 0755 "$CA_HOOK"
"$CA_HOOK"

# Ubuntu's own config, kept once for reference
[ -f /etc/squid/squid.conf.ubuntu ] || cp /etc/squid/squid.conf /etc/squid/squid.conf.ubuntu
sed "s#/usr/lib/squid/security_file_certgen#$certgen#" "$FILES/squid.conf" > /etc/squid/squid.conf.new
chmod 0644 /etc/squid/squid.conf.new
mv /etc/squid/squid.conf.new /etc/squid/squid.conf
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

# --- The settings for claude's tools, and the dev servers' ----------------------------------
# The proxy, in both spellings, since tools disagree on which they read. NO_PROXY keeps
# localhost (the dev servers, the database) direct. NODE_USE_ENV_PROXY makes Node's built-in
# fetch use them. The certificate settings make each kind of tool trust the proxy's
# authority as well as the usual ones: OpenSSL, PHP and Composer (SSL_CERT_FILE), curl,
# Python's requests, and Node and npm (NODE_EXTRA_CA_CERTS).
proxy_settings() { # port
  local proxy="http://127.0.0.1:$1"
  echo "HTTPS_PROXY=$proxy"
  echo "https_proxy=$proxy"
  echo "HTTP_PROXY=$proxy"
  echo "http_proxy=$proxy"
  echo "NO_PROXY=localhost,127.0.0.1,::1"
  echo "no_proxy=localhost,127.0.0.1,::1"
  echo "NODE_USE_ENV_PROXY=1"
  echo "SSL_CERT_FILE=$CA_BUNDLE"
  echo "CURL_CA_BUNDLE=$CA_BUNDLE"
  echo "REQUESTS_CA_BUNDLE=$CA_BUNDLE"
  echo "NODE_EXTRA_CA_CERTS=$PROXY_CA"
}
if [ "$NETWORK" = "allowlist" ]; then
  proxy_settings 3128 > "$CLAUDE_ENV"
  proxy_settings 3129 > "$RUNNER_ENV"
  chmod 0644 "$CLAUDE_ENV" "$RUNNER_ENV"
else
  rm -f "$CLAUDE_ENV" "$RUNNER_ENV"
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
    # npm's install scripts off for every command Claude runs. Set here rather than only in
    # ~/.npmrc because a project's own .npmrc (Claude's to write) would override that file;
    # the environment wins over both. Re-enabling takes --ignore-scripts=false on the
    # command itself, which you'd see.
    "npm_config_ignore_scripts": "true",
    # No session links in commits (as well as the attribution settings below)
    "CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION": "1",
    # Your claude.ai connectors (Drive, Gmail and so on) stay out of the sandbox
    "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
    # Updates come through apt; and no plugin marketplace is fetched (see below)
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
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
    # No plugins: they're code from GitHub or your claude.ai account, outside the sandbox.
    # Skills in ~/.claude/skills (like /project-init) aren't plugins and still work.
    "strictKnownMarketplaces": [],
    "syncClaudeAiPlugins": False,
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
# Claude's instructions, /etc/claude-code/CLAUDE.md, are written by 11-claude-md.sh

# --- No name lookups through systemd-resolved, for claude or the dev servers -------------
# Gjöll blocks DNS on the network, but resolved also answers over D-Bus and a socket in
# /run/systemd/resolve. Close both to them, in allowlist mode only (open mode needs DNS).
if [ "$NETWORK" = "allowlist" ]; then
  install -m 0644 "$FILES/gleipnir-resolve1.conf" "$DBUS_POLICY"
  install -d -m 0755 "$(dirname "$RESOLVED_DROPIN")"
  # Applied each time resolved starts (the folder is kept across restarts, so this matters
  # at boot). "+" runs it outside resolved's sandbox; "-" means a failure can't stop resolved.
  printf '[Service]\nExecStartPost=-+/usr/bin/setfacl -m u:claude:---,u:runner:--- /run/systemd/resolve\n' > "$RESOLVED_DROPIN"
  [ -d /run/systemd/resolve ] && setfacl -m u:claude:---,u:runner:--- /run/systemd/resolve
else
  rm -f "$DBUS_POLICY" "$RESOLVED_DROPIN"
  [ -d /run/systemd/resolve ] && setfacl -x u:claude,u:runner /run/systemd/resolve 2>/dev/null || true
fi
systemctl reload dbus 2>/dev/null || true

# --- Nothing of claude's or runner's runs outside their sessions -----------------------------
# Code Claude runs could otherwise leave something to start at the next boot (a cron job, an
# at job, or its own services kept running with "linger"), possibly before Gjöll is up.
for deny in /etc/cron.deny /etc/at.deny; do
  touch "$deny"
  chmod 0644 "$deny"
  for user in claude runner; do
    grep -qx "$user" "$deny" || echo "$user" >> "$deny"
  done
done
for user in claude runner; do
  crontab -r -u "$user" 2>/dev/null || true
  loginctl disable-linger "$user" 2>/dev/null || true
done
if command -v atq >/dev/null; then
  atq | awk '$NF == "claude" || $NF == "runner" { print $1 }' | xargs -r atrm
fi
# polkit: nothing at all for claude or runner (services, linger, power and so on)
install -d -m 0755 /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/40-gleipnir-claude.rules <<'EOF'
// Gleipnir: claude and runner may never be allowed anything through polkit: no services,
// no linger (services of their own kept running, which would start at boot), no power.
polkit.addRule(function (action, subject) {
  if (subject.user === "claude" || subject.user === "runner") {
    return polkit.Result.NO;
  }
  return polkit.Result.NOT_HANDLED;
});
EOF
chmod 0644 /etc/polkit-1/rules.d/40-gleipnir-claude.rules

# --- Gjöll: the firewall -----------------------------------------------------------------
# No longer needed: sites are checked by name in the proxy, not by address
systemctl disable --now gjoll-firewall.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/gjoll-firewall.timer /etc/gleipnir/allowed-domains

# At boot, before the network, logins, cron and the dev servers: nothing of claude's or
# runner's ever runs without it
cat > /etc/systemd/system/gjoll-firewall.service <<'EOF'
[Unit]
Description=Gleipnir: Gjöll, the firewall for claude, the dev servers, the proxy and the database
DefaultDependencies=no
After=local-fs.target
Wants=network-pre.target
Before=network-pre.target systemd-user-sessions.service cron.service atd.service squid.service shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/gjoll-firewall

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gjoll-firewall.service >/dev/null 2>&1
/usr/local/sbin/gjoll-firewall --rebuild || fail "Gjöll's rules couldn't be put in place; the previous ones are unchanged"

# Restart, never reload: a reload reopens the ports without the warm-up after it
systemctl enable squid >/dev/null 2>&1
systemctl restart squid

/usr/local/sbin/gjoll-firewall --verify || fail "Gjöll didn't verify; Claude would not be contained"
if [ "$NETWORK" = "open" ]; then
  warn "claude.network is \"open\": Claude and the dev servers can reach any site. Their connections are logged (sudo journalctl -k | grep gjoll)."
fi

log "Claude Code ready. Run: vagrant ssh <machine>, then: claude"