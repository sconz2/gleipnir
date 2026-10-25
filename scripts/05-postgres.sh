#!/usr/bin/env bash
# Gleipnir: PostgreSQL (optional), with the databases listed in the config.
# Safe to re-run: existing databases are never dropped or changed.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive

if [ "$(cfg postgres.enabled false)" != "true" ]; then
  log "PostgreSQL isn't enabled; skipping"
  exit 0
fi

PG_VERSION="$(cfg postgres.version 18)"
DB_USER="$(cfg postgres.user app)"
DB_PASSWORD="$(cfg postgres.password '')"
[[ "$PG_VERSION" =~ ^[0-9]+$ ]] || fail "postgres.version must be a major version number, like 18"
[ -n "$DB_PASSWORD" ] || fail "postgres.password is required when PostgreSQL is enabled"
mapfile -t DATABASES < <(cfg postgres.databases "")

# --- Install, from PostgreSQL's own apt repository --------------------------------
apt-get install -y postgresql-common >/dev/null
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null
apt-get install -y "postgresql-$PG_VERSION" >/dev/null

CONF_DIR="/etc/postgresql/$PG_VERSION/main"
[ -d "$CONF_DIR" ] || fail "$CONF_DIR not found; PostgreSQL $PG_VERSION didn't install as expected"

# --- Who can connect ------------------------------------------------------------------
install -d -m 0755 "$CONF_DIR/conf.d"
if id vagrant >/dev/null 2>&1; then
  # Vagrant forwards your computer's localhost:<ports.db> here. Those connections
  # arrive from VirtualBox's NAT gateway, 10.0.2.2, and nothing else can use it.
  echo "listen_addresses = '*'" > "$CONF_DIR/conf.d/gleipnir.conf"
  hba="host    all    all    10.0.2.2/32    scram-sha-256"
  grep -qxF "$hba" "$CONF_DIR/pg_hba.conf" || echo "$hba" >> "$CONF_DIR/pg_hba.conf"
else
  # On a VPS: localhost only. Reach it from your computer through an SSH tunnel.
  echo "listen_addresses = 'localhost'" > "$CONF_DIR/conf.d/gleipnir.conf"
fi

systemctl restart postgresql
for _ in $(seq 1 30); do pg_isready -q && break; sleep 1; done
pg_isready -q || fail "PostgreSQL didn't start. See: sudo journalctl -u postgresql"

# --- The app's database user ------------------------------------------------------------
# Deliberately not a superuser: a PostgreSQL superuser can run shell commands on
# the server, which would let anything holding the password (the app, or Claude)
# step outside Gleipnir's restrictions. For admin work: sudo -u postgres psql
cd /tmp
sudo -u postgres psql -v ON_ERROR_STOP=1 -q -v user="$DB_USER" -v pass="$DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN CREATEDB PASSWORD %L', :'user', :'pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'user') \gexec
ALTER ROLE :"user" WITH LOGIN CREATEDB NOSUPERUSER PASSWORD :'pass';
SQL

# --- Databases ---------------------------------------------------------------------------
for db in "${DATABASES[@]}"; do
  [ -z "$db" ] && continue
  sudo -u postgres psql -v ON_ERROR_STOP=1 -q -v user="$DB_USER" -v db="$db" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
SQL
  log "Database ready: $db (owner $DB_USER)"
done

log "PostgreSQL $PG_VERSION ready on port 5432"