#!/usr/bin/env bash
# Gleipnir: the browser editor (code-server), running as dev and opening the project.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

DEV_HOME=/home/dev
USER_DIR="$DEV_HOME/.local/share/code-server/User"

# --- Install, or update to the latest release ------------------------------------
log "Installing code-server"
# Its output (including a download progress bar) is only shown if it fails
out="$(mktemp)"
if ! curl -fsSL https://code-server.dev/install.sh | sh > "$out" 2>&1; then
  tail -n 20 "$out" >&2
  rm -f "$out"
  fail "code-server didn't install"
fi
rm -f "$out"
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

# --- Config ------------------------------------------------------------------------------
# No password. Only your computer can reach the forwarded port, and inside the machine
# Gjöll stops the claude user connecting to the editor (see 08-claude.sh). Without that
# block, Claude could use the editor's terminal to act as dev.
# Written as dev, never as root: code Claude runs can end up running as dev, and a link
# left in dev's home could otherwise point root's writes anywhere.
sudo -u dev -H bash -s "$bind" <<'SH'
set -euo pipefail
mkdir -p ~/.config/code-server
chmod 0700 ~/.config ~/.config/code-server
tmp="$(mktemp ~/.config/code-server/.config.XXXXXX)"
printf 'bind-addr: %s\nauth: none\ncert: false\ndisable-telemetry: true\ndisable-update-check: true\n' "$1" > "$tmp"
chmod 0600 "$tmp"
mv -f -T "$tmp" ~/.config/code-server/config.yaml
SH

# --- Open the project by default ------------------------------------------------------
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
log "Editor running"