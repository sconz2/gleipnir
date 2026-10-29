#!/usr/bin/env bash
# Gleipnir: Playwright's browsers (optional), shared by dev and claude.
#
# The browsers go in /opt/playwright, owned by root, so tests run by either user
# use them but neither can change them. They're installed with a fresh copy of
# Playwright from npm, never the project's own copy: anything in node_modules
# could have been changed by Claude, and this runs as root.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

DEST=/srv/project
BROWSERS=/opt/playwright
PROFILE=/etc/profile.d/gleipnir-playwright.sh
USER_ENV=/etc/environment.d/60-gleipnir-playwright.conf
EDITOR_ENV=/etc/systemd/system/code-server@dev.service.d/playwright.conf

# --- Turned off: remove it ------------------------------------------------------------
if [ "$(cfg playwright.enabled false)" != "true" ]; then
  if [ -d "$BROWSERS" ]; then
    rm -rf "$BROWSERS" "$PROFILE" "$USER_ENV" "$EDITOR_ENV"
    log "Playwright's browsers removed"
  else
    log "Playwright isn't enabled; skipping"
  fi
  exit 0
fi

# --- Which version: the one the project uses, so its browsers match -------------------
# The first app with Playwright installed decides. Only the version number is read from
# the project, as dev (claude can change the project), and it's checked before use.
mapfile -t MODULES < <(apps | cut -f2 | sed "s#^#$DEST/#; s#\$#/node_modules#")
VERSION="$(timeout 20 sudo -u dev python3 -I - "${MODULES[@]}" <<'PY'
import json, os, sys
def version():
    for modules in sys.argv[1:]:
        for package in ("playwright-core", "playwright", "@playwright/test"):
            try:
                with open(os.path.join(modules, package, "package.json")) as fh:
                    data = json.load(fh)
            except (OSError, ValueError):
                continue
            return str(data.get("version", "")) if isinstance(data, dict) else ""
    return ""
print(version())
PY
)" || VERSION=""
if [ -z "$VERSION" ]; then
  VERSION=latest
  warn "The project doesn't use Playwright yet; installing browsers for the latest version. Provision again after adding it."
elif ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  fail "Unexpected Playwright version in node_modules: $VERSION"
fi

mapfile -t WANTED < <(cfg playwright.browsers chromium | sed '/^$/d')
[ "${#WANTED[@]}" -gt 0 ] || WANTED=(chromium)
for browser in "${WANTED[@]}"; do
  case "$browser" in
    chromium|firefox|webkit|chrome|msedge) ;;
    *) fail "playwright.browsers: unknown browser \"$browser\" (use chromium, firefox or webkit)" ;;
  esac
done

# --- Install the browsers and the system libraries they need ----------------------------
log "Installing Playwright $VERSION browsers: ${WANTED[*]}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
install -d -m 0755 "$BROWSERS"
(
  cd "$work"
  export HOME="$work" npm_config_cache="$work/npm-cache" npm_config_ignore_scripts=true
  export PLAYWRIGHT_BROWSERS_PATH="$BROWSERS"
  npx --yes "playwright@$VERSION" install --with-deps "${WANTED[@]}" > "$work/install.log" 2>&1 \
    || { tail -n 30 "$work/install.log" >&2; fail "Playwright's browser install failed"; }
)
chown -R root:root "$BROWSERS"
chmod -R u=rwX,go=rX "$BROWSERS"

# --- Point every user at them ------------------------------------------------------------
# Login shells (vagrant ssh, and Claude)
echo "export PLAYWRIGHT_BROWSERS_PATH=$BROWSERS" > "$PROFILE"
chmod 0644 "$PROFILE"
# User services (the dev server)
install -d -m 0755 /etc/environment.d
echo "PLAYWRIGHT_BROWSERS_PATH=$BROWSERS" > "$USER_ENV"
chmod 0644 "$USER_ENV"
# The editor and its terminal; the editor step restarts it after this
install -d -m 0755 "$(dirname "$EDITOR_ENV")"
printf '[Service]\nEnvironment=PLAYWRIGHT_BROWSERS_PATH=%s\n' "$BROWSERS" > "$EDITOR_ENV"
chmod 0644 "$EDITOR_ENV"

log "Playwright $VERSION browsers ready in $BROWSERS"