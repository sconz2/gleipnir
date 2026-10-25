#!/usr/bin/env bash
# Gleipnir: the two working users, neither with sudo.
#   dev     your daily work: the editor, git, the dev server, tests
#   claude  runs Claude Code (firewalled in a later step)
# They share the project through the "project" group.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"

getent group project >/dev/null || groupadd project

for user in dev claude; do
  id "$user" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$user"
  usermod -aG project "$user"
  chmod 700 "/home/$user"
done

# A guard, in case a base box ever puts new users in an admin group
for user in dev claude; do
  if id -nG "$user" | grep -qwE 'sudo|admin|wheel'; then
    fail "$user is in an admin group; it must not have sudo"
  fi
done

log "Users ready: dev, claude (group: project)"
