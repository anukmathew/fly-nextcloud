#!/bin/sh

# Fix data directory permissions
# The volume is mounted as root, Nextcloud needs www-data to own it
mkdir -p /var/www/html/data
chown -R www-data:www-data /var/www/html/data
chmod 750 /var/www/html/data

# ---------------------------------------------------------------
# Security hardening — Apache headers
# Sets HSTS, removes server version, adds __Host cookie support
# ---------------------------------------------------------------
configure_security_headers() {
  APACHE_CONF="/etc/apache2/conf-available/nextcloud-security.conf"

  cat > "$APACHE_CONF" << 'APACHE'
# Force HTTPS via HSTS
Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains; preload"

# Prevent clickjacking
Header always set X-Frame-Options "SAMEORIGIN"

# Prevent MIME type sniffing
Header always set X-Content-Type-Options "nosniff"

# XSS protection
Header always set X-XSS-Protection "1; mode=block"

# Referrer policy
Header always set Referrer-Policy "no-referrer"

# Remove server version from headers
ServerTokens Prod
ServerSignature Off

# Enable __Host- cookie prefix support
Header always edit Set-Cookie ^(.*)$ $1;SameSite=Strict;Secure
APACHE

  a2enconf nextcloud-security > /dev/null 2>&1
  a2enmod headers > /dev/null 2>&1
}

# ---------------------------------------------------------------
# Nextcloud occ configuration
# Sets system config values that can't be set via env vars
# Only runs on first boot (when config.php doesn't have instanceid)
# ---------------------------------------------------------------
configure_nextcloud() {
  # Wait for Nextcloud to initialise config.php
  local retries=0
  while [ $retries -lt 30 ]; do
    if [ -f /var/www/html/config/config.php ] && \
       grep -q "instanceid" /var/www/html/config/config.php 2>/dev/null; then
      break
    fi
    sleep 2
    retries=$((retries + 1))
  done

  if [ $retries -eq 30 ]; then
    echo "⚠️  Timed out waiting for Nextcloud config.php"
    return
  fi

  OCC="sudo -u www-data PHP_MEMORY_LIMIT=512M php /var/www/html/occ"

  # HTTPS and trusted domain
  $OCC config:system:set overwriteprotocol --value="https" > /dev/null 2>&1
  $OCC config:system:set overwritehost --value="${OVERWRITEHOST}" > /dev/null 2>&1
  $OCC config:system:set overwrite.cli.url --value="${OVERWRITE_CLI_URL}" > /dev/null 2>&1

  # Maintenance window (2am UTC)
  $OCC config:system:set maintenance_window_start --value="2" > /dev/null 2>&1

  # Default phone region
  $OCC config:system:set default_phone_region --value="US" > /dev/null 2>&1

  # Log to stdout/errorlog instead of file (saves disk space)
  $OCC config:system:set log_type --value="errorlog" > /dev/null 2>&1

  # Disable log file rotation (not needed when logging to errorlog)
  $OCC config:system:set log_rotate_size --value="0" > /dev/null 2>&1

  echo "✅ Nextcloud occ configuration applied"
}

# Apply Apache security headers
configure_security_headers

# Run occ configuration in background after Nextcloud starts
configure_nextcloud &

# Start cron in background
/cron.sh &

# Start Nextcloud
exec /entrypoint.sh apache2-foreground
