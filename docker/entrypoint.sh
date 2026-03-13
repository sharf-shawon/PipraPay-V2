#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# PipraPay container entrypoint
#
# Responsibilities:
#   1. Generate pp-config.php from environment variables (if not present).
#   2. Wait for MySQL to become available.
#   3. Initialise the database schema & seed data on first run.
#   4. Optionally create the initial admin user (ADMIN_* env vars).
#   5. Hand off to the Apache process.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Environment variable defaults ─────────────────────────────────────────────
DB_HOST="${DB_HOST:-mysql}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-piprapay}"
DB_PASS="${DB_PASS:-}"
DB_NAME="${DB_NAME:-piprapay}"
DB_PREFIX="${DB_PREFIX:-pp_}"
APP_MODE="${APP_MODE:-live}"
PASSWORD_RESET="${PASSWORD_RESET:-off}"
# Set to 1 when running behind an HTTPS reverse proxy (e.g. Traefik with TLS).
# Defaults to 0 to allow local development over plain HTTP.
SESSION_COOKIE_SECURE="${SESSION_COOKIE_SECURE:-0}"

if [ "$DB_PORT" = "33060" ]; then
    echo "[entrypoint] WARNING: DB_PORT=33060 usually targets MySQL X Plugin, not classic SQL protocol."
    echo "[entrypoint]          PipraPay uses classic MySQL protocol (typically port 3306)."
fi

PP_CONFIG="/var/www/html/pp-config.php"
INSTALL_DIR="/var/www/html/install"

# ── Helper: run MySQL with credentials from a temp options file ────────────────
_mysql_opts_file=$(mktemp)
chmod 600 "$_mysql_opts_file"
printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' \
    "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" > "$_mysql_opts_file"

mysql_cmd() {
    mysql --defaults-extra-file="$_mysql_opts_file" --ssl=0 "$DB_NAME" "$@"
}

mysql_admin_cmd() {
    mysqladmin --defaults-extra-file="$_mysql_opts_file" --ssl=0 "$@"
}

cleanup() {
    rm -f "$_mysql_opts_file"
}
trap cleanup EXIT

# ── 1. Generate pp-config.php ─────────────────────────────────────────────────
if [ ! -f "$PP_CONFIG" ]; then
    echo "[entrypoint] Generating pp-config.php from environment variables..."
    cat > "$PP_CONFIG" << PHPEOF
<?php
\$db_host        = '${DB_HOST}';
\$db_port        = '${DB_PORT}';
\$db_user        = '${DB_USER}';
\$db_pass        = '${DB_PASS}';
\$db_name        = '${DB_NAME}';
\$db_prefix      = '${DB_PREFIX}';
\$mode           = '${APP_MODE}';
\$password_reset = '${PASSWORD_RESET}';
?>
PHPEOF
    chown www-data:www-data "$PP_CONFIG"
    chmod 640 "$PP_CONFIG"
    echo "[entrypoint] pp-config.php generated."
else
    echo "[entrypoint] pp-config.php already exists, skipping generation."
fi

# ── 2. Wait for MySQL ─────────────────────────────────────────────────────────
echo "[entrypoint] Waiting for MySQL at ${DB_HOST}..."
MAX_TRIES=30
count=0
until mysql_admin_cmd ping --silent > /dev/null 2>&1; do
    count=$((count + 1))
    if [ "$count" -ge "$MAX_TRIES" ]; then
        echo "[entrypoint] ERROR: MySQL did not become ready after ${MAX_TRIES} attempts. Aborting."
        exit 1
    fi
    echo "[entrypoint] MySQL not ready yet (attempt ${count}/${MAX_TRIES}), retrying in 2 s..."
    sleep 2
done
echo "[entrypoint] MySQL is ready."

# ── 3. Initialise database schema on first run ────────────────────────────────
TABLE_COUNT=$(mysql_cmd -N -e \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema='${DB_NAME}'
       AND table_name='${DB_PREFIX}settings';" 2>/dev/null || echo "0")

if [ "$TABLE_COUNT" = "0" ]; then
    echo "[entrypoint] Database is empty — importing schema and seed data..."

    # database.sql uses the __PREFIX__ placeholder
    if [ -f "${INSTALL_DIR}/database.sql" ]; then
        echo "[entrypoint]   Importing database.sql..."
        sed "s/__PREFIX__/${DB_PREFIX}/g" "${INSTALL_DIR}/database.sql" | mysql_cmd
    fi

    # currency.sql uses the literal table name 'currency'
    if [ -f "${INSTALL_DIR}/currency.sql" ]; then
        echo "[entrypoint]   Importing currency.sql..."
        sed "s/INSERT INTO \`currency\`/INSERT INTO \`${DB_PREFIX}currency\`/g" \
            "${INSTALL_DIR}/currency.sql" | mysql_cmd
    fi

    # timezone.sql uses the literal table name 'timezone'
    if [ -f "${INSTALL_DIR}/timezone.sql" ]; then
        echo "[entrypoint]   Importing timezone.sql..."
        sed "s/INSERT INTO \`timezone\`/INSERT INTO \`${DB_PREFIX}timezone\`/g" \
            "${INSTALL_DIR}/timezone.sql" | mysql_cmd
    fi

    # ── 4. Create initial admin user (optional) ────────────────────────────────
    if [ -n "${ADMIN_USER:-}" ] && [ -n "${ADMIN_PASS:-}" ] && [ -n "${ADMIN_EMAIL:-}" ]; then
        echo "[entrypoint]   Creating admin user '${ADMIN_USER}'..."
        # Hash password with bcrypt — same algorithm as the web installer
        HASHED_PASS=$(php -r "echo password_hash(getenv('ADMIN_PASS'), PASSWORD_BCRYPT);")
        ADMIN_NAME_SAFE=$(printf '%s' "${ADMIN_NAME:-Admin}" | sed "s/'/''/g")
        ADMIN_USER_SAFE=$(printf '%s' "${ADMIN_USER}"         | sed "s/'/''/g")
        ADMIN_EMAIL_SAFE=$(printf '%s' "${ADMIN_EMAIL}"       | sed "s/'/''/g")

        mysql_cmd -e "
            INSERT INTO \`${DB_PREFIX}admins\`
                (name, email, username, password)
            VALUES
                ('${ADMIN_NAME_SAFE}', '${ADMIN_EMAIL_SAFE}', '${ADMIN_USER_SAFE}', '${HASHED_PASS}');
            INSERT INTO \`${DB_PREFIX}settings\` (site_name) VALUES ('PipraPay');
        "
        echo "[entrypoint]   Admin user created. Please change your password after first login."
    else
        echo "[entrypoint]   ADMIN_USER / ADMIN_PASS / ADMIN_EMAIL not set."
        echo "[entrypoint]   Navigate to /install/ to complete setup via the web installer."
        # Insert a placeholder settings row so the app starts without errors
        mysql_cmd -e \
            "INSERT IGNORE INTO \`${DB_PREFIX}settings\` (site_name) VALUES ('PipraPay');" \
            2>/dev/null || true
    fi

    echo "[entrypoint] Database initialisation complete."
else
    echo "[entrypoint] Database already initialised — skipping."
fi

# ── 5. Write runtime PHP overrides ───────────────────────────────────────────
# session.cookie_secure must be 1 in production (HTTPS via reverse proxy)
# and 0 for local development over plain HTTP.
echo "session.cookie_secure = ${SESSION_COOKIE_SECURE}" \
    > /usr/local/etc/php/conf.d/piprapay-runtime.ini

# ── 6. Hand off to CMD (apache2-foreground) ───────────────────────────────────
exec "$@"
