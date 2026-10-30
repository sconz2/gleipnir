#!/usr/bin/env bash
# Gleipnir: the browser editor (code-server), running as dev and opening your copy of the
# project. It asks for a password (generated once per machine; see it with the gpass
# shortcut), unless editor.auth is "none".
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

DEV_HOME=/home/dev
USER_DIR="$DEV_HOME/.local/share/code-server/User"
PASSWORD_FILE=/etc/gleipnir/editor-password   # root only; the gpass shortcut reads it
AUTH="$(cfg editor.auth password)"
case "$AUTH" in
  password|none) ;;
  *) fail "editor.auth must be \"password\" or \"none\"" ;;
esac

# --- Install the version in scripts/versions.sh, checked against its checksum --------------
installed="$(dpkg-query -W -f='${Version}' code-server 2>/dev/null || true)"
if [ "$installed" != "$CODE_SERVER_VERSION" ]; then
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) sum="$CODE_SERVER_SHA256_amd64" ;;
    arm64) sum="$CODE_SERVER_SHA256_arm64" ;;
    *) fail "code-server isn't set up for this machine's architecture ($arch)" ;;
  esac
  log "Installing code-server $CODE_SERVER_VERSION"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  deb="$work/code-server_${CODE_SERVER_VERSION}_$arch.deb"
  curl -fsSL -o "$deb" \
    "https://github.com/coder/code-server/releases/download/v$CODE_SERVER_VERSION/code-server_${CODE_SERVER_VERSION}_$arch.deb" \
    || fail "couldn't download code-server $CODE_SERVER_VERSION"
  if [ "$(sha256sum "$deb" | cut -d' ' -f1)" != "$sum" ]; then
    fail "code-server's download didn't match its checksum in scripts/versions.sh; stopping"
  fi
  # The pinned version, even if a newer one is installed (from before versions were pinned)
  apt-get install -y --allow-downgrades "$deb" >/dev/null || fail "code-server didn't install"
fi
rm -rf /root/.config/code-server   # left by older versions of this step; never used
log "code-server $(dpkg-query -W -f='${Version}' code-server 2>/dev/null)"

# --- Where it listens ---------------------------------------------------------------
if id vagrant >/dev/null 2>&1; then
  # In a Vagrant VM: Vagrant forwards this port to your computer's localhost only
  bind="0.0.0.0:8080"
else
  # On a VPS: only reachable through an SSH tunnel, never from the internet
  bind="127.0.0.1:8080"
fi

# --- Its password ------------------------------------------------------------------------
# Made once per machine and kept, so it doesn't change on every provision. Inside the
# machine, Gjöll also stops claude, the dev servers and the database connecting to the editor.
if [ "$AUTH" = "password" ] && [ ! -s "$PASSWORD_FILE" ]; then
  install -d -m 0755 "$(dirname "$PASSWORD_FILE")"
  ( umask 077; python3 -I -c 'import secrets; print(secrets.token_urlsafe(18), end="")' > "$PASSWORD_FILE" )
fi
[ -f "$PASSWORD_FILE" ] && chmod 0600 "$PASSWORD_FILE"

# --- Config ------------------------------------------------------------------------------
# Written as dev, never as root, so a link left in dev's home can't point root's writes
# anywhere. The password goes through a file only dev can read, never on a command line
# (which other users could see).
stage="$(mktemp -d)"
chmod 0711 "$stage"
secret="$stage/password"
if [ "$AUTH" = "password" ]; then cp "$PASSWORD_FILE" "$secret"; else : > "$secret"; fi
chown dev:dev "$secret"
chmod 0600 "$secret"
sudo -u dev -H bash -s "$bind" "$AUTH" "$secret" <<'SH'
set -euo pipefail
bind="$1" auth="$2" secret="$3"
mkdir -p ~/.config/code-server
chmod 0700 ~/.config ~/.config/code-server
tmp="$(mktemp ~/.config/code-server/.config.XXXXXX)"
{
  printf 'bind-addr: %s\n' "$bind"
  printf 'auth: %s\n' "$auth"
  if [ "$auth" = password ]; then printf 'password: "%s"\n' "$(cat "$secret")"; fi
  printf 'cert: false\ndisable-telemetry: true\ndisable-update-check: true\n'
} > "$tmp"
chmod 0600 "$tmp"
mv -f -T "$tmp" ~/.config/code-server/config.yaml
SH
rm -rf "$stage"
if [ "$AUTH" = "none" ]; then
  warn "editor.auth is \"none\": the editor has no password. Anything that can reach port 8080 gets a terminal as dev."
fi

# --- Open your copy of the project by default ---------------------------------------------
install -d /etc/systemd/system/code-server@dev.service.d
cat > /etc/systemd/system/code-server@dev.service.d/gleipnir.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/code-server /srv/project
EOF

# --- Editor settings ---------------------------------------------------------------------
# Gleipnir's defaults are added only where a setting isn't there yet, so anything you've
# changed in the editor is kept. A settings file with comments in it is left alone.
sudo -u dev -H mkdir -p "$USER_DIR"
sudo -u dev python3 -I - "$USER_DIR/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
defaults = {
    "workbench.colorTheme": "Dark 2026",
    "workbench.startupEditor": "none",
    "terminal.integrated.cwd": "/srv/project",
    "telemetry.telemetryLevel": "off",
    "git.autofetch": False,
}
settings = {}
if os.path.exists(path):
    try:
        with open(path) as fh:
            settings = json.load(fh)
    except ValueError:
        print("    WARNING: the editor's settings.json has comments or isn't plain JSON; left unchanged", file=sys.stderr)
        sys.exit(0)
missing = {key: value for key, value in defaults.items() if key not in settings}
if missing:
    settings.update(missing)
    with open(path, "w") as fh:
        json.dump(settings, fh, indent=2)
        fh.write("\n")
PY

# --- Extensions, from the Open VSX registry ------------------------------------------
mapfile -t extensions < <(cfg extensions "")
if [ "${#extensions[@]}" -eq 0 ] || [ -z "${extensions[0]}" ]; then
  extensions=(svelte.svelte-vscode bradlc.vscode-tailwindcss dbaeumer.vscode-eslint esbenp.prettier-vscode)
fi
for ext in "${extensions[@]}"; do
  if sudo -u dev -H code-server --install-extension "$ext" >/dev/null 2>&1; then
    log "Extension: $ext"
  else
    warn "Couldn't install extension $ext"
  fi
done

# --- Start it ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable code-server@dev >/dev/null 2>&1
systemctl restart code-server@dev

for _ in $(seq 1 30); do
  if curl -fs -o /dev/null http://127.0.0.1:8080/healthz; then break; fi
  sleep 1
done
if ! curl -fs -o /dev/null http://127.0.0.1:8080/healthz; then
  fail "code-server didn't start. See: sudo journalctl -u code-server@dev"
fi
if [ "$AUTH" = "password" ]; then
  log "Editor running. Its password: run gpass <machine> on your computer"
else
  log "Editor running"
fi