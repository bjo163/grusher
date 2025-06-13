#!/bin/bash
set -e

APP_ROOT="/var/www/html"
WEBSOCKET_ENTRYPOINT_PATH="/opt/grusher_tools/entrypoint-websocket.sh"

cd $APP_ROOT

# Wait for the main Grusher installation to be likely complete
# Check for .env file which is created by the installer
echo "WebSocket service: Waiting for Grusher installation to complete (checking for .env file)..."
WAIT_TIMEOUT=120 # Wait for 2 minutes max
while [ ! -f .env ] && [ $WAIT_TIMEOUT -gt 0 ]; do 
  sleep 5
  WAIT_TIMEOUT=$(($WAIT_TIMEOUT - 5))
  echo -n "."
  if [ $WAIT_TIMEOUT -eq 0 ]; then
    echo "
WebSocket service: Timed out waiting for Grusher .env file. Websocket server might not start correctly."
    # exit 1 # Optionally exit if setup seems incomplete
  fi
done

if [ -f .env ]; then
    echo "\nWebSocket service: Grusher .env file found in $APP_ROOT."
    # Source the .env file to get variables, though they should also be in Docker env
    # export $(grep -v '^#' .env | xargs)
else
    echo "\nWebSocket service: Grusher .env file NOT found in $APP_ROOT. This might indicate an incomplete installation."
fi

# Ensure config/grusher_modules.php exists, as it contains WS settings
if [ ! -f config/grusher_modules.php ]; then
    echo "WebSocket service: $APP_ROOT/config/grusher_modules.php not found! Cannot determine WebSocket configuration. Exiting."
    exit 1
fi

# The Grusher installer mentions a command like `php artisan websockets:run` or similar
# for its WebSocket server. The `module_ws` in `grusher_modules.php` suggests it uses WebSockets.
# The installer also mentions `ws_server_load.php` in the context of killing old processes.

# We need to determine the actual command to start the WebSocket server.
# Based on WinterCMS/Laravel, it's often an artisan command.
# Let's assume `php artisan websockets:serve` or `php artisan websockets:run`
# The port should be configured via config/grusher_modules.php (web_socket_port) and .env

# Use GRUSHER_WS_INTERNAL_PORT from .env, default to 8081 if not set
WS_PORT_TO_RUN=${GRUSHER_WS_INTERNAL_PORT:-8081}

# Check for a specific Grusher command if documented, otherwise use a common Laravel/October one.
# The installer itself does not show the exact command to run the WS server, only to update/kill it.
# Let's assume there is an artisan command. `php artisan list` could show it.

# Attempt to find a relevant artisan command
ARTISAN_CMD=""
if php artisan list | grep -q 'websockets:serve'; then
    ARTISAN_CMD="websockets:serve --port=${WS_PORT_TO_RUN}"
elif php artisan list | grep -q 'websockets:run'; then
    ARTISAN_CMD="websockets:run --port=${WS_PORT_TO_RUN}"
elif php artisan list | grep -q 'grusher:websocket:serve'; then # Hypothetical Grusher specific command
    ARTISAN_CMD="grusher:websocket:serve --port=${WS_PORT_TO_RUN}"
fi

if [ -n "$ARTISAN_CMD" ]; then
    echo "WebSocket service: Starting WebSocket server using 'php artisan $ARTISAN_CMD' on port ${WS_PORT_TO_RUN} from $APP_ROOT..."
    php artisan $ARTISAN_CMD
else
    echo "WebSocket service: Could not determine the Artisan command to start WebSockets."
    echo "Please check Grusher documentation or use 'php artisan list' in the web container to find the command."
    echo "Common commands: websockets:serve, websockets:run"
    echo "WebSocket server will not be started."
    # Keep the container running but idle if WS server can't start, to allow debugging
    tail -f /dev/null
fi
