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

# --- Config, keeping the existing password -----------------------------------------
install -d -o dev -g dev -m 0700 "$DEV_HOME/.config" "$CONF_DIR"

password=""
new_password=0
if [ -f "$CONF" ]; then
  password="$(sed -n 's/^password: *//p' "$CONF")"
fi
if [ -z "$password" ]; then
  password="$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(18))')"
  new_password=1
fi

# dev's home is private, so the claude user can't read this password
cat > "$CONF" <<EOF
bind-addr: $bind
auth: password
password: $password
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

if [ "$new_password" -eq 1 ]; then
  echo
  echo "    ------------------------------------------------------------"
  echo "    Editor password: $password"
  echo "    (shown once; see the README for how to look it up again)"
  echo "    ------------------------------------------------------------"
  echo
fi