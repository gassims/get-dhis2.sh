#!/bin/bash

# --- Configuration Variables ---
DEFAULT_DHIS2_IMAGE="dhis2/core-dev:latest"
DEFAULT_DB_DUMP_URL="https://databases.dhis2.org/sierra-leone/dev/dhis2-db-sierra-leone.sql.gz"
DEFAULT_DHIS2_HOST_PORT="8080"
DEFAULT_DEBUG_HOST_PORT="8081"
DEFAULT_JMX_HOST_PORT="9011"
DEFAULT_PG_HOST_PORT="5432"
DHIS2_COMPOSE_URL="https://raw.githubusercontent.com/dhis2/dhis2-core/master/docker-compose.yml" 


# --- Script Configuration ---
set -e # Exit immediately if a command exits with a non-zero status.

# --- Functions ---

# Function for pretty printing messages
pretty_echo() {
    echo -e "\n=============================================="
    echo -e "$1"
    echo -e "==============================================\n"
}

# Function for error messages and exiting
error_exit() {
    pretty_echo "ERROR: $1" >&2
    exit 1
}

# Function to check if a regular command exists and is executable for the current user
check_command() {
    command -v "$1" >/dev/null 2>&1
    return $?
}

# Function to check if a port is in use (needs sudo for comprehensive check)
is_port_in_use() {
    local port=$1
    echo "DEBUG: Checking if port $port is in use (via WSL2 and Windows)..." >&2

    # 1. Check with netstat for general system usage within WSL2.
    # This detects processes listening directly within the WSL2 environment.
    if sudo netstat -tuln | grep -q ":$1\>"; then
        echo "DEBUG: Port $port IS in use by another process within WSL2." >&2
        return 0 # Port is in use
    fi

    # 2. Check for port usage on the Windows host using netstat.exe.
    # This is the most definitive check for conflicts on the underlying Windows OS.
    if command -v netstat.exe >/dev/null 2>&1; then # Check if netstat.exe is in PATH
        if netstat.exe -ano | grep -q ":$port\b.*LISTENING"; then
            echo "DEBUG: Port $port IS in use by a Windows process." >&2
            return 0 # Port is in use
        else
            echo "DEBUG: Port $port IS NOT in use by a Windows process." >&2
            # If netstat.exe didn't find it, and WSL2 netstat didn't find it,
            # then the port truly appears free.
            return 1 # Port is not in use
        fi
    else
        echo "DEBUG: netstat.exe not found in WSL2 PATH. Skipping Windows host port check. You will need to make sure the port is not being used in your Windows (run: cmd /c \"netstat -ano | findstr \"&{port}\" && pause\") " >&2
        # If netstat.exe isn't found, we rely only on the WSL2 netstat check.
        # Since that check already happened and passed (or we would have returned 0),
        # we conclude the port is free based on available checks.
        return 1
    fi
}

# Function to find an available port, starting from a given default
find_available_port() {
    local desired_port=$1
    local current_port=$desired_port
    while is_port_in_use "$current_port"; do
        current_port=$((current_port + 1))
        # Add a safeguard to prevent infinite loops if many ports are in use or system issues
        if [ "$current_port" -gt 65535 ]; then
            error_exit "Could not find an available port starting from $desired_port up to 65535."
        fi
    done
    echo "$current_port" # This is the only line that should go to stdout
}

# Helper function to get and validate a user-selected port
# Arguments: $1=port_description (e.g., "DHIS2 web UI"), $2=default_start_port (e.g., 8080)
get_user_port() {
    local port_description="$1"
    local default_start_port="$2"
    local selected_port=""
    local proposed_port=""
    local user_input=""

    # Find an initially proposed available port based on the default
    proposed_port=$(find_available_port "$default_start_port")

    while true; do
        if [ "$proposed_port" -ne "$default_start_port" ]; then
            # Default port is in use, propose the next available one
            read -p "$port_description: Default port $default_start_port is IN USE. Recommended port is $proposed_port. Enter a new port (or press Enter to use $proposed_port): " user_input
        else
            # Default port is available
            read -p "$port_description will be accessible on port $default_start_port. Enter a new port (or press Enter to use $default_start_port): " user_input
        fi

        if [ -z "$user_input" ]; then
            # User pressed Enter, accept the proposed/default port
            selected_port="$proposed_port"
            break
        elif [[ "$user_input" =~ ^[0-9]+$ ]] && [ "$user_input" -ge 1024 ] && [ "$user_input" -le 65535 ]; then
            # User entered a number, validate it
            if is_port_in_use "$user_input"; then
                # Diagnostic messages to stderr
                echo "Port $user_input is already in use. Please choose a different one." >&2 
            else
                selected_port="$user_input"
                break
            fi
        else
            # Invalid input (not a number or out of range)
            echo "Invalid input. Please enter a valid port number (1024-65535) or press Enter." >&2
        fi
    done

    echo "$selected_port" # Return the validated port (only this should go to stdout)
}

# --- Script Start ---

pretty_echo "DHIS2 Docker Instance Setup Script for WSL2 Ubuntu"

# --- 1. System Update ---
pretty_echo "Updating system packages..."
sudo apt update || error_exit "Failed to update apt packages."
sudo apt upgrade -y || error_exit "Failed to upgrade apt packages."

# --- 2. Docker Desktop Integration Check ---
# This section replaces the manual Docker Engine/Compose installation and daemon management.
pretty_echo "Verifying Docker Desktop integration for WSL2..."

if command -v docker &> /dev/null; then
    echo "Docker command found in WSL2. Verifying Docker Desktop connectivity..."
    if ! docker info >/dev/null 2>&1; then
        error_exit "Docker command exists but cannot connect to Docker daemon. Ensure Docker Desktop is running on Windows and WSL2 integration is enabled for this distribution. After enabling/starting, you might need to run 'wsl --shutdown' from Windows PowerShell/CMD and reopen this terminal."
    fi
    echo "Docker Desktop is running and integrated with WSL2."
else
    error_exit "Docker command not found in WSL2. Please install Docker Desktop for Windows from https://www.docker.com/products/docker-desktop/ and ensure WSL2 integration is enabled for your Ubuntu distribution. Then, run 'wsl --shutdown' from Windows PowerShell/CMD and reopen this terminal."
fi

# Ensure docker compose command is available (it's part of Docker Desktop)
if ! command -v docker compose &> /dev/null; then
    error_exit "Docker Compose command not found. This should be provided by Docker Desktop. Please check your Docker Desktop installation."
fi

# --- 3. Set Docker Context (CRUCIAL for WSL2 with Docker Desktop) ---
pretty_echo "Setting Docker context to 'default' for WSL2 compatibility..."
# The 'default' context usually points to the Unix socket for WSL2.
docker context use default || error_exit "Failed to switch Docker context to 'default'. This is crucial for Docker Desktop integration with WSL2."
docker context ls
echo "Docker context set to 'default'."

# Check for curl, needed for downloading docker-compose.yml
if ! check_command curl; then
    pretty_echo "curl is not found. Installing curl..."
    sudo apt-get install -y curl || error_exit "Failed to install curl."
else
    pretty_echo "curl is already installed."
fi

pretty_echo "All required tools (Docker Desktop, Docker Compose, curl) are installed and ready."

# --- 4. Gather User Input ---

pretty_echo "Setting up your DHIS2 instance"

read -p "Enter a name for your DHIS2 project (this will be a subdirectory within the current script's location, e.g., my-dhis2-instance): " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then
    error_exit "Project name cannot be empty."
fi

# Define the project directory based on the script's execution location
# This gets the directory where the script is run
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DHIS2_PROJECT_DIR="$SCRIPT_DIR/$PROJECT_NAME"

# --- NEW CONFIRMATION STEP ---
pretty_echo "Your DHIS2 project '$PROJECT_NAME' will be created at: $DHIS2_PROJECT_DIR"
echo "Please ensure this is the desired location."
read -p "Does this look correct? (y/N): " confirm_dir
if [[ ! "$confirm_dir" =~ ^[Yy]$ ]]; then
    error_exit "Operation cancelled by user. Please re-run the script from the desired parent directory."
fi
# --- END NEW CONFIRMATION STEP ---


read -p "Enter the DHIS2 Docker image to use (e.g., dhis2/core:2.41, dhis2/core-dev:latest). Default is '$DEFAULT_DHIS2_IMAGE': " USER_DHIS2_IMAGE
DHIS2_IMAGE="${USER_DHIS2_IMAGE:-$DEFAULT_DHIS2_IMAGE}"

# --- Port Configuration ---
pretty_echo "Configuring network ports for your DHIS2 instance..."

DHIS2_HOST_PORT=$(get_user_port "DHIS2 web UI" "$DEFAULT_DHIS2_HOST_PORT")
DEBUG_HOST_PORT=$(get_user_port "Java debugger" "$DEFAULT_DEBUG_HOST_PORT")
JMX_HOST_PORT=$(get_user_port "JMX monitoring" "$DEFAULT_JMX_HOST_PORT")
PG_HOST_PORT=$(get_user_port "PostgreSQL database" "$DEFAULT_PG_HOST_PORT")
#
#
#(Deprecated) Prompt for encryption password
#(Deprecated) read -s -p "Enter a strong, unique encryption password for DHIS2 (required for dhis.conf): " ENCRYPTION_PASSWORD
#(Deprecated) echo "" # Newline after password input
#(Deprecated) if [ -z "$ENCRYPTION_PASSWORD" ]; then
#(Deprecated)     error_exit "Encryption password cannot be empty."
#(Deprecated) fi


# --- 5. Create Project Directory and Files ---

pretty_echo "Creating project directory and files in $DHIS2_PROJECT_DIR..."
mkdir -p "$DHIS2_PROJECT_DIR/docker" || error_exit "Failed to create project directory structure."
cd "$DHIS2_PROJECT_DIR" || error_exit "Failed to change to project directory."

# Create .env file
cat << EOF > .env
DHIS2_IMAGE=${DHIS2_IMAGE}
DHIS2_DB_DUMP_URL=${DEFAULT_DB_DUMP_URL} # Can be changed later if needed
EOF
echo "Created .env file."

# Create dhis.conf
cat << EOF > docker/dhis.conf
# Hibernate SQL dialect
connection.dialect = org.hibernate.dialect.PostgreSQLDialect
# JDBC driver class
connection.driver_class = org.postgresql.Driver
# JDBC driver connection URL.
connection.url = jdbc:postgresql://db:5432/dhis
# Database username
connection.username = dhis
# Database password
connection.password = dhis
# Database schema behavior
connection.schema = update
#(Deprecated) # Encryption password (CRITICAL: MUST BE UNIQUE AND STRONG)
#(Deprecated) encryption.password = ${ENCRYPTION_PASSWORD}
EOF
echo "Created docker/dhis.conf."

# Create log4j2.xml (simple version)
cat << EOF > docker/log4j2.xml
<?xml version="1.0" encoding="UTF-8"?>
<Configuration status="INFO">
    <Appenders>
        <Console name="Console" target="SYSTEM_OUT">
            <PatternLayout pattern="%d{yyyy-MM-dd HH:mm:ss.SSS} %-5level %logger{36} - %msg%n"/>
        </Console>
    </Appenders>
    <Loggers>
        <Root level="INFO">
            <AppenderRef ref="Console"/>
        </Root>
    </Loggers>
</Configuration>
EOF
echo "Created docker/log4j2.xml."

# Download and modify docker-compose.yml
pretty_echo "Downloading official docker-compose.yml from DHIS2 Core GitHub repository and customizing it..."

MAX_RETRIES=5
RETRY_COUNT=0
DOWNLOAD_SUCCESS=false

while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
    echo "Attempting to download docker-compose.yml (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
    if curl -sL "$DHIS2_COMPOSE_URL" -o docker-compose.yml; then
        DOWNLOAD_SUCCESS=true
        echo "Download successful!"
        break
    else
        echo "Download failed. Retrying in 5 seconds..."
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 5
    fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    error_exit "Failed to download docker-compose.yml from GitHub after $MAX_RETRIES attempts. Please check your internet connection or the URL: $DHIS2_COMPOSE_URL"
fi

# Perform substitutions for project-specific values, ports, and healthcheck parameters
sed -i \
    -e "s|dhis2-db-data:|${PROJECT_NAME}-db-data:|g" \
    -e "s|db-dump:|${PROJECT_NAME}-db-dump:|g" \
    -e "s|- \"127.0.0.1:8080:8080\"|- \"127.0.0.1:${DHIS2_HOST_PORT}:8080\"|g" \
    -e "s|- \"127.0.0.1:8081:8081\"|- \"127.0.0.1:${DEBUG_HOST_PORT}:8081\"|g" \
    -e "s|- \"127.0.0.1:9011:9011\"|- \"127.0.0.1:${JMX_HOST_PORT}:9011\"|g" \
    -e "s|- \"127.0.0.1:5432:5432\"|- \"127.0.0.1:${PG_HOST_PORT}:5432\"|g" \
    -e "/^x-db-base:/,/^services:/ {
        s/^[[:space:]]*start_period:.*$/    start_period: 600s/
        s/^[[:space:]]*interval:.*$/    interval: 10s/
        s/^[[:space:]]*timeout:.*$/    timeout: 5s/
        s/^[[:space:]]*retries:.*$/    retries: 50/
    }" \
    docker-compose.yml || error_exit "Failed to modify docker-compose.yml."

echo "Modified docker-compose.yml with custom ports, volume names, DHIS2_IMAGE reference, and DB healthcheck."

pretty_echo "All files generated successfully for project '$PROJECT_NAME'."

# --- 6. Start DHIS2 Instance ---

pretty_echo "Starting your DHIS2 instance..."
echo "This may take several minutes, especially on the first run (downloading DB dump, initializing database, starting DHIS2 application)."

# This `docker compose up -d` command is correct for starting services with Docker Desktop.
docker compose up -d || error_exit "Failed to start Docker Compose services using 'docker compose up -d'. Please check 'docker compose logs -f' for details. Make sure Docker Desktop integration with WSL2 is running properly."

# Increased sleep duration
sleep 15 # Giving enough time for containers to likely start before attaching logs.

# --- Automatic Log Monitoring ---
pretty_echo "Monitoring DHIS2 startup logs..."
echo "Waiting for DHIS2 application to start up (this may take a few minutes)..."
echo "You will see output from 'db' (database initialization) and 'web' (DHIS2 application startup)."
echo "The script will automatically continue once 'Server startup in [XXXXX] milliseconds' is detected."
echo "If you need to stop watching logs manually, you can press Ctrl+C, but the script will then exit."
echo ""
# Navigate to project directory before running logs, just to be safe
# Using the subshell execution for robustness.
(cd "$DHIS2_PROJECT_DIR" && \
  timeout 30m docker compose logs -f web 2>&1 | while IFS= read -r line; do
    echo "$line"
    if [[ "$line" =~ "Server startup in " && "$line" =~ "milliseconds" ]]; then
      echo "DHIS2 Web application startup detected!"
      kill "$(pgrep -f "docker compose logs -f web")" 2>/dev/null || true
      break
    fi
  done
) || {
    echo "WARNING: DHIS2 Web application startup not detected within 30 minutes. Please check logs manually for errors:" >&2
    echo "  cd ${DHIS2_PROJECT_DIR} && docker compose logs" >&2
    # Do NOT exit the script here with error_exit, allow post-setup info to be displayed.
}

# Add a small delay to ensure processes are properly shut down after pkill
sleep 5


# --- 7. Post-Setup Information ---

pretty_echo "DHIS2 Instance Setup Complete (or in progress)! Please check logs for final status."

echo "Project Name: '$PROJECT_NAME'"
echo "Project Directory: '$DHIS2_PROJECT_DIR'"
echo "DHIS2 Docker Image: '${DHIS2_IMAGE}'"
echo ""
echo "To monitor the startup process (recommended):"
echo "    cd ${DHIS2_PROJECT_DIR}"
echo "    docker compose logs -f"
echo ""
echo "Once 'Server startup in [XXXXX] milliseconds' appears in the logs,"
echo "you can access DHIS2 at:"
echo "    http://localhost:${DHIS2_HOST_PORT}"
echo ""
echo "Default Login Credentials (for Sierra Leone Demo Database):"
echo "    Username: admin"
echo "    Password: district"
echo ""
echo "--- Management Commands ---"
echo "To stop this instance:"
echo "    cd ${DHIS2_PROJECT_DIR} && docker compose stop"
echo "To restart this instance:"
echo "    cd ${DHIS2_PROJECT_DIR} && docker compose restart"
echo "To stop and remove containers (but keep data volumes):"
echo "    cd ${DHIS2_PROJECT_DIR} && docker compose down"
echo "To stop and remove containers AND delete ALL data (for a fresh start):"
echo "    cd ${DHIS2_PROJECT_DIR} && docker compose down -v"
echo ""
echo "--- Finding Your Instances (If You Forget) ---"
echo "To list all running DHIS2 Docker Compose projects and their ports:"
echo '    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}"'
echo ""
echo "To find the directory of a specific project (e.g., 'dhis2-myproject'):"
echo "    Look in the directory where you ran this setup script for a subdirectory named after your project."
echo "    Alternatively, use 'docker ps ...' to find a container name like 'dhis2-myproject-web-1'."
echo "    Then, run: docker inspect dhis2-myproject-web-1 --format '{{ index .Config.Labels \"com.docker.compose.project.working_dir\" }}'"
echo ""
pretty_echo "Script Finished."