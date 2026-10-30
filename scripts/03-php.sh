#!/usr/bin/env bash
# Gleipnir: PHP and Composer (optional), system-wide and owned by root, so dev and
# claude can use them but can't change them. PHP comes from the ondrej/php PPA, which
# has every current version; only the command-line PHP, never a web server.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

if [ "$(cfg php.enabled false)" != "true" ]; then
  log "PHP isn't enabled; skipping"
  exit 0
fi

PHP_VERSION="$(cfg php.version 8.4)"
[[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || fail "php.version must be a version like 8.4"

# What Laravel needs, plus PostgreSQL, SQLite and image support. Add more with php.extensions.
EXTENSIONS=(cli common mbstring xml curl zip bcmath intl pgsql sqlite3 gd readline)
while IFS= read -r ext; do
  [ -z "$ext" ] && continue
  [[ "$ext" =~ ^[a-z0-9_]+$ ]] || fail "php.extensions: \"$ext\" isn't an extension name (e.g. redis)"
  EXTENSIONS+=("$ext")
done < <(cfg php.extensions '')

# --- PHP, from the ondrej/php PPA -------------------------------------------------------
if ! grep -rqs "ondrej/php" /etc/apt/sources.list.d/; then
  apt-get install -y software-properties-common >/dev/null
  # The PPA's name has a non-ASCII character in it; this locale lets the tool read it
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php >/dev/null
fi
apt-get update -y >/dev/null
packages=(unzip)
for ext in "${EXTENSIONS[@]}"; do packages+=("php$PHP_VERSION-$ext"); done
apt-get install -y --no-install-recommends "${packages[@]}" >/dev/null \
  || fail "PHP $PHP_VERSION didn't install. Check php.version and php.extensions."

# This version is the one `php` runs, even if another was installed before
update-alternatives --set php "/usr/bin/php$PHP_VERSION" >/dev/null

# --- Composer: the version in scripts/versions.sh, checked against its checksum ----------
# In a throwaway home folder, so nothing is left in root's
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export COMPOSER_HOME="$work" COMPOSER_ALLOW_SUPERUSER=1
current="$(/usr/local/bin/composer --version --no-ansi 2>/dev/null | awk '/^Composer version/ { print $3 }' || true)"
if [ "$current" != "$COMPOSER_VERSION" ]; then
  log "Installing Composer $COMPOSER_VERSION"
  curl -fsSL -o "$work/composer.phar" \
    "https://github.com/composer/composer/releases/download/$COMPOSER_VERSION/composer.phar" \
    || fail "couldn't download Composer $COMPOSER_VERSION"
  if [ "$(sha256sum "$work/composer.phar" | cut -d' ' -f1)" != "$COMPOSER_SHA256" ]; then
    fail "Composer's download didn't match its checksum in scripts/versions.sh; stopping"
  fi
  install -o root -g root -m 0755 "$work/composer.phar" /usr/local/bin/composer
fi
chown root:root /usr/local/bin/composer
chmod 0755 /usr/local/bin/composer

log "PHP $(php -r 'echo PHP_VERSION;'), $(/usr/local/bin/composer --version --no-ansi 2>/dev/null | head -n 1)"