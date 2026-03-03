#!/bin/bash
set -euo pipefail

# ------------------------------------------------
# Constants and Environment Variables
# ------------------------------------------------
APP_INSTALL_DIR="$HOME/.hiretrack/APP"
BACKUP_DIR="$HOME/.hiretrack/backup"
TMP_INSTALL_DIR="$HOME/.hiretrack/tmp_install"
CONFIG_PATH="$HOME/.hiretrack/config.json"
LICENSE_PATH="$HOME/.hiretrack/license.json"
SCRIPT_PATH="$HOME/.hiretrack/installer.sh"
SNAPSHOT_SCRIPT="$HOME/.hiretrack/take-snapshot.js"
LOG_DIR="$HOME/.hiretrack/logs"
CRON_LOG_FILE="$LOG_DIR/cron_update.log"
SNAPSHOT_LOG_FILE="$LOG_DIR/snapshot.log"
MANUAL_LOG_FILE="$LOG_DIR/manual_update.log"
ROLLBACK_LOG_FILE="$LOG_DIR/rollback.log"

API_URL="https://admin.hiretrack.in/api/license/register"
API_URL_UPDATE_LIC="https://admin.hiretrack.in/api/license/update"
LATEST_VERSION_API="https://admin.hiretrack.in/api/version/list"
ASSET_DOWNLOAD_API="https://admin.hiretrack.in/api/asset/download"
ASSET_MIGRATION_API="https://admin.hiretrack.in/api/migration/download"
MONGODB_VERSION="${MONGODB_VERSION:-7.0}"
# NODE_VERSION_DEFAULT=20

# Channel: production (default), beta, or staging. Set by init_channel_mode().
CHANNEL="${CHANNEL:-production}"

# Helper function to append channel query param (BETA=true or STAGING=true) when not production
append_channel_param() {
    local url="$1"
    local ch="${CHANNEL:-production}"
    if [ "$ch" = "beta" ]; then
        if [[ "$url" == *"?"* ]]; then
            echo "${url}&BETA=true"
        else
            echo "${url}?BETA=true"
        fi
    elif [ "$ch" = "staging" ]; then
        if [[ "$url" == *"?"* ]]; then
            echo "${url}&STAGING=true"
        else
            echo "${url}?STAGING=true"
        fi
    else
        echo "$url"
    fi
}

# Function to initialize and manage channel (production / beta / staging) from config.json
init_channel_mode() {
    # Ensure config.json exists
    if [ ! -f "$CONFIG_PATH" ]; then
        mkdir -p "$(dirname "$CONFIG_PATH")"
        echo '{"autoUpdate": true, "installedVersion": "none", "channel": "production"}' > "$CONFIG_PATH"
    fi

    # Read channel from config; fallback to "beta" if old "beta": true exists for backward compat
    local CONFIG_CHANNEL
    CONFIG_CHANNEL=$(jq -r '.channel // empty' "$CONFIG_PATH" 2>/dev/null || echo "")
    if [ -z "$CONFIG_CHANNEL" ] || [ "$CONFIG_CHANNEL" = "null" ]; then
        local CONFIG_BETA
        CONFIG_BETA=$(jq -r '.beta // false' "$CONFIG_PATH" 2>/dev/null || echo "false")
        if [ "$CONFIG_BETA" = "true" ] || [ "$CONFIG_BETA" = "1" ] || [ "$CONFIG_BETA" = "yes" ]; then
            CONFIG_CHANNEL="beta"
        else
            CONFIG_CHANNEL="production"
        fi
    fi

    # Check for command line flag override (--beta or --staging)
    local CHANNEL_FLAG=""
    for arg in "$@"; do
        if [ "$arg" = "--beta" ] || [ "$arg" = "-beta" ]; then
            CHANNEL_FLAG="beta"
            break
        fi
        if [ "$arg" = "--staging" ] || [ "$arg" = "-staging" ]; then
            CHANNEL_FLAG="staging"
            break
        fi
    done

    if [ -n "$CHANNEL_FLAG" ]; then
        CHANNEL="$CHANNEL_FLAG"
        if [ "$CONFIG_CHANNEL" != "$CHANNEL" ]; then
            write_config "channel" "$CHANNEL"
            echo "💾 Channel saved to config.json: $CHANNEL" >&2
        fi
    else
        CHANNEL="$CONFIG_CHANNEL"
    fi

    # Normalize
    case "$CHANNEL" in
        beta|staging|production) ;;
        *) CHANNEL="production" ;;
    esac

    if [ "$CHANNEL" = "beta" ]; then
        echo "🔷 BETA MODE ENABLED - Using beta repository" >&2
    elif [ "$CHANNEL" = "staging" ]; then
        echo "🔷 STAGING MODE ENABLED - Using staging repository" >&2
    fi
}

mkdir -p "$APP_INSTALL_DIR" "$BACKUP_DIR" "$TMP_INSTALL_DIR" "$LOG_DIR"

# ------------------------------------------------
# Auto-copy Installer
# ------------------------------------------------
if [ "$(realpath "$0")" != "$SCRIPT_PATH" ]; then
    echo "📦 Copying installer to $HOME/.hiretrack..."
    mkdir -p "$HOME/.hiretrack"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✅ Installer ready at $SCRIPT_PATH"
    #echo "▶️ Please re-run the installer: $SCRIPT_PATH --install"
    echo "🚀 Auto-running installer with --install..."
    #exec "$SCRIPT_PATH" --install
    exec "$SCRIPT_PATH" "$@"
    exit 0
fi

# ------------------------------------------------
# Utility Functions
# ------------------------------------------------
check_dep() {
    local CMD="$1"
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "⚠ $CMD not found. Installing..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y "$CMD"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "$CMD"
        else
            echo "❌ Cannot install $CMD automatically. Please install it manually."
            exit 1
        fi
    fi
    echo "✅ $CMD is available."
}



get_machine_code() {
    local OS_TYPE
    OS_TYPE=$(uname | tr '[:upper:]' '[:lower:]')
    local MAC_ADDR=""
    local PUBLIC_IP=""


    # 1. Get MAC Address (First non-loopback, non-virtual interface)
    if [[ "$OS_TYPE" == "linux" ]]; then
        # On Linux, try to get the MAC of the default route interface
        INTERFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
        if [ -n "$INTERFACE" ]; then
            MAC_ADDR=$(cat /sys/class/net/$INTERFACE/address 2>/dev/null || ip link show "$INTERFACE" | awk '/ether/ {print $2}')
        fi
    elif [[ "$OS_TYPE" == "darwin" ]]; then
        # On macOS, typically use the Wi-Fi or Ethernet MAC
        MAC_ADDR=$(networksetup -listallhardwareports | awk '/Hardware Port: (Wi-Fi|Ethernet)/{getline; getline; print $3; exit}' 2>/dev/null || ifconfig | awk '/ether / {print $2; exit}')
    else
        echo "❌ Unsupported OS: $OS_TYPE" >&2
        exit 1
    fi
    MAC_ADDR=$(echo "$MAC_ADDR" | tr -d '[:space:]')

    # 2. Get Public IP Address
    PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "0.0.0.0")
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '\r\n')

    # 3. Combine and Hash (Canonical Code)
    COMBINED_STRING="${MAC_ADDR}_${PUBLIC_IP}"
    
    local HASH_RESULT

    if command -v shasum >/dev/null 2>&1; then
        HASH_RESULT=$(printf "%s" "$COMBINED_STRING" | shasum -a 256 | awk '{print $1}')
    elif command -v sha256sum >/dev/null 2>&1; then
        HASH_RESULT=$(printf "%s" "$COMBINED_STRING" | sha256sum | awk '{print $1}')
    else
        echo "❌ Hash utility (shasum or sha256sum) not found. Cannot generate final machine code." >&2
        exit 1
    fi

    # Only output the hash result to stdout (for variable capture)
    echo "$HASH_RESULT"
}
prompt_for_email() {
    read -p "Enter your email: " EMAIL
    if [ -z "$EMAIL" ]; then
        echo "❌ Email cannot be empty."
        exit 1
    fi
    echo "$EMAIL"
}
prompt_for_update() {
    read -p "Enter your email: " EMAIL
    if [ -z "$EMAIL" ]; then
        echo "❌ Email cannot be empty."
        exit 1
    fi
    echo "$EMAIL"
}

prompt_for_version() {
    read -p "Enter the version to install: " VERSION
    if [ -z "$VERSION" ]; then
        echo "❌ Version cannot be empty."
        exit 1
    fi
    VERSION=${VERSION#hiretrack-}
    echo "$VERSION"
}

write_env_mongo_url() {
    local APP_DIR="$1"
    local URL="$2"
    local ENV_FILE="$APP_DIR/.env"
    mkdir -p "$APP_DIR"
    if [ -f "$ENV_FILE" ]; then
        grep -v "^MONGODB_URI=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
        echo "MONGODB_URI=$URL" >> "${ENV_FILE}.tmp"
        mv "${ENV_FILE}.tmp" "$ENV_FILE"
    else
        echo "MONGODB_URI=$URL" > "$ENV_FILE"
    fi
    echo "✅ MongoDB URL updated in $ENV_FILE"
}

write_env_server_details() {
    local ENV_FILE="$APP_INSTALL_DIR/.env"
    mkdir -p "$APP_INSTALL_DIR"

    # Extract serverName from config.json
    local SERVER_NAME
    SERVER_NAME=$(jq -r '.serverName // empty' "$CONFIG_PATH")

    # Handle missing server name
    if [ -z "$SERVER_NAME" ] || [ "$SERVER_NAME" = "null" ]; then
        echo "⚠️ serverName not found in $CONFIG_PATH"
        return 0
    fi

    # Determine BASE_URL
    local BASE_URL
    if [[ "$SERVER_NAME" =~ ^(localhost|127\.0\.0\.1)$ ]]; then
        BASE_URL="http://$SERVER_NAME:3000"
    elif [[ "$SERVER_NAME" =~ ^https?:// ]]; then
        BASE_URL="$SERVER_NAME"
    else
        BASE_URL="https://$SERVER_NAME"
    fi

    # Remove existing BASE_URL/NEXT_PUBLIC_BASE_URL lines if exists
    if [ -f "$ENV_FILE" ]; then
        grep -v "^BASE_URL=" "$ENV_FILE" | grep -v "^NEXT_PUBLIC_BASE_URL=" > "${ENV_FILE}.tmp" || true
    else
        touch "${ENV_FILE}.tmp"
    fi

    # Write new BASE_URL and NEXT_PUBLIC_BASE_URL
    echo "BASE_URL=$BASE_URL" >> "${ENV_FILE}.tmp"
    echo "NEXT_PUBLIC_BASE_URL=$BASE_URL" >> "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"

    echo "✅ BASE_URL and NEXT_PUBLIC_BASE_URL updated in $ENV_FILE ($BASE_URL)"
}

write_config() {
    local KEY="$1"
    local VALUE="$2"
    jq --arg k "$KEY" --arg v "$VALUE" '.[$k]=$v' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
}

# Set channel in config.json (production | beta | staging)
set_channel_config() {
    local CH="$1"
    if [ ! -f "$CONFIG_PATH" ]; then
        mkdir -p "$(dirname "$CONFIG_PATH")"
        echo '{"autoUpdate": true, "installedVersion": "none", "channel": "production"}' > "$CONFIG_PATH"
    fi
    write_config "channel" "$CH"
    case "$CH" in
        beta)   echo "✅ Beta channel set in config.json ($CONFIG_PATH). Future updates use the beta repository." ;;
        staging) echo "✅ Staging channel set in config.json ($CONFIG_PATH). Future updates use the staging repository." ;;
        *)      echo "✅ Production channel set in config.json ($CONFIG_PATH). Future updates use the production repository." ;;
    esac

    if [ ! -f "$LICENSE_PATH" ] || ! jq -e '.licenseKey' "$LICENSE_PATH" >/dev/null 2>&1; then
        echo "   Note: License not found. Please register a license first before upgrading."
        exit 0
    fi
    echo ""
    read -p "Do you want to upgrade the app now? (y/n): " UPGRADE_CHOICE
    UPGRADE_CHOICE=$(echo "$UPGRADE_CHOICE" | tr '[:upper:]' '[:lower:]')
    if [ "$UPGRADE_CHOICE" = "y" ] || [ "$UPGRADE_CHOICE" = "yes" ]; then
        echo ""
        echo "🚀 Starting app upgrade..."
        check_update_and_install "manually"
    else
        echo "✅ Channel configuration saved. Exiting."
        exit 0
    fi
}

# Legacy: set beta on/off (maps to channel beta or production)
set_beta_config() {
    local VALUE="$1"
    if [ "$VALUE" = "true" ] || [ "$VALUE" = "1" ] || [ "$VALUE" = "yes" ]; then
        set_channel_config "beta"
    else
        set_channel_config "production"
    fi
}

# ------------------------------------------------
# Dependency Installation
# ------------------------------------------------
# Normalize version for comparison: strip leading 'v' and trim (e.g. v20.19.5 or 20.19.5 -> 20.19.5)
normalize_node_version() {
    echo "$1" | sed 's/^v//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

install_node() {
    local APP_DIR="$1"
    local NODE_VERSION NODE_MAJOR_VERSION REQUIRED_NORMALIZED NEEDS_INSTALL=false NEEDS_REMOVE=false

    if [ -n "$APP_DIR" ] && [ -f "$APP_DIR/.env" ]; then
        NODE_VERSION=$(grep -E '^NODE_VERSION=' "$APP_DIR/.env" | cut -d '=' -f2)
    fi

    if [ -z "$NODE_VERSION" ]; then
        echo "⚠️ NODE_VERSION not found in .env file. Skipping Node.js installation."
        return 0
    fi

    REQUIRED_NORMALIZED=$(normalize_node_version "$NODE_VERSION")
    NODE_MAJOR_VERSION=$(echo "$REQUIRED_NORMALIZED" | sed -n 's/^\([0-9]*\).*/\1/p')
    if [ -z "$NODE_MAJOR_VERSION" ]; then
        echo "⚠️ Could not determine Node.js version from: $NODE_VERSION. Skipping installation."
        return 0
    fi

    if command -v node >/dev/null 2>&1; then
        local CURRENT_NORMALIZED
        CURRENT_NORMALIZED=$(normalize_node_version "$(node -v 2>/dev/null)")
        if [ "$CURRENT_NORMALIZED" = "$REQUIRED_NORMALIZED" ]; then
            echo "✅ Node.js $REQUIRED_NORMALIZED already installed (found $(node -v))."
            return
        else
            echo "⚠ Found Node.js $(node -v), but $REQUIRED_NORMALIZED required (from .env)."
            NEEDS_REMOVE=true
            NEEDS_INSTALL=true
        fi
    else
        echo "⚠ Node.js not found. Will install $REQUIRED_NORMALIZED (from .env)."
        NEEDS_INSTALL=true
    fi

    if [ "$NEEDS_REMOVE" = "true" ]; then
        echo "🗑️ Removing existing Node.js installation and cleaning up PATH..."
        local NODE_PATHS=(
            "/usr/bin/node"
            "/usr/local/bin/node"
            "/opt/nodejs/bin/node"
            "/usr/bin/nodejs"
            "/usr/local/bin/nodejs"
            "$HOME/.nvm/versions/node/*/bin/node"
        )

        for NODE_PATH in "${NODE_PATHS[@]}"; do
            for p in $NODE_PATH; do
                [ -f "$p" ] && echo "   Removing $p..." && sudo rm -f "$p" 2>/dev/null || true
            done
        done

        sudo apt-get remove -y nodejs npm 2>/dev/null || true
        sudo apt-get purge -y nodejs npm 2>/dev/null || true
        sudo rm -rf /usr/lib/node_modules ~/.nvm 2>/dev/null || true
        sudo rm -f /etc/apt/sources.list.d/nodesource*.list /usr/share/keyrings/nodesource.gpg 2>/dev/null || true
        hash -r 2>/dev/null || true

        # Remove NVM path from startup scripts if any
        sed -i '/nvm/d' ~/.bashrc ~/.profile ~/.bash_login ~/.bash_profile 2>/dev/null || true
        export PATH="/usr/local/bin:/usr/bin:/bin"
        echo "✅ Cleanup complete. PATH reset to safe defaults."
    fi

    if [ "$NEEDS_INSTALL" = "true" ]; then
        echo "📦 Installing Node.js $REQUIRED_NORMALIZED (exact version from .env)..."
        local NODE_DIST_VER="v$REQUIRED_NORMALIZED"
        local OS_TYPE ARCH NODE_TAR DIRNAME
        OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64|amd64) ARCH="x64" ;;
            aarch64|arm64) ARCH="arm64" ;;
            *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
        esac
        case "$OS_TYPE" in
            linux) DIRNAME="node-${NODE_DIST_VER}-linux-${ARCH}" ;;
            darwin) DIRNAME="node-${NODE_DIST_VER}-darwin-${ARCH}" ;;
            *) echo "❌ Unsupported OS: $OS_TYPE"; exit 1 ;;
        esac
        local NODE_INSTALL_ROOT="${NODE_INSTALL_ROOT:-/usr/local}"
        local NODE_DIR="$NODE_INSTALL_ROOT/$DIRNAME"
        NODE_TAR="/tmp/${DIRNAME}.tar.xz"
        local NODE_URL="https://nodejs.org/dist/${NODE_DIST_VER}/${DIRNAME}.tar.xz"

        if [ ! -d "$NODE_DIR" ] || ! "$NODE_DIR/bin/node" -v 2>/dev/null | grep -qF "$REQUIRED_NORMALIZED"; then
            echo "   Downloading from $NODE_URL"
            curl -fsSL -o "$NODE_TAR" "$NODE_URL" || { echo "❌ Failed to download Node.js $REQUIRED_NORMALIZED."; exit 1; }
            sudo mkdir -p "$NODE_INSTALL_ROOT"
            sudo rm -rf "$NODE_DIR"
            sudo tar -xJf "$NODE_TAR" -C "$NODE_INSTALL_ROOT" || { rm -f "$NODE_TAR"; echo "❌ Failed to extract Node.js."; exit 1; }
            sudo rm -f "$NODE_TAR"
        fi

        if [ ! -x "$NODE_DIR/bin/node" ]; then
            echo "❌ Node.js binary not found at $NODE_DIR/bin/node"
            exit 1
        fi

        # Symlink node, npm, npx into /usr/local/bin so they are available globally for all users
        # (avoids relying on PATH in profile, which may be root's when installer runs with sudo)
        echo "   Linking Node.js binaries to /usr/local/bin for global access..."
        sudo ln -sf "$NODE_DIR/bin/node" /usr/local/bin/node
        sudo ln -sf "$NODE_DIR/bin/npm" /usr/local/bin/npm
        sudo ln -sf "$NODE_DIR/bin/npx" /usr/local/bin/npx

        # Prepend to PATH and persist so exec $SHELL -l gets the new node
        export PATH="$NODE_DIR/bin:$PATH"
        local PROFILE
        for PROFILE in ~/.bashrc ~/.profile; do
            if [ -f "$PROFILE" ] && ! grep -qF "$NODE_DIR/bin" "$PROFILE" 2>/dev/null; then
                echo "export PATH=\"$NODE_DIR/bin:\$PATH\"" >> "$PROFILE"
            fi
        done
        hash -r

        local NODE_PATH NODE_VER NPM_VER
        NODE_PATH=$(command -v node)
        NODE_VER=$(node -v)
        NPM_VER=$(npm -v 2>/dev/null || echo "missing")
        echo "✅ Node.js $NODE_VER and npm $NPM_VER installed successfully."
        echo "   Active binary: $NODE_PATH"
        echo "♻️ Reloading environment to apply Node.js changes..."
        hash -r
        sleep 1
        if command -v node >/dev/null 2>&1; then
            echo "✅ Node.js environment refreshed successfully (using $(node -v))"
        else
            echo "⚠️ Node.js not detected after reload. You may need to restart your terminal manually."
        fi
    fi
}

# Logout/exit user to restart terminal session (for fresh Node.js installation)
logout_user() {
    echo ""
    echo "🔄 Node.js has been installed successfully."
    echo "   Please logout and login again (or restart your terminal) to apply the changes,"
    echo "   then run the installer again to continue."
    echo ""
    # Exit the script - user needs to logout/login manually to get the updated PATH
    # The PATH has been added to ~/.bashrc/~/.profile, so after logout/login it will be available
    exit 0
}

# Returns 0 if Node.js is not installed, 1 if installed
is_node_installed() {
    command -v node >/dev/null 2>&1
}

# Returns 0 if Node.js needs to be installed (missing or version mismatch), 1 otherwise.
# Compares full version from extracted .env to installed node (e.g. 20.19.5 vs 20.19.5).
need_node_install() {
    local APP_DIR="$1"
    local NODE_VERSION REQUIRED_NORMALIZED CURRENT_NORMALIZED

    if [ -z "$APP_DIR" ] || [ ! -f "$APP_DIR/.env" ]; then
        return 1
    fi
    NODE_VERSION=$(grep -E '^NODE_VERSION=' "$APP_DIR/.env" 2>/dev/null | cut -d '=' -f2)
    if [ -z "$NODE_VERSION" ]; then
        return 1
    fi
    REQUIRED_NORMALIZED=$(normalize_node_version "$NODE_VERSION")
    if [ -z "$REQUIRED_NORMALIZED" ] || ! echo "$REQUIRED_NORMALIZED" | grep -qE '^[0-9]+\.[0-9]'; then
        return 1
    fi
    if ! is_node_installed; then
        return 0
    fi
    CURRENT_NORMALIZED=$(normalize_node_version "$(node -v 2>/dev/null)")
    if [ "$CURRENT_NORMALIZED" = "$REQUIRED_NORMALIZED" ]; then
        return 1
    fi
    return 0
}

check_pm2() {
    # Check if APP_INSTALL_DIR exists and contains required files
    if [ ! -d "$APP_INSTALL_DIR" ]; then
        echo "⚠️ App install directory not found: $APP_INSTALL_DIR. Skipping PM2 installation."
        return 0
    fi

    if [ ! -f "$APP_INSTALL_DIR/.env" ]; then
        echo "⚠️ .env file not found in $APP_INSTALL_DIR. Skipping PM2 installation."
        return 0
    fi

    if [ ! -f "$APP_INSTALL_DIR/package.json" ]; then
        echo "⚠️ package.json not found in $APP_INSTALL_DIR. Skipping PM2 installation."
        return 0
    fi

    install_node "$APP_INSTALL_DIR"
    if command -v pm2 >/dev/null 2>&1; then
        echo "✅ PM2 already installed."
    else
        echo "📦 Installing PM2 globally..."
        npm install -g pm2
        if command -v pm2 >/dev/null 2>&1; then
            echo "✅ PM2 installed."
        else
            echo "❌ Failed to install PM2."
            exit 1
        fi
    fi
}

install_and_start_mongodb() {
    local OS_TYPE
    OS_TYPE=$(uname | tr '[:upper:]' '[:lower:]')
    local LATEST_VERSION=""

    if command -v mongod >/dev/null 2>&1; then
        echo "✅ MongoDB already installed."
        [[ "$OS_TYPE" == "darwin" ]] && LATEST_VERSION=$(brew list --formula | grep -E '^mongodb-community@[0-9]+\.[0-9]+' | sort -V | tail -n 1)
    else
        echo "📦 Installing MongoDB $MONGODB_VERSION..."
        if [[ "$OS_TYPE" == "darwin" ]]; then
            [ ! -x "$(command -v brew)" ] && { echo "❌ Install Homebrew first"; exit 1; }
            brew tap mongodb/brew
            LATEST_VERSION=$(brew search mongodb-community@ | grep -Eo 'mongodb-community@[0-9]+\.[0-9]+' | sort -V | tail -n 1)
            [ -z "$LATEST_VERSION" ] && { echo "❌ MongoDB formula not found"; exit 1; }
            brew install "$LATEST_VERSION"
        elif [[ "$OS_TYPE" == "linux" ]]; then
            if command -v apt-get >/dev/null 2>&1; then
                sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
                curl -fsSL https://www.mongodb.org/static/pgp/server-$MONGODB_VERSION.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-$MONGODB_VERSION.gpg
                local CODENAME=$(lsb_release -cs)
                if [[ "$CODENAME" == "noble" ]]; then
                    echo "⚠ Ubuntu Noble (24.04) detected. Using Jammy (22.04) repository for MongoDB $MONGODB_VERSION."
                    CODENAME="jammy"
                fi
                echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGODB_VERSION.gpg ] https://repo.mongodb.org/apt/ubuntu $CODENAME/mongodb-org/$MONGODB_VERSION multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-$MONGODB_VERSION.list
                sudo apt-get update
                if ! sudo apt-get install -y mongodb-org; then
                    echo "❌ Failed to install MongoDB $MONGODB_VERSION. Trying MongoDB 6.0 as fallback..."
                    MONGODB_VERSION="6.0"
                    sudo rm -f /etc/apt/sources.list.d/mongodb-org-$MONGODB_VERSION.list
                    curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-6.0.gpg
                    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] https://repo.mongodb.org/apt/ubuntu $CODENAME/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
                    sudo apt-get update
                    if ! sudo apt-get install -y mongodb-org; then
                        echo "❌ Failed to install MongoDB. Please install it manually from https://www.mongodb.com/docs/manual/installation/"
                        exit 1
                    fi
                fi
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y mongodb-org
            else
                echo "❌ Unsupported Linux. Install MongoDB manually."
                exit 1
            fi
        else
            echo "❌ Unsupported OS: $OS_TYPE"
            exit 1
        fi
    fi

    echo "▶️ Starting MongoDB service..."
    if [[ "$OS_TYPE" == "darwin" ]]; then
        [ -z "$LATEST_VERSION" ] && LATEST_VERSION="mongodb-community@$MONGODB_VERSION"
        brew services start "$LATEST_VERSION" || { echo "❌ Failed to start MongoDB via Homebrew"; exit 1; }
    elif [[ "$OS_TYPE" == "linux" ]]; then
        sudo systemctl start mongod || { echo "❌ Failed to start MongoDB"; exit 1; }
        sudo systemctl enable mongod || { echo "❌ Failed to enable MongoDB"; exit 1; }
    fi
    sleep 5
    if pgrep -x "mongod" >/dev/null; then
        echo "✅ MongoDB running"
        if command -v mongo >/dev/null 2>&1; then
            mongo --eval "db.adminCommand('ping')" >/dev/null 2>&1 && echo "✅ MongoDB connection verified" || { echo "❌ MongoDB connection failed"; exit 1; }
        else
            echo "⚠ MongoDB shell not found, skipping connection test"
        fi
    else
        echo "❌ MongoDB failed to start. Check logs at /var/log/mongodb/mongod.log"
        exit 1
    fi
}

# ------------------------------------------------
# Config and License Management
# ------------------------------------------------
create_default_config() {
    local PASSED_EMAIL="${1:-}"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo '{"autoUpdate": true, "installedVersion": "none", "channel": "production"}' > "$CONFIG_PATH"
        echo "✅ Default config created at $CONFIG_PATH"
    else
        # Ensure channel exists; migrate old beta-only config
        if ! jq -e '.channel' "$CONFIG_PATH" >/dev/null 2>&1; then
            local BETA_VAL
            BETA_VAL=$(jq -r '.beta // false' "$CONFIG_PATH" 2>/dev/null || echo "false")
            if [ "$BETA_VAL" = "true" ] || [ "$BETA_VAL" = "1" ] || [ "$BETA_VAL" = "yes" ]; then
                write_config "channel" "beta"
            else
                write_config "channel" "production"
            fi
        fi
    fi

    if [ -n "$PASSED_EMAIL" ]; then
        if ! echo "$PASSED_EMAIL" | grep -E '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' >/dev/null 2>&1; then
            echo "❌ Invalid email format: $PASSED_EMAIL"
            exit 1
        fi
        local EXISTING_EMAIL
        EXISTING_EMAIL=$(jq -r '.email // empty' "$CONFIG_PATH" 2>/dev/null || echo "")
        if [ -n "$EXISTING_EMAIL" ] && [ "$EXISTING_EMAIL" != "$PASSED_EMAIL" ]; then
           echo "Existing email"
           exit 0
        fi
    fi
}

register_license() {
    # Check if license.json exists and contains a valid license key
    if [ -f "$LICENSE_PATH" ] && jq -e '.licenseKey' "$LICENSE_PATH" >/dev/null 2>&1; then
        local EXISTING_LICENSE_KEY
        EXISTING_LICENSE_KEY=$(jq -r '.licenseKey' "$LICENSE_PATH")
        if [ -n "$EXISTING_LICENSE_KEY" ] && [ "$EXISTING_LICENSE_KEY" != "null" ]; then
            echo "✅ License key already exists in $LICENSE_PATH. Skipping registration."
            return 0
        fi
    fi
    local EMAIL="$1"
    [ -z "$EMAIL" ] && EMAIL=$(prompt_for_email)
    local MACHINE_CODE=$(get_machine_code)
    local EXISTING_DB_CHOICE
    EXISTING_DB_CHOICE=$(jq -r '.dbChoice // empty' "$CONFIG_PATH")
    local SKIP_DB_SETUP=""
    if [ -n "$EXISTING_DB_CHOICE" ]; then
        echo "✅ Database preference already set: $EXISTING_DB_CHOICE"
        local EXISTING_DB_URL
        EXISTING_DB_URL=$(jq -r '.dbUrl // empty' "$CONFIG_PATH")
        [ -n "$EXISTING_DB_URL" ] && echo "🔗 Existing DB URL: $EXISTING_DB_URL"
        read -p "Do you want to override the database preference and URL? [y/N]: " OVERRIDE
        OVERRIDE=${OVERRIDE:-N}
        if [[ ! "$OVERRIDE" =~ ^[Yy]$ ]]; then
            SKIP_DB_SETUP=1
            # Ensure current .env reflects existing DB URL if present
            if [ -n "$EXISTING_DB_URL" ]; then
                write_env_mongo_url "$APP_INSTALL_DIR" "$EXISTING_DB_URL"
            fi
        fi
    fi

    if [ -z "$SKIP_DB_SETUP" ]; then
        echo "📦 Choose MongoDB option:"
        echo "1) MongoDB Atlas (cloud)"
        echo "2) Local MongoDB"
        read -p "Enter choice [1/2]: " DB_CHOICE

        local APP_DIR="$APP_INSTALL_DIR"
        local DB_URL
        if [ "$DB_CHOICE" == "1" ]; then
            read -p "Enter your MongoDB Atlas connection URL: " ATLAS_URL
            [ -z "$ATLAS_URL" ] && { echo "❌ MongoDB Atlas URL cannot be empty."; exit 1; }
            DB_URL="$ATLAS_URL"
            write_config "dbChoice" "atlas"
        elif [ "$DB_CHOICE" == "2" ]; then
            install_and_start_mongodb
            DB_URL="mongodb://localhost:27017/hiretrack"
            write_config "dbChoice" "local"
        else
            echo "❌ Invalid choice."
            exit 1
        fi
        write_env_mongo_url "$APP_DIR" "$DB_URL"
        write_config "dbUrl" "$DB_URL"
    fi
    local RESPONSE
    RESPONSE=$(curl -s -X POST "$API_URL" -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\",\"machineCode\":\"$MACHINE_CODE\"}")
    if [ -z "$RESPONSE" ] || ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
        echo "❌ License registration failed: Invalid response."
        exit 1
    fi
    local ERROR_MSG
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error // empty')
    if [ -n "$ERROR_MSG" ] && [ "$ERROR_MSG" != "null" ]; then
        echo "❌ License registration failed: $ERROR_MSG"
        exit 1
    fi
    local LICENSE_KEY EMAIL_RES
    LICENSE_KEY=$(echo "$RESPONSE" | jq -r '.license.licenseKey')
    EMAIL_RES=$(echo "$RESPONSE" | jq -r '.license.email')
    if [ -z "$LICENSE_KEY" ] || [ "$LICENSE_KEY" == "null" ] || [ -z "$EMAIL_RES" ] || [ "$EMAIL_RES" == "null" ]; then
        echo "❌ License registration failed."
        exit 1
    fi

    echo "{\"licenseKey\":\"$LICENSE_KEY\"}" > "$LICENSE_PATH"
    echo "✅ License saved at $LICENSE_PATH"
    if [ -n "$EMAIL_RES" ] && [ "$EMAIL_RES" != "null" ]; then
        write_config "email" "$EMAIL_RES"
    fi
}
update_license() {
    local EMAIL="$1"
    [ -z "$EMAIL" ] && EMAIL=$(prompt_for_email)
    local MACHINE_CODE=$(get_machine_code)

    # Check if license.json exists and contains a license key
    if [ ! -f "$LICENSE_PATH" ] || ! jq -e '.licenseKey' "$LICENSE_PATH" >/dev/null 2>&1; then
        echo "❌ No valid license key found in $LICENSE_PATH. Please register a license first."
        exit 1
    fi
    local OLD_LICENSE_KEY
    OLD_LICENSE_KEY=$(jq -r '.licenseKey' "$LICENSE_PATH")

    local EXISTING_DB_CHOICE
    

    # Send update request with old license key
    local RESPONSE
    RESPONSE=$(curl -s -X PATCH "$API_URL_UPDATE_LIC" -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\",\"machineCode\":\"$MACHINE_CODE\",\"licenseKey\":\"$OLD_LICENSE_KEY\"}")

    if [ -z "$RESPONSE" ] || ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
        echo "❌ License update failed: Invalid response."
        exit 1
    fi

    local NEW_LICENSE_KEY EMAIL_RES
    NEW_LICENSE_KEY=$(echo "$RESPONSE" | jq -r '.newLicenseKey')
    EMAIL_RES=$(echo "$RESPONSE" | jq -r '.email')
    if [ -z "$NEW_LICENSE_KEY" ] || [ "$NEW_LICENSE_KEY" == "null" ] || [ -z "$EMAIL_RES" ] || [ "$EMAIL_RES" == "null" ]; then
        echo "❌ License update failed."
        exit 1
    fi

    # Save new license key to license.json
    echo "{\"licenseKey\":\"$NEW_LICENSE_KEY\"}" > "$LICENSE_PATH"
    echo "✅ License updated and saved at $LICENSE_PATH"
    if [ -n "$EMAIL_RES" ] && [ "$EMAIL_RES" != "null" ]; then
        write_config "email" "$EMAIL_RES"
    fi
}

validate_license_and_get_asset() {
    local VERSION="${1:-}"
    if [ ! -f "$LICENSE_PATH" ]; then
        echo "❌ License not found. Please register first." >&2
        return 1
    fi

    local LICENSE_KEY=$(jq -r '.licenseKey' "$LICENSE_PATH")
    local MACHINE_CODE=$(get_machine_code)
    local INSTALLED_VERSION=$(jq -r '.installedVersion // "none"' "$CONFIG_PATH")
    local VERSION_TO_SEND="${VERSION:-$INSTALLED_VERSION}"
    
    # Build query parameters
    local QUERY_PARAMS="licenseKey=$(printf '%s' "$LICENSE_KEY" | jq -sRr @uri)&machineCode=$(printf '%s' "$MACHINE_CODE" | jq -sRr @uri)"
    if [ -n "$VERSION_TO_SEND" ] && [ "$VERSION_TO_SEND" != "none" ]; then
        QUERY_PARAMS="${QUERY_PARAMS}&installedVersion=$(printf '%s' "$VERSION_TO_SEND" | jq -sRr @uri)"
    fi
    
    local TMP_FILE="$HOME/.hiretrack/tmp_asset.tar.gz"
    local HTTP_CODE
    
    # Remove any existing partial download
    rm -f "$TMP_FILE"
    
    # Download asset with license validation
    # -w writes HTTP code to stdout, -o saves response body to file
    # --progress-bar shows download progress on stderr
    # Capture HTTP code from stdout (last line), progress shows on stderr
    echo "📥 Downloading asset with license validation..." >&2
    local ASSET_URL="${ASSET_DOWNLOAD_API}?${QUERY_PARAMS}"
    ASSET_URL=$(append_channel_param "$ASSET_URL")
    HTTP_CODE=$(curl -w "\n%{http_code}" -o "$TMP_FILE" \
        --progress-bar \
        "$ASSET_URL" 2>&1 | grep -E '^[0-9]{3}$' | tail -n1 || echo "000")
    # echo "ASSET_URL: $ASSET_URL" >&2
    # Check for curl errors (non-HTTP errors like network failures)
    if [ -z "$HTTP_CODE" ] || ! echo "$HTTP_CODE" | grep -qE '^[0-9]{3}$'; then
        echo "❌ Network error: Failed to connect to server. Please check your internet connection." >&2
        rm -f "$TMP_FILE"
        return 1
    fi
    
    # Check if download was successful (HTTP 200)
    if [ "$HTTP_CODE" != "200" ]; then
        # Try to read error message from response if it's JSON
        if [ -f "$TMP_FILE" ] && [ -s "$TMP_FILE" ]; then
            # Check if response starts with '{' (JSON error message)
            local FIRST_CHAR
            FIRST_CHAR=$(head -c 1 "$TMP_FILE" 2>/dev/null || echo "")
            if [ "$FIRST_CHAR" = "{" ]; then
                local ERROR_MSG
                ERROR_MSG=$(jq -r '.error // .message // "Unknown error"' "$TMP_FILE" 2>/dev/null || echo "License validation failed")
                echo "❌ License validation failed: $ERROR_MSG" >&2
            else
                echo "❌ License validation failed: HTTP $HTTP_CODE" >&2
            fi
        else
            echo "❌ License validation failed: HTTP $HTTP_CODE (No response body)" >&2
        fi
        rm -f "$TMP_FILE"
        return 1
    fi
    
    # Verify file was downloaded and has content
    if [ ! -f "$TMP_FILE" ] || [ ! -s "$TMP_FILE" ]; then
        echo "❌ Downloaded file is empty or missing." >&2
        rm -f "$TMP_FILE"
        return 1
    fi
    
    # Check file size (should be > 0 and reasonable)
    local FILE_SIZE
    FILE_SIZE=$(stat -f%z "$TMP_FILE" 2>/dev/null || stat -c%s "$TMP_FILE" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -lt 1000 ]; then
        echo "❌ Downloaded file is too small ($FILE_SIZE bytes). File may be corrupted or incomplete." >&2
        rm -f "$TMP_FILE"
        return 1
    fi
    
    # Return the downloaded file path
    echo "$TMP_FILE"
}

# ------------------------------------------------
# Version Management
# ------------------------------------------------
check_latest_version() {
    local VERSION_URL=$(append_channel_param "$LATEST_VERSION_API")
    local RESPONSE=$(curl -s "$VERSION_URL")
    if [ -z "$RESPONSE" ] || ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
        echo "❌ Failed to get latest version info."
        exit 1
    fi
    local LATEST_VERSION=$(echo "$RESPONSE" | jq -r '.latestVerson // .latestVersion // empty')
    if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then
        echo "❌ No latest version found."
        exit 1
    fi
    echo "$LATEST_VERSION"
}


# -------------------------------
# Rollback helper function
# -------------------------------




rollback() {
    # Get previous version from config.json
    local VERSION_TO_RESTORE
    if [ -f "$CONFIG_PATH" ]; then
        VERSION_TO_RESTORE=$(jq -r '.previousVersion // empty' "$CONFIG_PATH")
    fi

    if [ -z "$VERSION_TO_RESTORE" ] || [ "$VERSION_TO_RESTORE" = "null" ] || [ "$VERSION_TO_RESTORE" = "none" ]; then
        echo "❌ No previous version found in config.json for rollback" | tee -a "$ROLLBACK_LOG_FILE"
        return 1
    fi

    echo "🔄 Rolling back to version $VERSION_TO_RESTORE..." | tee -a "$ROLLBACK_LOG_FILE"

    # Download the previous version
    echo "📥 Downloading version $VERSION_TO_RESTORE..." | tee -a "$ROLLBACK_LOG_FILE"
    local TMP_FILE
    TMP_FILE=$(validate_license_and_get_asset "$VERSION_TO_RESTORE") || {
        echo "❌ Failed to download version $VERSION_TO_RESTORE" | tee -a "$ROLLBACK_LOG_FILE"
        return 1
    }

    if [ ! -f "$TMP_FILE" ]; then
        echo "❌ Downloaded file not found at $TMP_FILE" | tee -a "$ROLLBACK_LOG_FILE"
        return 1
    fi

    # Check file size
    local FILE_SIZE
    FILE_SIZE=$(stat -f%z "$TMP_FILE" 2>/dev/null || stat -c%s "$TMP_FILE" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -lt 1000 ]; then
        echo "❌ Downloaded file is too small ($FILE_SIZE bytes). File may be corrupted." | tee -a "$ROLLBACK_LOG_FILE"
        rm -f "$TMP_FILE"
        return 1
    fi

    # Remove current install directory (only if exists)
    if [ -d "$APP_INSTALL_DIR" ]; then
        if rm --help 2>&1 | grep -q -- '--no-preserve-root'; then
            sudo rm -rf --no-preserve-root "$APP_INSTALL_DIR"
        else
            sudo rm -rf "$APP_INSTALL_DIR"
        fi
    fi

    # Extract the downloaded version
    mkdir -p "$APP_INSTALL_DIR"
    echo "📂 Extracting archive to $APP_INSTALL_DIR..." | tee -a "$ROLLBACK_LOG_FILE"
    
    local EXTRACT_OUTPUT EXTRACT_STATUS
    EXTRACT_OUTPUT=$(tar --no-xattrs -xzf "$TMP_FILE" -C "$APP_INSTALL_DIR" 2>&1)
    EXTRACT_STATUS=$?
    
    # Filter out harmless macOS xattr warnings
    if [ -n "$EXTRACT_OUTPUT" ]; then
        echo "$EXTRACT_OUTPUT" | grep -v "LIBARCHIVE.xattr" | grep -v "^$" >&2 || true
    fi
    
    # Clean up temp file after extraction
    rm -f "$TMP_FILE" >/dev/null 2>&1 || true

    if [ $EXTRACT_STATUS -ne 0 ]; then
        echo "❌ Extraction failed. The archive may be corrupted." | tee -a "$ROLLBACK_LOG_FILE"
        return 1
    fi

    # Verify package.json exists
    if [ ! -f "$APP_INSTALL_DIR/package.json" ]; then
        echo "❌ package.json not found after extraction." | tee -a "$ROLLBACK_LOG_FILE"
        return 1
    fi

    # Database setup
    local DB_URL DB_CHOICE
    DB_URL=$(jq -r '.dbUrl // empty' "$CONFIG_PATH")
    DB_CHOICE=$(jq -r '.dbChoice // empty' "$CONFIG_PATH")
    [ -n "$DB_URL" ] && write_env_mongo_url "$APP_INSTALL_DIR" "$DB_URL"

    [ "$DB_CHOICE" = "local" ] && install_and_start_mongodb

    # Compare required Node version (from extracted app .env) with current system:
    # - If Node.js is NOT installed → install → logout user (restart terminal)
    # - If Node.js version mismatch → update → continue (no logout needed)
    if need_node_install "$APP_INSTALL_DIR"; then
        if ! is_node_installed; then
            # Node.js is not installed - install it and logout user
            echo "⚠️  Node.js is not installed. Installing Node.js..." | tee -a "$ROLLBACK_LOG_FILE"
            install_node "$APP_INSTALL_DIR" || {
                echo "❌ Node install failed during rollback." | tee -a "$ROLLBACK_LOG_FILE"
                return 1
            }
            echo "✅ Node.js installed. Logging out to restart terminal session..." | tee -a "$ROLLBACK_LOG_FILE"
            logout_user
        else
            # Node.js is installed but wrong version - update it and continue
            echo "⚠️  Node.js version mismatch. Updating Node.js..." | tee -a "$ROLLBACK_LOG_FILE"
            install_node "$APP_INSTALL_DIR" || {
                echo "❌ Node update failed during rollback." | tee -a "$ROLLBACK_LOG_FILE"
                return 1
            }
            echo "✅ Node.js updated. Continuing with rollback..." | tee -a "$ROLLBACK_LOG_FILE"
        fi
    fi
    # Ensure Node.js is available (in case it was already correct version)
    install_node "$APP_INSTALL_DIR" || {
        echo "❌ Node install failed during rollback." | tee -a "$ROLLBACK_LOG_FILE"
        return 1
    }

    cd "$APP_INSTALL_DIR" || exit

    echo "📦 Restoring dependencies..." | tee -a "$ROLLBACK_LOG_FILE"
    if ! clean_npm_install "$APP_INSTALL_DIR" 2>&1 | tee -a "$ROLLBACK_LOG_FILE"; then
        echo "❌ npm install failed during rollback." | tee -a "$ROLLBACK_LOG_FILE"
        return 1
    fi

    write_env_server_details
    check_pm2

    echo "🚀 Restarting previous version with PM2..." | tee -a "$ROLLBACK_LOG_FILE"

    # Kill only hiretrack-* processes, not all
    echo "🧹 Cleaning up old hiretrack PM2 processes..." | tee -a "$ROLLBACK_LOG_FILE"
    pm2 list | awk '/hiretrack-/ {print $4}' | while read -r PROC; do
        if [ -n "$PROC" ]; then
            echo "🛑 Stopping $PROC..." | tee -a "$ROLLBACK_LOG_FILE"
            pm2 delete "$PROC" 2>&1 | tee -a "$ROLLBACK_LOG_FILE" || true
        fi
    done

    # Format version name for PM2
    local VERSION_NAME="$VERSION_TO_RESTORE"
    if [[ "$VERSION_NAME" != v* ]]; then
        VERSION_NAME="v$VERSION_NAME"
    fi

    # Start the restored version
    pm2 start "npm run start" --name "hiretrack-$VERSION_NAME" --cwd "$APP_INSTALL_DIR" 2>&1 | tee -a "$ROLLBACK_LOG_FILE" || {
        echo "❌ Failed to start PM2 process." | tee -a "$ROLLBACK_LOG_FILE"
        return 1
    }

    pm2 save --force >/dev/null 2>&1 || true

    echo "✅ Rollback completed." | tee -a "$ROLLBACK_LOG_FILE"
    write_config "installedVersion" "$VERSION_NAME"
}



clean_npm_install() {
    local TARGET_DIR="${1:-$PWD}"

    if [ ! -d "$TARGET_DIR" ]; then
        echo "❌ Target directory not found: $TARGET_DIR"
        return 1
    fi

    if [ ! -f "$TARGET_DIR/package.json" ]; then
        echo "❌ package.json not found in $TARGET_DIR"
        echo "📁 Directory contents:"
        ls -la "$TARGET_DIR" | head -40 || true
        return 1
    fi

    (
    cd "$TARGET_DIR" || exit 1

    case ":$PATH:" in
        *":/bin:"*) ;;
        *) export PATH="/usr/local/bin:/usr/bin:/bin:$PATH" ;;
    esac
    echo "🧹 Performing full clean-room reset for npm in directory: ($PWD)..."

    # npm cache clean --force >/dev/null 2>&1 || true   
    # sudo rm -r package-lock.json >/dev/null 2>&1 || true
    if [ -d node_modules ]; then
        echo "   removing node_modules..."
        rm -rf node_modules 2>/dev/null || sudo rm -rf node_modules
    fi

    echo "🔍 Node version: $(node -v)"
    echo "🔍 npm version: $(npm -v)"
    echo "🔍 node path: $(command -v node)"
    echo "🔍 npm path: $(command -v npm)"

    echo "📦 Running npm install in clean mode... in directory: ($PWD)..."
    npm install --legacy-peer-deps
    local NPM_EXIT=$?
    if [ $NPM_EXIT -ne 0 ]; then
        echo "❌ npm install failed with code $NPM_EXIT"
        return $NPM_EXIT
    fi

    echo "✅ npm install completed successfully in $(pwd)"
    )
}

# -------------------------------
# Main update & install function
# -------------------------------

check_update_and_install() {
    create_default_config
    local FLAG1="${1:-}"
    local AUTO_UPDATE
    AUTO_UPDATE=$(jq -r '.autoUpdate' "$CONFIG_PATH")
    local INSTALLED_VERSION
    INSTALLED_VERSION=$(jq -r '.installedVersion // "none"' "$CONFIG_PATH")
    local TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    local LOG_TO_FILE="false"

    # 🔹 Detect manual update
    if [ "$FLAG1" = "manually" ]; then
        LOG_TO_FILE="true"
        echo "[$TIMESTAMP] ⚡ Manual update triggered." | tee -a "$MANUAL_LOG_FILE"
    fi

    # 🔹 Helper: unified echo wrapper
    log() {
        local MSG="$1"
        local NOW
        NOW=$(date '+%Y-%m-%d %H:%M:%S')
        if [ "$LOG_TO_FILE" = "true" ]; then
            echo "[$NOW] $MSG" | tee -a "$MANUAL_LOG_FILE"
        else
            echo "$MSG"
        fi
    }

    # ---------------------------------------------------
    # Begin update process
    # ---------------------------------------------------
    if [ "$AUTO_UPDATE" != "true" ] && [ "$LOG_TO_FILE" != "true" ]; then
        log "✅ Auto-update disabled. Keeping version: $INSTALLED_VERSION"
        return 0
    fi

    log "🔍 Checking latest version..."
    local LATEST_VERSION
    LATEST_VERSION=$(check_latest_version) || { log "❌ Failed to fetch latest version."; return 1; }

    local NORMALIZED_INSTALLED NORMALIZED_LATEST
    NORMALIZED_INSTALLED=$(echo "${INSTALLED_VERSION#v}" | tr -d '[:space:]')
    NORMALIZED_LATEST=$(echo "${LATEST_VERSION#v}" | tr -d '[:space:]')

    log "📋 Installed: $INSTALLED_VERSION | Latest: $LATEST_VERSION"

    if [ "$INSTALLED_VERSION" != "none" ] && [ "$NORMALIZED_INSTALLED" = "$NORMALIZED_LATEST" ] ; then
        # Ensure the app directory actually contains files (not empty)
        if [ -d "$APP_INSTALL_DIR" ] && [ "$(find "$APP_INSTALL_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            log "✅ Already up to date."
            return 0
        else
            log "⚠️ Installed version matches latest but $APP_INSTALL_DIR appears empty. Proceeding with reinstall/update."
        fi
    fi

    log "🚀 Update available: upgrading to $LATEST_VERSION"
    
    # Store current version as previousVersion in config.json before updating
    if [ "$INSTALLED_VERSION" != "none" ] && [ -n "$INSTALLED_VERSION" ]; then
        log "💾 Storing previous version ($INSTALLED_VERSION) in config.json..."
        write_config "previousVersion" "$INSTALLED_VERSION"
    fi
    
    local TMP_FILE
    TMP_FILE=$(validate_license_and_get_asset "$LATEST_VERSION") || { log "❌ Failed to validate license and download asset."; return 1; }
    
    if [ ! -f "$TMP_FILE" ]; then
        log "❌ Downloaded file not found at $TMP_FILE"
        return 1
    fi
    
    log "✅ Asset downloaded successfully: $TMP_FILE"
    
    sleep 1
    # Derive PM2 app name from target version instead of temp file name
    # ensure we keep a leading "v" for clarity (hiretrack-v2.x.x)
    local FILENAME VERSION_NAME APP_NAME_WITH_VERSION
    FILENAME=$(basename "$TMP_FILE")
    VERSION_NAME="$LATEST_VERSION"
    if [[ "$VERSION_NAME" != v* ]]; then
        VERSION_NAME="v$VERSION_NAME"
    fi
    APP_NAME_WITH_VERSION="hiretrack-$VERSION_NAME"



    # Validate downloaded file before extraction
    if [ ! -f "$TMP_FILE" ]; then
        log "❌ Downloaded file not found at $TMP_FILE"
        rollback
        return 1
    fi

    # Check file size (should be > 0 and reasonable)
    local FILE_SIZE
    FILE_SIZE=$(stat -f%z "$TMP_FILE" 2>/dev/null || stat -c%s "$TMP_FILE" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -lt 1000 ]; then
        log "❌ Downloaded file is too small ($FILE_SIZE bytes). File may be corrupted or incomplete."
        log "💡 This may indicate a network issue or incomplete download."
        rm -f "$TMP_FILE"
        rollback
        return 1
    fi

    # Format file size for display
    local FILE_SIZE_DISPLAY
    if command -v numfmt >/dev/null 2>&1; then
        FILE_SIZE_DISPLAY=$(numfmt --to=iec-i --suffix=B "$FILE_SIZE" 2>/dev/null || echo "${FILE_SIZE} bytes")
    elif [ "$FILE_SIZE" -gt 1073741824 ]; then
        FILE_SIZE_DISPLAY=$(awk "BEGIN {printf \"%.2f GB\", $FILE_SIZE/1073741824}")
    elif [ "$FILE_SIZE" -gt 1048576 ]; then
        FILE_SIZE_DISPLAY=$(awk "BEGIN {printf \"%.2f MB\", $FILE_SIZE/1048576}")
    elif [ "$FILE_SIZE" -gt 1024 ]; then
        FILE_SIZE_DISPLAY=$(awk "BEGIN {printf \"%.2f KB\", $FILE_SIZE/1024}")
    else
        FILE_SIZE_DISPLAY="${FILE_SIZE} bytes"
    fi
    log "📦 File size: $FILE_SIZE_DISPLAY"

    # Extract archive (tar will validate the archive format)
    if [ -d "$APP_INSTALL_DIR" ]; then
       if rm --help 2>&1 | grep -q -- '--no-preserve-root'; then
            sudo rm -rf --no-preserve-root "$APP_INSTALL_DIR" 2>/dev/null || true
        else
            sudo rm -rf "$APP_INSTALL_DIR" 2>/dev/null || true
        fi
    fi
    mkdir -p "$APP_INSTALL_DIR"
    log "📂 Extracting archive to $APP_INSTALL_DIR..."

    # Extract archive, filtering out macOS xattr warnings but preserving real errors
    local EXTRACT_OUTPUT EXTRACT_STATUS
    EXTRACT_OUTPUT=$(tar --no-xattrs -xzf "$TMP_FILE" -C "$APP_INSTALL_DIR" 2>&1)
    EXTRACT_STATUS=$?
    
    # Filter out harmless macOS xattr warnings
    if [ -n "$EXTRACT_OUTPUT" ]; then
        echo "$EXTRACT_OUTPUT" | grep -v "LIBARCHIVE.xattr" | grep -v "^$" >&2 || true
    fi
    
    if [ $EXTRACT_STATUS -ne 0 ]; then
        log "❌ Extraction failed. The archive may be corrupted or incomplete."
        log "💡 File size: $FILE_SIZE_DISPLAY"
        log "💡 Attempting to re-download..."
        rm -f "$TMP_FILE"
        rollback
        return 1
    fi
    # Keep temp file during extraction and PM2 startup - will be cleaned up after successful start
    log "✅ Extracted to: $APP_INSTALL_DIR"
    

    
      
    # Verify package.json exists
    if [ ! -f "$APP_INSTALL_DIR/package.json" ]; then
        log "❌ package.json not found after extraction. Archive structure may be invalid."
        log "💡 Contents of $APP_INSTALL_DIR:"
        ls -la "$APP_INSTALL_DIR" | head -20 >&2 || true
        rm -f "$TMP_FILE" >/dev/null 2>&1 || true
        rollback
        return 1
    fi
    
    log "✅ Verified package.json exists"
    # Database setup
    local DB_URL DB_CHOICE
    DB_URL=$(jq -r '.dbUrl // empty' "$CONFIG_PATH")
    DB_CHOICE=$(jq -r '.dbChoice // empty' "$CONFIG_PATH")
    [ -n "$DB_URL" ] && write_env_mongo_url "$APP_INSTALL_DIR" "$DB_URL"

    [ "$DB_CHOICE" = "local" ] && install_and_start_mongodb

    # Compare required Node version (from extracted app .env) with current system:
    # - If Node.js is NOT installed → install → logout user (restart terminal)
    # - If Node.js version mismatch → update → continue (no logout needed)
    if need_node_install "$APP_INSTALL_DIR"; then
        if ! is_node_installed; then
            # Node.js is not installed - install it and logout user
            log "⚠️  Node.js is not installed. Installing Node.js..."
            install_node "$APP_INSTALL_DIR" || {
                log "❌ Node install failed."
                rm -f "$TMP_FILE" >/dev/null 2>&1 || true
                rollback
                return 1
            }
            log "✅ Node.js installed. Logging out to restart terminal session..."
            logout_user
        else
            # Node.js is installed but wrong version - update it and continue
            log "⚠️  Node.js version mismatch. Updating Node.js..."
            install_node "$APP_INSTALL_DIR" || {
                log "❌ Node update failed."
                rm -f "$TMP_FILE" >/dev/null 2>&1 || true
                rollback
                return 1
            }
            log "✅ Node.js updated. Continuing with installation..."
        fi
    fi
    # Ensure Node.js is available (in case it was already correct version)
    install_node "$APP_INSTALL_DIR" || {
        log "❌ Node install failed."
        rm -f "$TMP_FILE" >/dev/null 2>&1 || true
        rollback
        return 1
    }

    log "✅ Using Node.js ($(node -v))"
    
    cd "$APP_INSTALL_DIR" || {
        log "❌ Failed to cd into app dir."
        rm -f "$TMP_FILE" >/dev/null 2>&1 || true
        rollback
        return 1
    }
    
    # Show files in APP_INSTALL_DIR for debugging
    log "📁 Files in $APP_INSTALL_DIR:"
    if [ -d "$APP_INSTALL_DIR" ]; then
        ls -la "$APP_INSTALL_DIR" 2>/dev/null | head -30 || true
        log "📋 Total items in directory: $(ls -1 "$APP_INSTALL_DIR" 2>/dev/null | wc -l)"
    else
        log "⚠️ Directory $APP_INSTALL_DIR does not exist"
    fi

    if ! clean_npm_install "$APP_INSTALL_DIR"; then
        log "❌ npm install failed."
        rm -f "$TMP_FILE" >/dev/null 2>&1 || true
        rollback
        return 1
    fi
    write_env_server_details
    check_pm2
    # ---------------------------------------------------
    # PM2 Restart Logic (fixed and robust)
    # ---------------------------------------------------
    log "🚀 Restarting PM2 process..."
    export PM2_HOME="$HOME/.pm2"

    # Kill all old hiretrack processes safely
    log "🗑️ Cleaning up old PM2 processes..."
    

    # Start new hiretrack process   
    pm2 start "npm run start" --name "$APP_NAME_WITH_VERSION" --cwd "$APP_INSTALL_DIR" || {
        log "❌ Failed to start. Rolling back..."
        pm2 delete "$APP_NAME_WITH_VERSION" || true
        rm -f "$TMP_FILE" >/dev/null 2>&1 || true
        rollback
        return 1
    }

    ## Migrations

    if [ "$NORMALIZED_INSTALLED" != "none" ]; then
        log "📦 Running migrations from $NORMALIZED_INSTALLED to $NORMALIZED_LATEST..."
        run_migrations "$NORMALIZED_INSTALLED" "$NORMALIZED_LATEST" || {
            log "❌ Migrations failed. Rolling back..."
            rm -f "$TMP_FILE" >/dev/null 2>&1 || true
            rollback
            return 1
        }
    fi
    
    # Clean up temp file after successful update (PM2 started and migrations completed)
    rm -f "$TMP_FILE" >/dev/null 2>&1 || true
    log "🧹 Cleaned up temporary download file"
    log "✅ Successfully installed/updated to $VERSION_NAME at $APP_INSTALL_DIR"
    write_config "installedVersion" "$VERSION_NAME"

    if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "none" ]; then
     pm2 delete "hiretrack-$INSTALLED_VERSION" || true
    fi
    pm2 save --force >/dev/null 2>&1 || true
}


# ------------------------------------------------
# Migration Functions (Fail-Safe)
# ------------------------------------------------


run_migrations() {
    set +u  # prevent unbound variable errors

    local CURRENT_VERSION="${1:-none}"
    local TARGET_VERSION="${2:-none}"

    if [ "$CURRENT_VERSION" = "none" ]; then
        echo "✅ No migrations needed for fresh install." | tee -a "$LOG_DIR/migration.log"
        return 0
    fi

    echo "📦 Fetching migrations from $CURRENT_VERSION → $TARGET_VERSION ..." | tee -a "$LOG_DIR/migration.log"

    mkdir -p "$TMP_INSTALL_DIR" "$APP_INSTALL_DIR" "$LOG_DIR" >/dev/null 2>&1 || true

    # Call migration download API with currentVersion and requiredVersion (target)
    local MIG_URL="${ASSET_MIGRATION_API}?currentVersion=$CURRENT_VERSION&requiredVersion=$TARGET_VERSION"
    MIG_URL=$(append_channel_param "$MIG_URL")
    local MIG_RESPONSE
    MIG_RESPONSE="$(curl -s "$MIG_URL" 2>/dev/null || true)"
    echo "MIG_RESPONSE: $MIG_RESPONSE" | tee -a "$LOG_DIR/migration.log"
    if [ -z "$MIG_RESPONSE" ] || ! echo "$MIG_RESPONSE" | jq . >/dev/null 2>&1; then
        echo "⚠️ Warning: Invalid or empty migration response — skipping migrations." | tee -a "$LOG_DIR/migration.log"
        return 0
    fi

    local MIG_COUNT
    MIG_COUNT=$(echo "$MIG_RESPONSE" | jq -r '.migrations | length' 2>/dev/null || echo "0")

    if [ "$MIG_COUNT" = "0" ]; then
        echo "✅ No migrations required." | tee -a "$LOG_DIR/migration.log"
        return 0
    fi

    for i in $(seq 0 $((MIG_COUNT-1))); do
        local VER FILE_NAME CONTENT_B64 CONTENT_TYPE TMP_MIG
        VER=$(echo "$MIG_RESPONSE" | jq -r ".migrations[$i].version")
        FILE_NAME=$(echo "$MIG_RESPONSE" | jq -r ".migrations[$i].fileName")
        CONTENT_B64=$(echo "$MIG_RESPONSE" | jq -r ".migrations[$i].contentBase64")
        CONTENT_TYPE=$(echo "$MIG_RESPONSE" | jq -r ".migrations[$i].contentType")

        if [ -z "$CONTENT_B64" ] || [ "$CONTENT_B64" = "null" ]; then
            echo "ℹ️ Missing content for migration $VER — skipping." | tee -a "$LOG_DIR/migration.log"
            continue
        fi

        TMP_MIG="$TMP_INSTALL_DIR/${FILE_NAME:-migration_$VER.cjs}"
        echo "$CONTENT_B64" | base64 -d > "$TMP_MIG" 2>>"$LOG_DIR/migration.log" || {
            echo "⚠️ Failed to decode migration for $VER — skipping." | tee -a "$LOG_DIR/migration.log"
            rm -f "$TMP_MIG" >/dev/null 2>&1 || true
            continue
        }

        echo "──────────────────────────────────────────────" | tee -a "$LOG_DIR/migration.log"
        echo "🆕 Preparing migration for version: $VER" | tee -a "$LOG_DIR/migration.log"
        echo "FILE     :: $TMP_MIG" | tee -a "$LOG_DIR/migration.log"
        echo "TYPE     :: ${CONTENT_TYPE:-application/octet-stream}" | tee -a "$LOG_DIR/migration.log"

        # Run migration
        (
            cd "$APP_INSTALL_DIR" 2>/dev/null || true
            [ -f ".env" ] && export $(grep -v '^#' .env | xargs) >/dev/null 2>&1
            echo "📂 Using NODE_PATH=$APP_INSTALL_DIR/node_modules" | tee -a "$LOG_DIR/migration.log"
            NODE_PATH="$APP_INSTALL_DIR/node_modules" node "$TMP_MIG" >> "$LOG_DIR/migration.log" 2>&1 || true
        )

        rm -f "$TMP_MIG" >/dev/null 2>&1 || true
        echo "✅ Migration for $VER completed (see migration.log for details)." | tee -a "$LOG_DIR/migration.log"
    done

    echo "✅ All available migrations processed (failures skipped safely)." | tee -a "$LOG_DIR/migration.log"
}



create_snapshot_script() {
    local HIRETRACK_DIR="$HOME/.hiretrack"
    local SNAPSHOT_FILE="$HIRETRACK_DIR/take-snapshot.js"

    echo "🧩 Creating take-snapshot.js in $HIRETRACK_DIR ..."

    # Ensure the .hiretrack directory exists
    mkdir -p "$HIRETRACK_DIR"

    # Write the JS backup script
    cat > "$SNAPSHOT_FILE" <<'EOF'
// take-snapshot.js
const { exec } = require('child_process');
const path = require('path');
const fs = require('fs');

// ---------------------------------------------
// 📦 MongoDB Backup Script
// ---------------------------------------------

const configPath = path.join(__dirname, 'config.json');
if (!fs.existsSync(configPath)) {
  console.error('❌ config.json not found.');
  process.exit(1);
}

const config = require(configPath);
const { dbUrl } = config;

if (!dbUrl) {
  console.error('❌ Database URL (dbUrl) missing in config.json.');
  process.exit(1);
}

const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
const dumpDir = path.join('/tmp', `mongo-dump-${timestamp}`);
const backupDir = path.join(__dirname, 'backups');
const tarFile = path.join(backupDir, `backup-${timestamp}.tar.gz`);

fs.mkdirSync(backupDir, { recursive: true });

const dumpCmd = `mongodump --uri="${dbUrl}" --out="${dumpDir}"`;
const compressCmd = `tar -czf "${tarFile}" -C "${dumpDir}" .`;
const cleanupCmd = `rm -rf "${dumpDir}"`;

console.log('🧩 Starting MongoDB backup...');
console.log(`🔗 DB URL: ${dbUrl}`);
console.log(`📁 Backup Path: ${tarFile}`);
console.log('----------------------------------');

exec(`${dumpCmd} && ${compressCmd} && ${cleanupCmd}`, (error, stdout, stderr) => {
  if (error) {
    console.error(`❌ Backup failed: ${error.message}`);
    return;
  }
  if (stderr && !stderr.includes('warning')) {
    console.error(`⚠ stderr: ${stderr}`);
  }
  console.log(`✅ Backup successful! Archive created at: ${tarFile}`);
});
EOF

    # Make it executable
    chmod +x "$SNAPSHOT_FILE"
    echo "✅ take-snapshot.js created and made executable."
}



# --------------------------------------------------
# 🧩 Backup .hiretrack (inline, no separate backup.sh script)
# --------------------------------------------------
run_backup() {
    local ROOT_DIR="$HOME"
    local MYAPP_DIR="$HOME/.hiretrack"
    local BACKUP_DIR="$ROOT_DIR/hiretrack-backup"
    local BACKUP_FILE="$BACKUP_DIR/hiretrack_backup.tar.gz"

    log_backup() {
        echo "[ $(date +"%Y-%m-%d %H:%M:%S") ] $1"
    }

    install_mongodump_backup() {
        log_backup "⚙️  Installing MongoDB Database Tools (includes mongodump)..."
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update -y
                sudo apt-get install -y mongodb-database-tools
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y mongodb-database-tools
            else
                log_backup "❌ Unsupported Linux package manager. Please install mongodump manually."
                return 1
            fi
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            if command -v brew >/dev/null 2>&1; then
                brew tap mongodb/brew
                brew install mongodb-database-tools
            else
                log_backup "❌ Homebrew not found. Please install Homebrew or install mongodump manually."
                return 1
            fi
        else
            log_backup "❌ Unsupported OS. Please install mongodump manually."
            return 1
        fi
        if ! command -v mongodump >/dev/null 2>&1; then
            log_backup "❌ Installation failed — mongodump still not found."
            return 1
        fi
        log_backup "✅ mongodump installed successfully!"
    }

    if [ ! -d "$MYAPP_DIR" ]; then
        log_backup "❌ .hiretrack directory not found at $MYAPP_DIR"
        return 1
    fi

    if ! command -v mongodump >/dev/null 2>&1; then
        log_backup "⚠️  mongodump not found. Attempting to install..."
        install_mongodump_backup || return 1
    else
        log_backup "✅ mongodump found: $(mongodump --version 2>/dev/null | head -n 1 || echo 'available')"
    fi

    log_backup "🚀 Starting backup process..."
    mkdir -p "$BACKUP_DIR"

    local SNAPSHOT_FILE="$MYAPP_DIR/take-snapshot.js"
    log_backup "🔎 Checking for take-snapshot.js in $MYAPP_DIR..."
    if [ ! -f "$SNAPSHOT_FILE" ]; then
        log_backup "❌ take-snapshot.js not found in $MYAPP_DIR"
        return 1
    fi

    pushd "$MYAPP_DIR" > /dev/null || return 1
    log_backup "▶️ Running snapshot script..."
    if ! command -v node >/dev/null 2>&1; then
        log_backup "❌ node runtime not found in PATH"
        popd > /dev/null || true
        return 1
    fi
    if ! node take-snapshot.js; then
        log_backup "❌ take-snapshot.js failed"
        popd > /dev/null || true
        return 1
    fi
    popd > /dev/null || true
    log_backup "✅ Snapshot script completed successfully"

    if [ -f "$BACKUP_FILE" ]; then
        log_backup "🗑️ Removing old backup file..."
        rm -f "$BACKUP_FILE"
    fi

    log_backup "📦 Creating backup of APP dir only (excluding node_modules)..."
    tar --exclude='APP/node_modules' -czf "$BACKUP_FILE" -C "$MYAPP_DIR" "APP" || return 1

    log_backup "✅ Backup created successfully!"
    log_backup "📁 Backup file: $BACKUP_FILE"
    log_backup "🎉 Done!"
}



# ------------------------------------------------
# Nginx Setup Script
# ------------------------------------------------
setup_nginx() {
    echo "🚀 Running Nginx setup ..."

    cat <<'NGINXEOF' | bash -s
	#!/bin/bash
	set -euo pipefail

	# ================================================
	# Nginx Setup Script for HireTrack Application
	# ================================================
	# This script must be run AFTER the main installation
	# It handles:
	# 1. Domain name collection from user
	# 2. Nginx installation
	# 3. SSL certificate setup (Let's Encrypt)
	# 4. Nginx configuration with proper proxy setup
	# 5. Include HTTPS block in configuration
	# ================================================

	echo "🚀 Starting Nginx Setup..."

	# ------------------------------------------------
	# Configuration Paths
	# ------------------------------------------------
	CONFIG_PATH="$HOME/.hiretrack/config.json"
	APP_INSTALL_DIR="$HOME/.hiretrack/APP"
	APP_PORT="${APP_PORT:-3000}"
	NGINX_BACKUP_DIR="$HOME/.hiretrack/nginx-backups"
	NGINX_CONF_DIR="/etc/nginx/sites-available"
	NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

	# Global variables
	DOMAIN_NAME=""
	EMAIL=""

	# ------------------------------------------------
	# Detect OS
	# ------------------------------------------------
	OS_TYPE=$(uname | tr '[:upper:]' '[:lower:]')
	echo "🖥️  Detected OS: $OS_TYPE"

	# ------------------------------------------------
	# Set OS-specific paths
	# ------------------------------------------------
	if [[ "$OS_TYPE" == "darwin" ]]; then
	    NGINX_CONF_DIR="/usr/local/etc/nginx/servers"
	    NGINX_ENABLED_DIR=""  # macOS doesn't use sites-enabled
	    LOG_DIR="/usr/local/var/log/nginx"
	else
	    LOG_DIR="/var/log/nginx"
	fi

	mkdir -p "$NGINX_BACKUP_DIR"
	mkdir -p "$LOG_DIR" 2>/dev/null || sudo mkdir -p "$LOG_DIR"

	# ------------------------------------------------
	# Dependency check function
	# ------------------------------------------------
	check_dep() {
	    local CMD=$1
	    if ! command -v "$CMD" >/dev/null 2>&1; then
		echo "⚠️  $CMD not found. Installing..."
		if command -v apt-get >/dev/null 2>&1; then
		    sudo apt-get update
		    sudo apt-get install -y "$CMD"
		elif command -v yum >/dev/null 2>&1; then
		    sudo yum install -y "$CMD"
		elif [[ "$OS_TYPE" == "darwin" ]] && command -v brew >/dev/null 2>&1; then
		    brew install "$CMD"
		else
		    echo "❌ Cannot install $CMD automatically. Please install it manually."
		    exit 1
		fi
	    fi
	    echo "✅ $CMD is available."
	}

	check_dep curl
	check_dep jq

	# ------------------------------------------------
	# Prompt for domain name
	# ------------------------------------------------
	prompt_for_domain() {
	    echo ""
	    echo "════════════════════════════════════════════════"
	    echo "  Domain Configuration"
	    echo "════════════════════════════════════════════════"
	    echo ""
	    echo "Please enter the domain name for your HireTrack instance."
	    echo "Examples:"
	    echo "  - release.hiretrack.in"
	    echo "  - demo.yourcompany.com"
	    echo "  - localhost (for local testing only)"
	    echo ""

	    while true; do
		read -p "🌐 Enter domain name: " DOMAIN_NAME </dev/tty

		# Trim whitespace
		DOMAIN_NAME=$(echo "$DOMAIN_NAME" | xargs)

		# Check if empty
		if [ -z "$DOMAIN_NAME" ]; then
		    echo "❌ Domain name cannot be empty. Please try again."
		    echo ""
		    continue
		fi

		# Basic domain validation
		if [[ "$DOMAIN_NAME" == "localhost" ]]; then
		    echo "⚠️  Using localhost (HTTP only, no SSL)"
		    break
		elif echo "$DOMAIN_NAME" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'; then
		    echo "✅ Domain accepted: $DOMAIN_NAME"
		    break
		else
		    echo "❌ Invalid domain format. Please use a valid domain like 'release.hiretrack.in'"
		    echo ""
		fi
	    done

	    # Confirm domain
	    echo ""
	    echo "📋 Domain Summary:"
	    echo "   Domain: $DOMAIN_NAME"
	    echo ""
	    read -p "Is this correct? (Y/n): " CONFIRM </dev/tty

	    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
		echo "❌ Aborted. Please run the script again."
		exit 1
	    fi

	    echo ""
	    echo "✅ Domain confirmed: $DOMAIN_NAME"
	}

	# ------------------------------------------------
	# Prompt for email
	# ------------------------------------------------
	prompt_for_email() {
	    # Try to get email from config first
	    if [ -f "$CONFIG_PATH" ]; then
		EMAIL=$(jq -r '.email // empty' "$CONFIG_PATH" 2>/dev/null || echo "")
	    fi

	    if [ -n "$EMAIL" ]; then
		echo "✅ Using email from config: $EMAIL"
		return
	    fi

	    echo ""
	    echo "📧 Email is required for SSL certificate registration (Let's Encrypt)"
	    echo ""

	    while true; do
		read -p "Enter your email address: " EMAIL </dev/tty

		# Trim whitespace
		EMAIL=$(echo "$EMAIL" | xargs)

		# Validate email format
		if [ -z "$EMAIL" ]; then
		    echo "❌ Email cannot be empty."
		    continue
		elif echo "$EMAIL" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then  
		    echo "✅ Email accepted: $EMAIL"
		    break
		else
		    echo "❌ Invalid email format. Please try again."
		fi
	    done
	}

	# ------------------------------------------------
	# Save domain to config
	# ------------------------------------------------
	save_domain_to_config() {
	    if [ -f "$CONFIG_PATH" ]; then
		# Update existing config
		local TEMP_FILE
		TEMP_FILE=$(mktemp)
		jq --arg domain "$DOMAIN_NAME" '.serverName=$domain' "$CONFIG_PATH" > "$TEMP_FILE"      
		mv "$TEMP_FILE" "$CONFIG_PATH"
		echo "✅ Domain saved to config: $CONFIG_PATH"
	    else
		# Create new config
		mkdir -p "$(dirname "$CONFIG_PATH")"
		echo "{\"serverName\": \"$DOMAIN_NAME\", \"email\": \"$EMAIL\"}" > "$CONFIG_PATH"       
		echo "✅ Config created with domain and email: $CONFIG_PATH"
	    fi
	}

	# ------------------------------------------------
	# Write BASE_URL and NEXT_PUBLIC_BASE_URL to .env
	# ------------------------------------------------
	write_env_server_details() {
	    local ENV_FILE="$APP_INSTALL_DIR/.env"
	    mkdir -p "$APP_INSTALL_DIR"

	    # Extract serverName from config.json
	    local SERVER_NAME
	    SERVER_NAME=$(jq -r '.serverName // empty' "$CONFIG_PATH")

	    # Handle missing server name
	    if [ -z "$SERVER_NAME" ] || [ "$SERVER_NAME" = "null" ]; then
		echo "⚠️ serverName not found in $CONFIG_PATH"
		return 0
	    fi

	    # Determine BASE_URL
	    local BASE_URL
	    if [[ "$SERVER_NAME" =~ ^(localhost|127\.0\.0\.1)$ ]]; then
		BASE_URL="http://$SERVER_NAME:3000"
	    elif [[ "$SERVER_NAME" =~ ^https?:// ]]; then
		BASE_URL="$SERVER_NAME"
	    else
		BASE_URL="https://$SERVER_NAME"
	    fi

	    # Remove existing BASE_URL/NEXT_PUBLIC_BASE_URL lines if exists
	    if [ -f "$ENV_FILE" ]; then
		grep -v "^BASE_URL=" "$ENV_FILE" | grep -v "^NEXT_PUBLIC_BASE_URL=" > "${ENV_FILE}.tmp" || true
	    else
		touch "${ENV_FILE}.tmp"
	    fi

	    # Write new BASE_URL and NEXT_PUBLIC_BASE_URL
	    echo "BASE_URL=$BASE_URL" >> "${ENV_FILE}.tmp"
	    echo "NEXT_PUBLIC_BASE_URL=$BASE_URL" >> "${ENV_FILE}.tmp"
	    mv "${ENV_FILE}.tmp" "$ENV_FILE"

	    echo "✅ BASE_URL and NEXT_PUBLIC_BASE_URL updated in $ENV_FILE ($BASE_URL)"
	}

	# ------------------------------------------------
	# Check DNS resolution
	# ------------------------------------------------
	check_dns_resolution() {
	    if [ "$DOMAIN_NAME" == "localhost" ]; then
		return 0
	    fi

	    echo ""
	    echo "🔍 Checking DNS resolution for $DOMAIN_NAME..."

	    local DNS_IP
	    DNS_IP=$(host "$DOMAIN_NAME" 2>/dev/null | grep "has address" | head -n1 | awk '{print $NF}')

	    if [ -z "$DNS_IP" ]; then
		DNS_IP=$(nslookup "$DOMAIN_NAME" 2>/dev/null | grep "Address:" | tail -n1 | awk '{print $NF}')
	    fi

	    if [ -n "$DNS_IP" ]; then
		echo "✅ Domain resolves to: $DNS_IP"

		# Get server's public IP
		local SERVER_IP
		SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "unknown")

		if [ "$SERVER_IP" != "unknown" ]; then
		    echo "   Server's public IP: $SERVER_IP"

		    if [ "$DNS_IP" == "$SERVER_IP" ]; then
			echo "   ✅ DNS points to this server!"
		    else
			echo "   ⚠️  WARNING: DNS ($DNS_IP) does not point to this server ($SERVER_IP)" 
			echo "   SSL certificate generation may fail."
			echo ""
			read -p "Continue anyway? (y/N): " CONTINUE </dev/tty
			if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
			    echo "❌ Aborted. Please update your DNS records first."
			    exit 1
			fi
		    fi
		fi
	    else
		echo "⚠️  WARNING: Cannot resolve $DOMAIN_NAME"
		echo "   Please ensure DNS is configured correctly."
		echo "   Your domain must point to this server's IP address."
		echo ""
		read -p "Continue anyway? (y/N): " CONTINUE </dev/tty
		if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
		    echo "❌ Aborted. Please configure DNS first."
		    exit 1
		fi
	    fi
	}

	# ------------------------------------------------
	# Check if application is running
	# ------------------------------------------------
	check_application() {
	    echo ""
	    echo "🔍 Checking if application is running on port $APP_PORT..."
	    if ! lsof -Pi :$APP_PORT -sTCP:LISTEN -t >/dev/null 2>&1 && ! netstat -an 2>/dev/null | grep -q ":$APP_PORT.*LISTEN"; then
		echo "⚠️  WARNING: No service detected on port $APP_PORT"
		echo "Please ensure your HireTrack application is running before continuing."
		read -p "Continue anyway? (y/N): " CONTINUE </dev/tty
		if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
		    echo "❌ Aborted. Please start your application first with:"
		    echo "   pm2 list  # Check running apps"
		    exit 1
		fi
	    else
		echo "✅ Application is running on port $APP_PORT"
	    fi
	}

	# ------------------------------------------------
	# Install Nginx
	# ------------------------------------------------
	install_nginx() {
	    if command -v nginx >/dev/null 2>&1; then
		echo "✅ Nginx already installed ($(nginx -v 2>&1 | cut -d'/' -f2))"
		return 0
	    fi

	    echo ""
	    echo "📦 Installing Nginx..."
	    if [[ "$OS_TYPE" == "linux" ]]; then
		if command -v apt-get >/dev/null 2>&1; then
		    sudo apt-get update
		    sudo apt-get install -y nginx
		elif command -v yum >/dev/null 2>&1; then
		    sudo yum install -y epel-release
		    sudo yum install -y nginx
		else
		    echo "❌ Unsupported Linux package manager. Install Nginx manually."
		    exit 1
		fi
	    elif [[ "$OS_TYPE" == "darwin" ]]; then
		if ! command -v brew >/dev/null 2>&1; then
		    echo "❌ Homebrew not found. Install Homebrew first from https://brew.sh"
		    exit 1
		fi
		brew install nginx
	    else
		echo "❌ Unsupported OS: $OS_TYPE"
		exit 1
	    fi

	    if ! command -v nginx >/dev/null 2>&1; then
		echo "❌ Nginx installation failed."
		exit 1
	    fi

	    echo "✅ Nginx installed successfully."
	}

	# ------------------------------------------------
	# Start Nginx service
	# ------------------------------------------------
	start_nginx() {
	    echo ""
	    echo "▶️  Starting Nginx service..."

	    if [[ "$OS_TYPE" == "linux" ]]; then
		sudo systemctl start nginx 2>/dev/null || true
		sudo systemctl enable nginx 2>/dev/null || true
	    elif [[ "$OS_TYPE" == "darwin" ]]; then
		# Ensure nginx.conf includes servers directory
		if ! grep -q "include.*servers/\*" /usr/local/etc/nginx/nginx.conf 2>/dev/null; then    
		    echo "📝 Configuring Nginx to include servers directory..."
		    sudo sed -i '' '/http {/a\
    include /usr/local/etc/nginx/servers/*;
' /usr/local/etc/nginx/nginx.conf 2>/dev/null || {
			echo "⚠️  Please manually add this line to /usr/local/etc/nginx/nginx.conf:"    
			echo "   include /usr/local/etc/nginx/servers/*;"
			echo "   (inside the http {} block)"
		    }
		fi
		brew services start nginx >/dev/null 2>&1
	    fi

	    sleep 2

	    if pgrep -x "nginx" >/dev/null; then
		echo "✅ Nginx is running"
	    else
		echo "❌ Nginx failed to start. Checking for errors..."
		sudo nginx -t
		exit 1
	    fi
	}

	# ------------------------------------------------
	# Setup SSL Certificate (Let's Encrypt)
	# ------------------------------------------------
	setup_ssl_certificate() {
	    local USE_HTTPS="false"
	    local CERT_PATH="/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
	    local KEY_PATH="/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem"

	    echo ""
	    echo "🔐 Setting up SSL Certificate for $DOMAIN_NAME..."

	    # Skip SSL for localhost
	    if [ "$DOMAIN_NAME" == "localhost" ]; then
		echo "⚠️  Localhost detected. Skipping SSL setup (will use HTTP only)."
		echo "false"
		return
	    fi

	    # Install certbot if not present
	    echo "📦 Installing certbot for Let's Encrypt..."
	    if ! command -v certbot >/dev/null 2>&1; then
		if command -v snap >/dev/null 2>&1; then
		    echo "Installing certbot via snap..."
		    sudo snap install --classic certbot 2>/dev/null || true
		    sudo ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
		elif command -v apt-get >/dev/null 2>&1; then
		    sudo apt-get update
		    sudo apt-get install -y certbot python3-certbot-nginx
		elif command -v yum >/dev/null 2>&1; then
		    sudo yum install -y certbot python3-certbot-nginx
		else
		    echo "❌ Cannot install certbot automatically."
		    echo "Please install certbot manually: https://certbot.eff.org/"
		    USE_HTTPS="false"
		    echo "$USE_HTTPS"
		    return
		fi
	    fi

	    if ! command -v certbot >/dev/null 2>&1; then
		echo "❌ Certbot installation failed. Using HTTP only."
		USE_HTTPS="false"
		echo "$USE_HTTPS"
		return
	    fi

	    echo "✅ Certbot is ready"

	    # Pre-flight checks
	    echo ""
	    echo "🔍 Pre-flight checks for SSL certificate..."
	    echo "   1. Domain: $DOMAIN_NAME"
	    echo "   2. Email: $EMAIL"

	    # Check port 80
	    echo "   3. Checking if port 80 is accessible..."
	    if sudo netstat -tlnp 2>/dev/null | grep -q ":80" || sudo lsof -i :80 2>/dev/null | grep -q nginx; then
		echo "   ✅ Port 80 is accessible"
	    else
		echo "   ⚠️  Port 80 may not be accessible (needed for Let's Encrypt verification)"     
	    fi

	    # Obtain or renew certificate
	    echo ""
	    echo "🔐 Obtaining/renewing Let's Encrypt certificate for $DOMAIN_NAME..."
	    echo ""
	    echo "This will:"
	    echo "  - Verify domain ownership via HTTP-01 challenge"
	    echo "  - Install certificates at /etc/letsencrypt/live/$DOMAIN_NAME/"
	    echo "  - Setup auto-renewal via certbot timer"
	    echo ""
	    read -p "Proceed with SSL certificate generation/renewal? (Y/n): " PROCEED_SSL </dev/tty

	    if [[ "$PROCEED_SSL" =~ ^[Nn]$ ]]; then
		echo "⚠️  Skipping SSL setup. Using HTTP only."
		USE_HTTPS="false"
		echo "$USE_HTTPS"
		return
	    fi

	    # Try standalone mode
	    echo "   ⏳ Obtaining certificate (this may take a moment)..."
	    if sudo certbot certonly \
		--standalone \
		--non-interactive \
		--agree-tos \
		--quiet \
		--email "$EMAIL" \
		--preferred-challenges http \
		-d "$DOMAIN_NAME" \
		--pre-hook "systemctl stop nginx 2>/dev/null || true" \
		--post-hook "systemctl start nginx 2>/dev/null || true" >/tmp/certbot_$DOMAIN_NAME.log 2>&1; then

		USE_HTTPS="true"
		echo ""
		echo "✅ Successfully obtained/renewed Let's Encrypt certificate for $DOMAIN_NAME!"     
		echo "   Certificate: $CERT_PATH"
		echo "   Private Key: $KEY_PATH"
		echo "   Auto-renewal is configured via certbot timer."
	    else
		echo ""
		echo "❌ Failed to obtain/renew Let's Encrypt certificate for $DOMAIN_NAME."
		echo ""
		echo "Common issues:"
		echo "  1. Domain '$DOMAIN_NAME' doesn't point to this server"
		echo "  2. Firewall blocking port 80/443"
		echo "  3. Another service using port 80"
		echo ""
		echo "Check logs at: /tmp/certbot_$DOMAIN_NAME.log"
		echo ""

		read -p "Proceed with HTTP only? (Y/n): " PROCEED_HTTP </dev/tty
		if [[ "$PROCEED_HTTP" =~ ^[Nn]$ ]]; then
		    echo "❌ Aborting. Please fix DNS/firewall issues and try again."
		    exit 1
		fi

		echo "⚠️  Proceeding with HTTP only for $DOMAIN_NAME."
		echo "   You can add HTTPS later with:"
		echo "   sudo certbot certonly --nginx -d $DOMAIN_NAME"
		USE_HTTPS="false"
	    fi

	    echo "$USE_HTTPS"
	}

	# ------------------------------------------------
	# Configure Nginx
	# ------------------------------------------------
	configure_nginx() {
	    local USE_HTTPS="$1"
	    local NGINX_CONF_FILE
	    local CERT_PATH="/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
	    local KEY_PATH="/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem"

	    echo ""
	    echo "📝 Configuring Nginx for $DOMAIN_NAME..."

	    # Set configuration file path
	    if [[ "$OS_TYPE" == "linux" ]]; then
		NGINX_CONF_FILE="$NGINX_CONF_DIR/$DOMAIN_NAME"
		NGINX_ENABLED_FILE="$NGINX_ENABLED_DIR/$DOMAIN_NAME"
	    elif [[ "$OS_TYPE" == "darwin" ]]; then
		NGINX_CONF_FILE="$NGINX_CONF_DIR/$DOMAIN_NAME"
		mkdir -p "$NGINX_CONF_DIR"
	    fi

	    # Backup existing configuration
	    if [ -f "$NGINX_CONF_FILE" ]; then
		local BACKUP_FILE="$NGINX_BACKUP_DIR/$DOMAIN_NAME.backup.$(date +%s)"
		cp "$NGINX_CONF_FILE" "$BACKUP_FILE"
		echo "📦 Backed up existing config to: $BACKUP_FILE"
	    fi

	    # Generate HTTP configuration
	    local NGINX_CONF_CONTENT=$(cat <<INNEREOF
# HireTrack Nginx Configuration
# Generated on: $(date)
# Domain: $DOMAIN_NAME
# Port: $APP_PORT

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;

    # Redirect HTTP to HTTPS if HTTPS is enabled
    $( [ "$USE_HTTPS" = "true" ] && echo "return 301 https://\$server_name\$request_uri;" || echo "" )

    client_max_body_size 500M;
    chunked_transfer_encoding on;

    # Buffer sizes
    proxy_buffer_size 256k;
    proxy_buffers 8 256k;
    proxy_busy_buffers_size 512k;
    large_client_header_buffers 4 16k;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    # Specific location for assets
    location /assets {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        gzip off;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    error_log $LOG_DIR/${DOMAIN_NAME}.error.log;
    access_log $LOG_DIR/${DOMAIN_NAME}.access.log;
}
INNEREOF
)

	    # Append HTTPS block if not localhost
	    if [ "$DOMAIN_NAME" != "localhost" ]; then
		NGINX_CONF_CONTENT+=$(cat <<INNEREOF

# HTTPS server block
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN_NAME;

    client_max_body_size 500M;
    chunked_transfer_encoding on;

    # SSL configuration
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=63072000; includeSubdomains; preload";

    # Buffer sizes
    proxy_buffer_size 256k;
    proxy_buffers 8 256k;
    proxy_busy_buffers_size 512k;
    large_client_header_buffers 4 16k;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    # Specific location for assets
    location /assets {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        gzip off;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    error_log $LOG_DIR/${DOMAIN_NAME}.error.log;
    access_log $LOG_DIR/${DOMAIN_NAME}.access.log;
}
INNEREOF
)
	    fi

	    # Write configuration file
	    echo "$NGINX_CONF_CONTENT" | sudo tee "$NGINX_CONF_FILE" >/dev/null
	    echo "✅ Configuration written to: $NGINX_CONF_FILE"

	    # Enable site on Linux
	    if [[ "$OS_TYPE" == "linux" ]]; then
		if [ ! -L "$NGINX_ENABLED_FILE" ]; then
		    sudo ln -sf "$NGINX_CONF_FILE" "$NGINX_ENABLED_FILE"
		    echo "✅ Site enabled at: $NGINX_ENABLED_FILE"
		fi
	    fi

	    # Test configuration
	    echo ""
	    echo "🧪 Testing Nginx configuration..."
	    if sudo nginx -t >/dev/null 2>&1; then
		echo "✅ Configuration test passed!"
	    else
		echo "❌ Configuration test failed!"
		sudo nginx -t
		echo "❌ Configuration test failed!"
		echo ""
		echo "Rolling back to previous configuration..."
		if [ -f "$NGINX_BACKUP_DIR/$DOMAIN_NAME.backup."* ]; then
		    local LATEST_BACKUP=$(ls -t "$NGINX_BACKUP_DIR"/$DOMAIN_NAME.backup.* 2>/dev/null | head -n1)
		    if [ -n "$LATEST_BACKUP" ]; then
			cp "$LATEST_BACKUP" "$NGINX_CONF_FILE"
			echo "✅ Rolled back to: $LATEST_BACKUP"
		    fi
		fi
		exit 1
	    fi

	    # Reload Nginx
	    echo ""
	    echo "🔄 Reloading Nginx..."
	    if [[ "$OS_TYPE" == "linux" ]]; then
		sudo systemctl reload nginx >/dev/null 2>&1
	    elif [[ "$OS_TYPE" == "darwin" ]]; then
		brew services restart nginx >/dev/null 2>&1
	    fi

	    sleep 2

	    if pgrep -x "nginx" >/dev/null; then
		echo "✅ Nginx reloaded successfully!"
	    else
		echo "❌ Nginx failed to reload!"
		exit 1
	    fi
	}

	# ------------------------------------------------
	# Verify setup
	# ------------------------------------------------
	verify_setup() {
	    local USE_HTTPS="$1"

	    echo ""
	    echo "🔍 Verifying setup for $DOMAIN_NAME..."

	    # Check Nginx process
	    if pgrep -x "nginx" >/dev/null; then
		echo "✅ Nginx process is running"
	    else
		echo "❌ Nginx process not found"
		return 1
	    fi

	    # Test HTTP
	    echo ""
	    echo "Testing HTTP connection to $DOMAIN_NAME..."
	    local HTTP_CODE
	    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost" -H "Host: $DOMAIN_NAME" 2>/dev/null || echo "000")

	    if [[ "$HTTP_CODE" =~ ^(200|301|302|404)$ ]]; then
		echo "✅ HTTP connection successful (Status: $HTTP_CODE)"
	    else
		echo "⚠️  HTTP connection returned status: $HTTP_CODE"
	    fi

	    # Test HTTPS if enabled
	    if [ "$USE_HTTPS" = "true" ] || [ "$DOMAIN_NAME" != "localhost" ]; then
		echo ""
		echo "Testing HTTPS connection to $DOMAIN_NAME..."
		local HTTPS_CODE
		HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN_NAME" --insecure 2>/dev/null || echo "000")

		if [[ "$HTTPS_CODE" =~ ^(200|301|302|404)$ ]]; then
		    echo "✅ HTTPS connection successful (Status: $HTTPS_CODE)"
		else
		    echo "⚠️  HTTPS connection returned status: $HTTPS_CODE"
		fi
	    fi

	    # Show log file paths
	    echo ""
	    echo "📋 Log files for $DOMAIN_NAME:"
	    echo "   - Error log:  $LOG_DIR/${DOMAIN_NAME}.error.log"
	    echo "   - Access log: $LOG_DIR/${DOMAIN_NAME}.access.log"

	    # Show recent errors if any
	    if [ -f "$LOG_DIR/${DOMAIN_NAME}.error.log" ]; then
		local ERROR_COUNT
		ERROR_COUNT=$(sudo tail -n 50 "$LOG_DIR/${DOMAIN_NAME}.error.log" 2>/dev/null | grep -c "error" || echo "0")
		if [ "$ERROR_COUNT" -gt 0 ] 2>/dev/null; then
		    echo "   ⚠️  Found $ERROR_COUNT recent errors. Check logs with:"
		    echo "      sudo tail -f $LOG_DIR/${DOMAIN_NAME}.error.log"
		fi
	    fi
	}

	# ------------------------------------------------
	# Print summary
	# ------------------------------------------------
	print_summary() {
	    local USE_HTTPS="$1"

	    echo ""
	    echo "════════════════════════════════════════════════"
	    echo "✅ Nginx Setup Complete!"
	    echo "════════════════════════════════════════════════"
	    echo ""
	    echo "📋 Configuration Summary:"
	    echo "   - Domain Name: $DOMAIN_NAME"
	    echo "   - Application Port: $APP_PORT"
	    echo "   - Protocol: $( [ "$USE_HTTPS" = "true" ] || [ "$DOMAIN_NAME" != "localhost" ] && echo "HTTP & HTTPS" || echo "HTTP only")"
	    echo ""

	    if [ "$USE_HTTPS" = "true" ] || [ "$DOMAIN_NAME" != "localhost" ]; then
		echo "🔐 SSL/TLS:"
		echo "   - Certificate: /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
		echo "   - Auto-renewal: Enabled (certbot timer)"
		echo "   - Test renewal: sudo certbot renew --dry-run"
		echo ""
	    fi

	    echo "🌐 Access your application:"
	    if [ "$USE_HTTPS" = "true" ] || [ "$DOMAIN_NAME" != "localhost" ]; then
		echo "   - https://$DOMAIN_NAME"
		echo "   - http://$DOMAIN_NAME (redirects to HTTPS)"
	    else
		echo "   - http://$DOMAIN_NAME"
	    fi
	    echo ""

	    echo "📝 Nginx Commands:"
	    if [[ "$OS_TYPE" == "linux" ]]; then
		echo "   - Test config:   sudo nginx -t"
		echo "   - Reload:        sudo systemctl reload nginx"
		echo "   - Restart:       sudo systemctl restart nginx"
		echo "   - Status:        sudo systemctl status nginx"
		echo "   - Logs:          sudo journalctl -u nginx -f"
	    elif [[ "$OS_TYPE" == "darwin" ]]; then
		echo "   - Test config:   sudo nginx -t"
		echo "   - Reload:        brew services restart nginx"
		echo "   - Status:        brew services list | grep nginx"
		echo "   - Logs:          tail -f $LOG_DIR/${DOMAIN_NAME}.error.log"
	    fi
	    echo ""

	    echo "📁 Files:"
	    echo "   - Config:  $( [ "$OS_TYPE" == "linux" ] && echo "$NGINX_CONF_DIR/$DOMAIN_NAME" || echo "$NGINX_CONF_DIR/$DOMAIN_NAME")"
	    echo "   - Backups: $NGINX_BACKUP_DIR/"
	    echo "   - Logs:    $LOG_DIR/"
	    echo ""

	    if [ "$USE_HTTPS" = "false" ] && [ "$DOMAIN_NAME" != "localhost" ]; then
		echo "🔐 To add HTTPS later:"
		echo "   1. Ensure DNS points to this server"
		echo "   2. Run: sudo certbot certonly --nginx -d $DOMAIN_NAME"
		echo "   3. Re-run this script or manually update Nginx config"
		echo ""
	    fi

	    echo ""
	    echo "════════════════════════════════════════════════"
	    echo "  🎯 REGISTRATION URL"
	    echo "════════════════════════════════════════════════"
	    echo ""
	    echo "You can register the first organization from the URL below:"
	    echo ""
	    echo "   ╔══════════════════════════════════════════════════════════╗"
	    echo "   ║                                                          ║"
	    printf "   ║ %-56s ║\n" "https://$DOMAIN_NAME/register/org"
	    echo "   ║                                                          ║"
	    echo "   ╚══════════════════════════════════════════════════════════╝"
	    echo ""
	    echo "════════════════════════════════════════════════"
	}

	# ------------------------------------------------
	# Cleanup function for errors
	# ------------------------------------------------
	cleanup_on_error() {
	    echo ""
	    echo "❌ Setup failed. Cleaning up..."

	    # Restore backup if exists
	    if [ -f "$NGINX_BACKUP_DIR/$DOMAIN_NAME.backup."* ]; then
		local LATEST_BACKUP=$(ls -t "$NGINX_BACKUP_DIR"/$DOMAIN_NAME.backup.* 2>/dev/null | head -n1)
		if [ -n "$LATEST_BACKUP" ]; then
		    echo "🔄 Restoring previous configuration..."
		    cp "$LATEST_BACKUP" "$NGINX_CONF_DIR/$DOMAIN_NAME" 2>/dev/null || true
		    sudo nginx -t && sudo systemctl reload nginx 2>/dev/null || brew services restart nginx 2>/dev/null
		fi
	    fi

	    echo "Please check the error messages above and try again."
	    exit 1
	}

	trap cleanup_on_error ERR

	# ------------------------------------------------
	# Main execution flow
	# ------------------------------------------------
	main() {
	    echo "════════════════════════════════════════════════"
	    echo "  HireTrack Nginx Setup Script"
	    echo "════════════════════════════════════════════════"
	    echo ""

	    # Step 1: Prompt for domain name
	    prompt_for_domain

	    # Step 2: Prompt for email
	    prompt_for_email

	    # Step 3: Save domain and email to config
	    save_domain_to_config

	    # Step 3.1: Write BASE_URL values to .env
	    write_env_server_details

	    # Step 4: Check DNS resolution
	    check_dns_resolution

	    # Step 5: Check if application is running
	    check_application

	    # Step 6: Install Nginx
	    install_nginx

	    # Step 7: Start Nginx
	    start_nginx

	    # Step 8: Setup SSL
	    local USE_HTTPS
	    USE_HTTPS=$(setup_ssl_certificate)

	    # Step 9: Configure Nginx with HTTP and HTTPS (if not localhost)
	    configure_nginx "$USE_HTTPS"

	    # Step 10: Verify setup
	    verify_setup "$USE_HTTPS"

	    # Step 11: Print summary
	    print_summary "$USE_HTTPS"
	}

	# Run main function
	main
NGINXEOF
    local NGINX_EXIT=$?
    if [ "$NGINX_EXIT" -ne 0 ]; then
        echo "❌ Nginx setup failed. Check logs and try setting up the domain again by using the --domain command."
        exit 1
    fi
    echo "✅ Nginx setup completed."
}

# ------------------------------------------------
# Restart PM2 Service
# ------------------------------------------------
restart_pm2_service() {
    local MATCHING_PROCS
    local ECOSYSTEM_FILE=""

    echo "🔍 Checking for existing hiretrack-* PM2 processes..."

    # Capture all running hiretrack-* processes (if any)
    MATCHING_PROCS=$(pm2 list 2>/dev/null | awk '/hiretrack-/ {print $4}' | tr -d '│')

    if [ -n "$MATCHING_PROCS" ]; then
        echo "♻️  Found running hiretrack processes:"
        echo "$MATCHING_PROCS" | sed 's/^/   • /'
        echo "🔄 Restarting all matching PM2 processes..."

        echo "$MATCHING_PROCS" | while read -r PROC; do
            [ -n "$PROC" ] && pm2 restart "$PROC" --update-env || echo "⚠️ Failed to restart $PROC"
        done
    else
        echo "⚠️  No hiretrack-* process found. Starting ecosystem..."

        if [ -d "$APP_INSTALL_DIR" ]; then
            cd "$APP_INSTALL_DIR" || { echo "❌ Failed to enter $APP_INSTALL_DIR"; return 1; }

            # Check for ecosystem.config.cjs or ecosystem.config.js
            if [ -f "ecosystem.config.cjs" ]; then
                ECOSYSTEM_FILE="ecosystem.config.cjs"
            elif [ -f "ecosystem.config.js" ]; then
                ECOSYSTEM_FILE="ecosystem.config.js"
            else
                echo "❌ No ecosystem file found in $APP_INSTALL_DIR"
                return 1
            fi

            pm2 start "$ECOSYSTEM_FILE" && echo "✅ PM2 started successfully using $ECOSYSTEM_FILE."
        else
            echo "❌ Directory $APP_INSTALL_DIR not found"
            return 1
        fi
    fi
}

# ------------------------------------------------
# Cron Setup
# ------------------------------------------------
setup_cron() {
    local OS_TYPE=$(uname | tr '[:upper:]' '[:lower:]')
    local CRON_NAME="hiretrack-autoupdate"
    local SNAPSHOT_CRON_NAME="hiretrack-snapshot"
    local CRON_ENTRY="0 2 * * * PATH=/usr/local/bin:/usr/bin:/bin $SCRIPT_PATH --update >> $CRON_LOG_FILE 2>&1"
    local SNAPSHOT_CRON_ENTRY="0 2 * * * PATH=/usr/local/bin:/usr/bin:/bin node $SNAPSHOT_SCRIPT >> $SNAPSHOT_LOG_FILE 2>&1"

    if [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "darwin" ]]; then
        local CURRENT_CRON=$(crontab -l 2>/dev/null || echo "")

        # ------------------------------------------------
        # 🧩 Auto-update Cron (every day at 2 AM)
        # ------------------------------------------------
        if ! echo "$CURRENT_CRON" | grep -Fq "$CRON_ENTRY"; then
            (echo "$CURRENT_CRON"; echo "# CRON_NAME:$CRON_NAME"; echo "$CRON_ENTRY") | crontab -
            echo "✅ Cron job '$CRON_NAME' added. Logs: $CRON_LOG_FILE"
            # Re-read crontab to include the newly added job
            CURRENT_CRON=$(crontab -l 2>/dev/null || echo "")
        else
            echo "✅ Cron job '$CRON_NAME' already exists. Logs: $CRON_LOG_FILE"
        fi

        # ------------------------------------------------
        # 🧩 Snapshot Cron (every day at 2 AM)
        # ------------------------------------------------
        if [ -f "$SNAPSHOT_SCRIPT" ]; then
            if ! echo "$CURRENT_CRON" | grep -Fq "$SNAPSHOT_CRON_ENTRY"; then
                (echo "$CURRENT_CRON"; echo "# CRON_NAME:$SNAPSHOT_CRON_NAME"; echo "$SNAPSHOT_CRON_ENTRY") | crontab -
                echo "✅ Cron job '$SNAPSHOT_CRON_NAME' added. Logs: $SNAPSHOT_LOG_FILE"
            else
                echo "✅ Cron job '$SNAPSHOT_CRON_NAME' already exists. Logs: $SNAPSHOT_LOG_FILE"
            fi
        else
            echo "⚠️ Snapshot script not found at $SNAPSHOT_SCRIPT. Skipping snapshot cron setup."
        fi

    else
        echo "❌ Unsupported OS: $OS_TYPE. Cannot setup cron."
    fi
}

# ------------------------------------------------
# Full Installation
# ------------------------------------------------
install_all() {
    local EMAIL="$1"
    [ -z "$EMAIL" ] && EMAIL=$(prompt_for_email)
    echo "==== Starting installation for $EMAIL ===="

    create_default_config "$EMAIL"
    [ ! -f "$LICENSE_PATH" ] && register_license "$EMAIL"
    create_snapshot_script
    check_update_and_install
    setup_cron
    setup_nginx
    write_env_server_details
    restart_pm2_service
    echo "==== Installation complete! ===="
    exit 0
}

# ------------------------------------------------
# Help (no dependency checks when showing help)
# ------------------------------------------------
show_help() {
    echo "Usage:"
    echo "  $0 [command] [options]"
    echo
    echo "Commands:"
    echo "  --update [mode]               Check for and install updates"
    echo "                                Use 'manually' to skip auto-update validation check"
    echo "                                Example: $0 --update manually"
    echo
    echo "  --run-migrations [from] [to]  Run database migrations between versions"
    echo "                                Example: $0 --run-migrations 2.2.25 2.2.26"
    echo
    echo "  --rollback                    Roll back to previous version (from config.json)"
    echo "                                Example: $0 --rollback"
    echo
    echo "  --setup-cron                  Set up automatic update cron job"
    echo "                                Configures cron to check for updates automatically"
    echo
    echo "  --domain                      Configure domain and Nginx setup"
    echo "                                Sets up domain, SSL certificate, and Nginx reverse proxy"
    echo
    echo "  --backup                      Create backup of .hiretrack (excludes node_modules)"
    echo "                                Example: $0 --backup"
    echo
    echo "  --update-license [email]      Update the license key manually"
    echo "                                Only changes the machine code, email remains unchanged"
    echo "                                Example: $0 --update-license user@example.com"
    echo
    echo "  --register [email]           Register a new license key"
    echo "                                Example: $0 --register user@example.com"
    echo
    echo "  --beta-on                     Use beta repository (same as --channel beta)"
    echo "  --beta-off                    Use production repository (same as --channel production)"
    echo "  --staging-on                  Use staging repository"
    echo "  --staging-off                 Use production repository"
    echo
    echo "  --help                        Show this help message and exit"
    echo
}

# ------------------------------------------------
# Main Entry Point
# ------------------------------------------------
# If --help or -h, show help and exit without running dependency checks
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

check_dep curl
check_dep jq
check_dep tar
check_dep shasum
check_pm2

# Initialize channel (production / beta / staging) from config.json (with command line override)
init_channel_mode "$@"

case "${1:-}" in
    --install)
        install_all "${2:-}"
        ;;
    --register)
        register_license "${2:-}"
        ;;
    --update)
	    check_update_and_install "${2:-}" 
       	;;
    --run-migrations)
        run_migrations "${2:-}" "${3:-}"
        ;;
    --rollback)
        # Version is automatically detected from config.json (previousVersion)
        rollback
        ;;
    --setup-cron)
        setup_cron
        ;;
    --domain)
        setup_nginx
        ;;
    --backup)
        run_backup
        ;;
    --update-license)
        update_license "${2:-}"
        ;;
    --beta-on)
        set_channel_config "beta"
        ;;
    --beta-off)
        set_channel_config "production"
        ;;
    --staging-on)
        set_channel_config "staging"
        ;;
    --staging-off)
        set_channel_config "production"
        ;;
    --help)
        show_help
        exit 0
        ;;
    -h)
        show_help
        exit 0
        ;;
    *)
        install_all "${2:-}"
        ;;
esac
