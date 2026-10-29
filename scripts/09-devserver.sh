#!/usr/bin/env bash
# Gleipnir: the project's dev servers, one per app, run by the dev user in the background.
# They start when the machine boots, restart if they crash, and are controlled with the
# `devserver` command.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

DEST=/srv/project
UNIT_FILE=/etc/systemd/user/gleipnir-dev@.service
RUN_DIR=/etc/gleipnir/devserver
LIST=/etc/gleipnir/devservers   # name, folder, port, command: read by devserver and 10-claude-md.sh
LOG_DIR=/var/log/gleipnir
DEV_UID="$(id -u dev)"

# systemctl --user for the dev user, from root
as_dev_systemctl() {
  sudo -u dev env XDG_RUNTIME_DIR="/run/user/$DEV_UID" systemctl --user "$@"
}

install -m 0755 "$GLEIPNIR_SRC/scripts/files/devserver" /usr/local/bin/devserver
install -d -m 0755 "$RUN_DIR"

# Give dev a user manager that runs from boot, without anyone logging in
loginctl enable-linger dev
for _ in $(seq 1 30); do [ -S "/run/user/$DEV_UID/bus" ] && break; sleep 1; done
[ -S "/run/user/$DEV_UID/bus" ] || fail "dev's user services didn't start"

# --- From the single dev server of earlier versions ------------------------------------------
if [ -f /etc/systemd/user/gleipnir-dev.service ]; then
  as_dev_systemctl disable --now gleipnir-dev.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/user/gleipnir-dev.service /etc/gleipnir/devserver-run
fi
rm -f /etc/gleipnir/devserver-command

# --- The service, one copy per app -----------------------------------------------------------
# A user service, so dev can start and stop it without sudo. Its files are owned by root,
# so nothing running as dev (including the dev servers themselves) can change them.
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Gleipnir: the %i dev server
ConditionUser=dev
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
ExecStart=$RUN_DIR/%i.run
Restart=on-failure
RestartSec=10
StandardOutput=append:$LOG_DIR/devserver-%i.log
StandardError=inherit

[Install]
WantedBy=default.target
EOF
chmod 0644 "$UNIT_FILE"
as_dev_systemctl daemon-reload

install -d -o root -g project -m 0750 "$LOG_DIR"
rm -f "$LOG_DIR/devserver.log" "$LOG_DIR"/devserver.log.*   # the single log of earlier versions
cat > /etc/logrotate.d/gleipnir <<EOF
$LOG_DIR/devserver-*.log {
  size 5M
  rotate 2
  copytruncate
  missingok
  notifempty
}
EOF

# It must listen on its app's port. Vagrant forwards that to your computer's localhost, which
# only works if the server listens on all of the VM's addresses, not just its own localhost.
if id vagrant >/dev/null 2>&1; then HOST=0.0.0.0; else HOST=127.0.0.1; fi

# Work out an app's command: the config's, or the usual one for what's in its folder.
# The project's files are read as dev, never as root, since claude can change them.
command_for() { # folder port configured
  local dir="$DEST/$1" port="$2" configured="$3"
  if [ -n "$configured" ]; then
    printf '%s\n' "$configured"
  elif [ -f "$dir/artisan" ] && [ -f "$dir/composer.json" ]; then
    printf '%s\n' "php artisan serve --host=$HOST --port=$port"
  elif [ -f "$dir/package.json" ] && timeout 20 sudo -u dev python3 -I - "$dir/package.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        scripts = json.load(fh).get("scripts", {})
    sys.exit(0 if isinstance(scripts, dict) and "dev" in scripts else 1)
except Exception:
    sys.exit(1)
PY
  then
    printf '%s\n' "npm run dev -- --host $HOST --port $port --strictPort"
  fi
}

# --- Each app -----------------------------------------------------------------------------------
: > "$LIST.new"
started=()
wanted=()
while IFS=$'\t' read -r name folder port enabled configured; do
  label="$name"; [ "$folder" = "." ] && label="The project"
  if [ "$enabled" != "true" ]; then
    log "$label: dev server turned off"
    continue
  fi
  if [ -L "$DEST/$folder" ]; then
    warn "$label: $folder is a link, not a folder; its dev server wasn't set up"
    continue
  fi
  if [ ! -d "$DEST/$folder" ]; then
    log "$label: $folder/ doesn't exist yet; its dev server will be set up on the first provision after it does"
    continue
  fi
  COMMAND="$(command_for "$folder" "$port" "$configured")"
  if [ -z "$COMMAND" ]; then
    if [ -f "$DEST/$folder/package.json" ]; then
      warn "$label has no \"dev\" script in package.json; set its devserver.command to run it. Skipping."
    elif [ "$folder" = "." ]; then
      log "No package.json in the project yet; the dev server will be set up on the first provision after it has one"
    else
      log "$label: nothing to run in $folder/ yet (no package.json or artisan); skipping"
    fi
    continue
  fi

  {
    echo '#!/bin/bash'
    echo "# Managed by Gleipnir: set the app's devserver.command in the machine's config."
    echo "# HOST and PORT are where it must listen."
    echo "export HOST=$HOST PORT=$port"
    printf 'cd %q\n' "$DEST/$folder"
    echo "exec $COMMAND"
  } > "$RUN_DIR/$name.run"
  chmod 0755 "$RUN_DIR/$name.run"
  [ -f "$LOG_DIR/devserver-$name.log" ] || install -o dev -g project -m 0640 /dev/null "$LOG_DIR/devserver-$name.log"

  as_dev_systemctl enable "gleipnir-dev@$name.service" >/dev/null 2>&1
  as_dev_systemctl reset-failed "gleipnir-dev@$name.service" >/dev/null 2>&1 || true
  as_dev_systemctl restart "gleipnir-dev@$name.service"
  printf '%s\t%s\t%s\t%s\n' "$name" "$folder" "$port" "$COMMAND" >> "$LIST.new"
  started+=("$name:$port:$COMMAND")
  wanted+=("$name")
done < <(apps)
chmod 0644 "$LIST.new"
mv "$LIST.new" "$LIST"

# --- Apps no longer set up: stop them and remove them --------------------------------------
for run in "$RUN_DIR"/*.run; do
  [ -f "$run" ] || continue
  name="$(basename "$run" .run)"
  if [[ " ${wanted[*]} " != *" $name "* ]]; then
    as_dev_systemctl disable --now "gleipnir-dev@$name.service" >/dev/null 2>&1 || true
    rm -f "$run"
    log "Dev server for $name removed"
  fi
done

# --- Check each came up ------------------------------------------------------------------------
for entry in "${started[@]}"; do
  name="${entry%%:*}"; rest="${entry#*:}"; port="${rest%%:*}"; COMMAND="${rest#*:}"
  up=no
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then up=yes; break; fi
    sleep 1
  done
  if [ "$up" = yes ]; then
    log "Dev server $name running on port $port: $COMMAND"
  else
    warn "The $name dev server didn't answer on port $port within 30 seconds. See: devserver log $name"
  fi
done