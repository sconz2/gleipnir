#!/usr/bin/env bash
# Gleipnir: the working users, none with sudo.
#   dev     you: the editor, your own copy of the project (/srv/project), git and pushing
#   claude  Claude Code, in its own copy of the project (/srv/work); firewalled in a later step
#   runner  runs the dev servers from Claude's copy; no login, no keys, firewalled too
# claude and runner share Claude's copy through the "project" group. dev isn't in it:
# nothing Claude writes is ever run as dev.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

getent group project >/dev/null || groupadd project

for user in dev claude; do
  id "$user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$user"
  chmod 700 "/home/$user"
done
# runner's home is outside /home, which its services can't see at all
install -d -m 0755 "$(dirname "$RUNNER_HOME")"
if ! id runner >/dev/null 2>&1; then
  useradd --system --home-dir "$RUNNER_HOME" --create-home --shell /usr/sbin/nologin runner
fi
install -d -o runner -g runner -m 0700 "$RUNNER_HOME"

usermod -aG project claude
usermod -aG project runner
# Earlier versions shared the project with dev through this group
gpasswd -d dev project >/dev/null 2>&1 || true

# A guard, in case a base box ever puts new users in an admin group
for user in dev claude runner; do
  if id -nG "$user" | grep -qwE 'sudo|admin|wheel'; then
    fail "$user is in an admin group; it must not have sudo"
  fi
done

log "Users ready: dev, claude and runner (group project: claude, runner)"