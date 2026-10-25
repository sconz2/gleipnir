#!/usr/bin/env bash
# Gleipnir: the project's dev server, run by the dev user in the background.
# It starts when the machine boots, restarts if it crashes, and is controlled
# with the `devserver` command.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

DEST=/srv/project
UNIT=gleipnir-dev.service
UNIT_FILE=/etc/systemd/user/$UNIT
RUN=/etc/gleipnir/devserver-run
LOG_DIR=/var/log/gleipnir
DEV_UID="$(id -u dev)"

# systemctl --user for the dev user, from root
as_dev_systemctl() {
  sudo -u dev env XDG_RUNTIME_DIR="/run/user/$DEV_UID" systemctl --user "$@"
}

install -m 0755 "$GLEIPNIR_SRC/scripts/files/devserver" /usr/local/bin/devserver

# --- Turned off: stop it and remove it ----------------------------------------------
if [ "$(cfg devserver.enabled true)" != "true" ]; then
  if [ -f "$UNIT_FILE" ]; then
    as_dev_systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE" "$RUN"
    log "Dev server turned off"
  else
    log "Dev server isn't enabled; skipping"
  fi
  exit 0
fi

# --- The command ------------------------------------------------------------------------
# It must listen on port 5173. Vagrant forwards that to your computer's localhost, which
# only works if the server listens on all of the VM's addresses, not just its own localhost.
if id vagrant >/dev/null 2>&1; then HOST=0.0.0.0; else HOST=127.0.0.1; fi
COMMAND="$(cfg devserver.command '')"
if [ -z "$COMMAND" ]; then
  has_dev_script="$(python3 -I - "$DEST/package.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print("yes" if "dev" in json.load(fh).get("scripts", {}) else "no")
except (OSError, ValueError):
    print("no")
PY
)"
  if [ "$has_dev_script" != "yes" ]; then
    warn "The project has no \"dev\" script in package.json; set devserver.command to run it. Skipping."
    exit 0
  fi
  COMMAND="npm run dev -- --host $HOST --port 5173 --strictPort"
fi

# --- Its log, readable by dev and claude ------------------------------------------------
install -d -o root -g project -m 0750 "$LOG_DIR"
[ -f "$LOG_DIR/devserver.log" ] || install -o dev -g project -m 0640 /dev/null "$LOG_DIR/devserver.log"

cat > /etc/logrotate.d/gleipnir <<EOF
$LOG_DIR/devserver.log {
  size 5M
  rotate 2
  copytruncate
  missingok
  notifempty
}
EOF

# --- The service ---------------------------------------------------------------------------
# A user service, so dev can start and stop it without sudo. Its files are owned by root,
# so nothing running as dev (including the dev server itself) can change them.
{
  echo '#!/bin/bash'
  echo '# Managed by Gleipnir: set devserver.command in the machine'"'"'s config.'
  echo "cd $DEST"
  echo "exec $COMMAND"
} > "$RUN"
chmod 0755 "$RUN"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Gleipnir: the project's dev server
ConditionUser=dev
ConditionPathExists=$DEST/package.json
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
WorkingDirectory=$DEST
ExecStart=$RUN
Restart=on-failure
RestartSec=10
StandardOutput=append:$LOG_DIR/devserver.log
StandardError=inherit

[Install]
WantedBy=default.target
EOF
chmod 0644 "$UNIT_FILE"

# Give dev a user manager that runs from boot, without anyone logging in
loginctl enable-linger dev
for _ in $(seq 1 30); do [ -S "/run/user/$DEV_UID/bus" ] && break; sleep 1; done
[ -S "/run/user/$DEV_UID/bus" ] || fail "dev's user services didn't start"

as_dev_systemctl daemon-reload
as_dev_systemctl enable "$UNIT" >/dev/null 2>&1
as_dev_systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
as_dev_systemctl restart "$UNIT"

# --- Tell Claude where to look ---------------------------------------------------------------
# 08-claude.sh writes this file fresh on every provision; this adds to it.
if [ -f /etc/claude-code/CLAUDE.md ]; then
  cat >> /etc/claude-code/CLAUDE.md <<EOF

## Dev server

- It runs \`$COMMAND\` as the \`dev\` user, on port 5173, and reloads as you edit.
- Its output is in $LOG_DIR/devserver.log (\`devserver log\` shows the end of it). Read it to check for build errors.
- If it needs restarting (after a dependency or config change), ask the user to run \`devserver restart\`.
EOF
fi

# --- Check it came up ---------------------------------------------------------------------------
for _ in $(seq 1 30); do
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:5173/"; then
    log "Dev server running on port 5173: $COMMAND"
    exit 0
  fi
  sleep 1
done
warn "The dev server didn't answer on port 5173 within 30 seconds. See: devserver log"