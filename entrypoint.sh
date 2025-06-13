#!/bin/bash
set -e

# Start cron service
service cron start

# Define the application root within the container
APP_ROOT="/var/www/html"
INSTALLER_PATH="/opt/grusher_tools/grusher_installer.phar"

# Check if Grusher is already installed by looking for key configuration files
if [ -f "$APP_ROOT/config/grusher_modules.php" ] && [ -f "$APP_ROOT/.env" ]; then
    echo "Grusher appears to be already installed (config/grusher_modules.php and .env exist in $APP_ROOT)."
else
    echo "Grusher is not installed in $APP_ROOT. Attempting automatic installation..."

    if [ -z "$LICENSE_KEY" ]; then
        echo "Error: LICENSE_KEY environment variable is not set."
        echo "Please set it in your .env file and rebuild/restart the container."
        exit 1
    fi

    # Ensure the APP_ROOT directory exists and is writable for www-data before installation
    # This is important because the volume is mounted here.
    mkdir -p $APP_ROOT
    # The installer will run as www-data and create files inside $APP_ROOT.
    # If $APP_ROOT is newly created by mkdir, its ownership might be root.
    # We need www-data to be able to write into it.
    # However, chown on /var/www/html (a root dir in image) might be too broad or fail if it has content.
    # The installer itself (sudo -u www-data php ...) should handle file creation permissions within $APP_ROOT.
    # What's crucial is that the directory $APP_ROOT itself is writable by www-data if it needs to create subdirs like 'config' directly.
    # If the installer creates $APP_ROOT/config, then $APP_ROOT must be writable by www-data.
    # Let's ensure the target directory for installation is prepared.
    # If ./grusher_app_data on host is empty, $APP_ROOT will be empty.
    # The installer runs `cd /var/www/html` (which is $APP_ROOT)
    # then `mkdir $PATH."/config"` which means $APP_ROOT/config

    # Use GRUSHER_APP_URL from .env for the installer, default if not set
    GRUSHER_URL_FOR_INSTALLER=${GRUSHER_APP_URL:-http://localhost:${WEB_HOST_PORT:-8080}/}
    DB_HOST_FOR_INSTALLER=${DB_HOST:-db}
    DB_PORT_FOR_INSTALLER=${DB_PORT:-3306}
    MYSQL_DATABASE_FOR_INSTALLER=${MYSQL_DATABASE:-grusher}
    MYSQL_USER_FOR_INSTALLER=${MYSQL_USER:-grusher}
    MYSQL_PASSWORD_FOR_INSTALLER=${MYSQL_PASSWORD:-grusherpassword}

    # WebSocket params for installer (to write into config/grusher_modules.php)
    # These come from .env, with defaults matching installer's own defaults if not set
    WS_KEY_FOR_INSTALLER=${GRUSHER_WS_KEY:-myWebsocketKey}
    WS_PORT_FOR_INSTALLER=${GRUSHER_WS_INTERNAL_PORT:-8080} # This is "web_socket_port" in grusher_modules.php
    WS_PORT_FOR_WEB_FOR_INSTALLER=${GRUSHER_WS_PORT_FOR_WEB:-8080} # This is "web_socket_port_for_web"
    # WS_URL_FOR_INSTALLER is optional, only used if GRUSHER_WS_URL is set in .env
    WS_URL_PARAM_FOR_INSTALLER=""
    if [ -n "$GRUSHER_WS_URL" ]; then
      WS_URL_PARAM_FOR_INSTALLER=$GRUSHER_WS_URL
    fi 

    echo "Waiting for database ($DB_HOST_FOR_INSTALLER:$DB_PORT_FOR_INSTALLER) to be ready..."
    timeout=60
    while ! nc -z $DB_HOST_FOR_INSTALLER $DB_PORT_FOR_INSTALLER; do
      sleep 1
      timeout=$(($timeout - 1))
      if [ $timeout -eq 0 ]; then
        echo "Error: Timed out waiting for database connection."
        exit 1
      fi
      echo -n "."
    done
    echo "Database is ready."

    echo "Running Grusher installer ($INSTALLER_PATH)..."
    cd $APP_ROOT # Ensure we are in the correct directory for the installer

    sudo -E -u www-data php $INSTALLER_PATH <<EOF
install
$LICENSE_KEY
$GRUSHER_URL_FOR_INSTALLER
$DB_HOST_FOR_INSTALLER
$DB_PORT_FOR_INSTALLER
$MYSQL_DATABASE_FOR_INSTALLER
$MYSQL_USER_FOR_INSTALLER
$MYSQL_PASSWORD_FOR_INSTALLER
yes
EOF

    INSTALL_EXIT_CODE=$?

    if [ $INSTALL_EXIT_CODE -eq 0 ] && [ -f "$APP_ROOT/config/grusher_modules.php" ] && [ -f "$APP_ROOT/.env" ]; then
        echo "Grusher installation script finished (Exit Code: $INSTALL_EXIT_CODE)."
        echo "Performing post-installation ownership and permission adjustments in $APP_ROOT..."
        
        echo "Updating $APP_ROOT/.env with Memcached and WebSocket settings from docker environment..."
        if [ -f "$APP_ROOT/.env" ]; then
            # Ensure CACHE_DRIVER is memcached
            sed -i "s/^CACHE_DRIVER=.*/CACHE_DRIVER=memcached/" "$APP_ROOT/.env"
            grep -q "^MEMCACHED_HOST=" "$APP_ROOT/.env" || echo "MEMCACHED_HOST=${MEMCACHED_HOST:-memcached}" >> "$APP_ROOT/.env"
            grep -q "^MEMCACHED_PORT=" "$APP_ROOT/.env" || echo "MEMCACHED_PORT=${MEMCACHED_PORT:-11211}" >> "$APP_ROOT/.env"
            # Add SESSION_DRIVER if you decided to use memcached for sessions
            # sed -i "s/^SESSION_DRIVER=.*/SESSION_DRIVER=memcached/" "$APP_ROOT/.env"
        fi

        echo "Updating $APP_ROOT/config/grusher_modules.php with WebSocket settings from docker environment..."
        if [ -f "$APP_ROOT/config/grusher_modules.php" ]; then
            sudo -u www-data sed -i "s/=> *\"myWebsocketKey\"/=> \"${GRUSHER_WS_KEY:-mySuperSecretGrusherWsKey}\"/" "$APP_ROOT/config/grusher_modules.php"
            sudo -u www-data sed -i "s/=> *\"8080\" *, *\/\/ This is local ws port/=> \"${GRUSHER_WS_INTERNAL_PORT:-8081}\", \/\/ This is local ws port/" "$APP_ROOT/config/grusher_modules.php"
            sudo -u www-data sed -i "s/=> *\"8080\" *, *\/\/ Change to 8443 if you are using SSL/=> \"${GRUSHER_WS_PORT_FOR_WEB:-8081}\", \/\/ Change to 8443 if you are using SSL/" "$APP_ROOT/config/grusher_modules.php"
            
            if [ -n "$GRUSHER_WS_URL" ]; then
                if grep -q "^ *\/\/\"web_socket_url\"" "$APP_ROOT/config/grusher_modules.php"; then
                    sudo -u www-data sed -i "s/^ *\/\/\(\"web_socket_url\" *=> *\"\).*\(\"\)/\1${GRUSHER_WS_URL}\2/" "$APP_ROOT/config/grusher_modules.php"
                elif grep -q "^ *\"web_socket_url\"" "$APP_ROOT/config/grusher_modules.php"; then
                    sudo -u www-data sed -i "s/^ *\(\"web_socket_url\" *=> *\"\).*\(\"\)/\1${GRUSHER_WS_URL}\2/" "$APP_ROOT/config/grusher_modules.php"
                else
                    echo "Warning: GRUSHER_WS_URL is set but could not automatically update/add it to $APP_ROOT/config/grusher_modules.php. Manual check might be needed."
                fi
            fi
        fi

        echo "Setting permissions for $APP_ROOT/storage and $APP_ROOT/bootstrap/cache..."
        if [ -d "$APP_ROOT/storage" ]; then
            sudo chown -R www-data:www-data "$APP_ROOT/storage"
            sudo chmod -R ug+rwx "$APP_ROOT/storage"
        fi
        if [ -d "$APP_ROOT/bootstrap/cache" ]; then
            sudo chown -R www-data:www-data "$APP_ROOT/bootstrap/cache"
            sudo chmod -R ug+rwx "$APP_ROOT/bootstrap/cache"
        fi
        sudo chown www-data:www-data "$APP_ROOT/.env" "$APP_ROOT/config/grusher_modules.php" "$APP_ROOT/config/lic.php"
        sudo chmod 640 "$APP_ROOT/.env"
        sudo chmod 644 "$APP_ROOT/config/grusher_modules.php" "$APP_ROOT/config/lic.php"

        echo "Installation and initial configuration complete. Grusher should be accessible."
    else
        echo "----------------------------------------------------------------------"
        echo " Grusher automatic installation FAILED (Exit code: $INSTALL_EXIT_CODE)."
        echo " Please check the output above for errors from grusher_installer.phar."
        echo " Key files (e.g., config/grusher_modules.php or .env) might be missing or incorrect."
        echo " If it failed, you might need to run the installer manually:"
        echo " 1. Access this container's shell: docker exec -it grusher-web bash"
        echo " 2. Navigate to $APP_ROOT: cd $APP_ROOT"
        echo " 3. Run the installer: sudo -u www-data php $INSTALLER_PATH"
        echo "    (You will be prompted for license and DB details)"
        echo "----------------------------------------------------------------------"
        # exit 1 # Optionally exit if installation fails
    fi
fi

# Start Apache in the foreground
echo "Starting Apache..."
exec apache2-foreground
