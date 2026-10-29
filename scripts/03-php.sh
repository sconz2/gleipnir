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

# --- Composer, from its own site, checked against its published signature --------------
# In a throwaway home folder, so nothing is left in root's
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export COMPOSER_HOME="$work" COMPOSER_ALLOW_SUPERUSER=1
if [ -x /usr/local/bin/composer ]; then
  /usr/local/bin/composer self-update --2 --no-interaction --quiet || warn "Composer couldn't update itself; keeping the version installed"
else
  log "Installing Composer"
  expected="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL https://getcomposer.org/installer -o "$work/composer-setup.php"
  actual="$(php -r 'echo hash_file("sha384", $argv[1]);' "$work/composer-setup.php")"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    fail "Composer's installer didn't match its signature; stopping"
  fi
  php "$work/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
fi
chown root:root /usr/local/bin/composer
chmod 0755 /usr/local/bin/composer

log "PHP $(php -r 'echo PHP_VERSION;'), $(/usr/local/bin/composer --version --no-ansi 2>/dev/null | head -n 1)"