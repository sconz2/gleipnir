#!/usr/bin/env bash
# Gleipnir: the browser editor (code-server), running as dev and opening the project.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

DEV_HOME=/home/dev
CONF_DIR="$DEV_HOME/.config/code-server"
CONF="$CONF_DIR/config.yaml"
USER_DIR="$DEV_HOME/.local/share/code-server/User"

# --- Install, or update to the latest release ------------------------------------
log "Installing code-server"
curl -fsSL https://code-server.dev/install.sh | sh >/dev/null
log "$(code-server --version | head -n 1)"

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
install -d -o dev -g dev -m 0700 "$DEV_HOME/.config" "$CONF_DIR"

cat > "$CONF" <<EOF
bind-addr: $bind
auth: none
cert: false
disable-telemetry: true
disable-update-check: true
EOF
chown dev:dev "$CONF"
chmod 0600 "$CONF"

# --- Open the project by default ------------------------------------------------------
install -d /etc/systemd/system/code-server@dev.service.d
cat > /etc/systemd/system/code-server@dev.service.d/gleipnir.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/code-server /srv/project
EOF

# --- Editor settings, on first setup only (yours to change after that) ---------------
install -d -o dev -g dev "$DEV_HOME/.local" "$DEV_HOME/.local/share" \
  "$DEV_HOME/.local/share/code-server" "$USER_DIR"
if [ ! -f "$USER_DIR/settings.json" ]; then
  cat > "$USER_DIR/settings.json" <<'EOF'
{
  "workbench.startupEditor": "none",
  "terminal.integrated.cwd": "/srv/project",
  "telemetry.telemetryLevel": "off",
  "git.autofetch": false
}
EOF
  chown dev:dev "$USER_DIR/settings.json"
fi

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