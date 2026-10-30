#!/usr/bin/env bash
# Gleipnir: the project's dev servers, one per app, run in the background from Claude's copy
# of the project by the runner user: inside Gjöll like Claude, and with no access to yours
# (the editor, /srv/project, the deploy key). They start when the machine boots, restart if
# they crash, and are controlled with the `devserver` command, from the editor's terminal too.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

UNIT_FILE=/etc/systemd/system/gleipnir-dev@.service
POLKIT_RULE=/etc/polkit-1/rules.d/50-gleipnir-devserver.rules
RUN_DIR=/etc/gleipnir/devserver
LIST=/etc/gleipnir/devservers   # name, folder, port, command: read by devserver and 11-claude-md.sh
LOG_DIR=/var/log/gleipnir

install -m 0755 "$GLEIPNIR_SRC/scripts/files/devserver" /usr/local/bin/devserver
install -d -m 0755 "$RUN_DIR"

# --- From earlier versions: dev servers run by dev, as user services -----------------------
if [ -f /etc/systemd/user/gleipnir-dev@.service ] || [ -f /etc/systemd/user/gleipnir-dev.service ]; then
  dev_uid="$(id -u dev)"
  for run in "$RUN_DIR"/*.run; do
    [ -f "$run" ] || continue
    sudo -u dev env XDG_RUNTIME_DIR="/run/user/$dev_uid" \
      systemctl --user disable --now "gleipnir-dev@$(basename "$run" .run).service" >/dev/null 2>&1 || true
  done
  sudo -u dev env XDG_RUNTIME_DIR="/run/user/$dev_uid" \
    systemctl --user disable --now gleipnir-dev.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/user/gleipnir-dev@.service /etc/systemd/user/gleipnir-dev.service /etc/gleipnir/devserver-run
  # They were all dev needed its user services for
  loginctl disable-linger dev 2>/dev/null || true
  log "The dev servers now run as runner, not dev"
fi
rm -f /etc/gleipnir/devserver-command

# --- The service, one copy per app ---------------------------------------------------------
# Its files are owned by root, so nothing the dev servers run can change them. It needs Gjöll:
# the firewall's rules are put in place first, and if that fails the dev servers don't start.
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Gleipnir: the %i dev server
Requires=gjoll-firewall.service
After=gjoll-firewall.service squid.service postgresql.service network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
ExecStart=$RUN_DIR/%i.run
User=runner
Group=runner
SupplementaryGroups=project
UMask=0002
Environment=HOME=$RUNNER_HOME
EnvironmentFile=-/etc/gleipnir/runner-env
Restart=on-failure
RestartSec=10
StandardOutput=append:$LOG_DIR/devserver-%i.log
StandardError=inherit

# It can change Claude's copy of the project and its own home, and nothing else
ProtectSystem=strict
ReadWritePaths=$WORK $RUNNER_HOME
ProtectHome=yes
InaccessiblePaths=-$TRUSTED -$WORK/.git
PrivateTmp=yes
NoNewPrivileges=yes
RestrictSUIDSGID=yes
ProtectProc=invisible
RestrictNamespaces=yes
LockPersonality=yes
RestrictRealtime=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$UNIT_FILE"
systemctl daemon-reload

# --- Who can control them -------------------------------------------------------------------
# dev (the editor's terminal) can start, stop and restart them, and nothing else
install -d -m 0755 "$(dirname "$POLKIT_RULE")"
cat > "$POLKIT_RULE" <<'EOF'
// Gleipnir: dev (the editor's terminal) may start, stop and restart the dev servers, and
// nothing else. The admin user does it with sudo.
polkit.addRule(function (action, subject) {
  if (action.id !== "org.freedesktop.systemd1.manage-units" || subject.user !== "dev") {
    return polkit.Result.NOT_HANDLED;
  }
  var unit = action.lookup("unit") || "";
  var verb = action.lookup("verb") || "";
  var verbs = ["start", "stop", "restart", "try-restart", "reset-failed"];
  if (/^gleipnir-dev@[a-z0-9][a-z0-9-]*\.service$/.test(unit) && verbs.indexOf(verb) >= 0) {
    return polkit.Result.YES;
  }
  return polkit.Result.NOT_HANDLED;
});
EOF
chmod 0644 "$POLKIT_RULE"

# --- Their output ------------------------------------------------------------------------------
# Readable by you (dev), and by Claude (the project group) to debug them
install -d -o root -g project -m 0750 "$LOG_DIR"
setfacl -m u:dev:rx "$LOG_DIR"
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
log_file() { # name
  local file="$LOG_DIR/devserver-$1.log"
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    rm -f "$file"
    install -o root -g project -m 0640 /dev/null "$file"
  fi
  chown root:project "$file"
  chmod 0640 "$file"
  setfacl -m u:dev:r "$file"
}

# It must listen on its app's port. Vagrant forwards that to your computer's localhost, which
# only works if the server listens on all of the VM's addresses, not just its own localhost.
if id vagrant >/dev/null 2>&1; then HOST=0.0.0.0; else HOST=127.0.0.1; fi

# Work out an app's command: the config's, or the usual one for what's in its folder.
# The project's files are read as runner, never as root or dev, since Claude can change
# them, and never through a link.
command_for() { # dir port configured
  local dir="$1" port="$2" configured="$3"
  if [ -n "$configured" ]; then
    printf '%s\n' "$configured"
  elif [ -f "$dir/artisan" ] && [ -f "$dir/composer.json" ]; then
    printf '%s\n' "php artisan serve --host=$HOST --port=$port"
  elif [ -f "$dir/package.json" ] && timeout 20 sudo -u runner python3 -I - "$dir/package.json" <<'PY'
import json, os, stat, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    if not stat.S_ISREG(os.fstat(fd).st_mode) or os.fstat(fd).st_size > 1_000_000:
        sys.exit(1)
    with os.fdopen(fd, "rb") as fh:
        scripts = json.loads(fh.read()).get("scripts", {})
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
  if [ ! -e "$WORK/$folder" ] && [ ! -L "$WORK/$folder" ]; then
    log "$label: $folder/ doesn't exist yet; its dev server will be set up on the first provision after it does"
    continue
  fi
  if ! dir="$(app_dir "$folder")"; then
    warn "$label: $folder isn't a plain folder in the project (a link?); its dev server wasn't set up"
    continue
  fi
  COMMAND="$(command_for "$dir" "$port" "$configured")"
  if [ -z "$COMMAND" ]; then
    if [ -f "$dir/package.json" ]; then
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
    printf 'cd %q\n' "$dir"
    echo "exec $COMMAND"
  } > "$RUN_DIR/$name.run"
  chmod 0755 "$RUN_DIR/$name.run"
  log_file "$name"

  systemctl enable "gleipnir-dev@$name.service" >/dev/null 2>&1
  systemctl reset-failed "gleipnir-dev@$name.service" >/dev/null 2>&1 || true
  systemctl restart "gleipnir-dev@$name.service"
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
    systemctl disable --now "gleipnir-dev@$name.service" >/dev/null 2>&1 || true
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