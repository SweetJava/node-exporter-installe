#!/usr/bin/env bash

set -uo pipefail

VERSION="1.12.1"
PORT="9100"
INSTALL_PATH="/usr/local/bin/node_exporter"
SERVICE_NAME_NEW="node_exporter.service"

echo "=========================================="
echo " Node Exporter Installer"
echo " Version: ${VERSION}"
echo " Port: ${PORT}"
echo "=========================================="
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run this script as root."
    exit 1
fi


# ============================================================
# Interactive input
# Works even when executed via:
# curl ... | sudo bash
# ============================================================

ask_yes_no() {
    local prompt="$1"
    local answer=""

    if [ ! -e /dev/tty ]; then
        echo "ERROR: Interactive terminal not available."
        return 1
    fi

    while true; do
        printf "%s [y/N]: " "$prompt" >/dev/tty

        if ! IFS= read -r answer </dev/tty; then
            return 1
        fi

        case "${answer:-N}" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No|"")
                return 1
                ;;
            *)
                echo "Please enter y or n." >/dev/tty
                ;;
        esac
    done
}


# ============================================================
# Port helpers
# ============================================================

port_is_busy() {
    ss -lntp 2>/dev/null | grep -qE ":${PORT}[[:space:]]"
}

get_port_pid() {
    ss -lntp 2>/dev/null \
        | grep -E ":${PORT}[[:space:]]" \
        | grep -oE 'pid=[0-9]+' \
        | head -n1 \
        | cut -d= -f2
}


# ============================================================
# Detect Node Exporter already installed by this script
# ============================================================

check_existing_native_node_exporter() {

    if [ ! -x "$INSTALL_PATH" ]; then
        return 1
    fi

    CURRENT_VERSION="$(
        "$INSTALL_PATH" --version 2>&1 \
        | head -n1 \
        | sed -n 's/.*version \([^ ]*\).*/\1/p'
    )"

    if [ -z "$CURRENT_VERSION" ]; then
        return 1
    fi

    echo "Existing native Node Exporter detected:"
    echo
    echo "  Binary : $INSTALL_PATH"
    echo "  Version: $CURRENT_VERSION"
    echo

    if [ "$CURRENT_VERSION" = "$VERSION" ]; then

        if systemctl is-active --quiet "$SERVICE_NAME_NEW" 2>/dev/null; then
            echo "Node Exporter ${VERSION} is already installed and running."

            if curl -fsS \
                "http://127.0.0.1:${PORT}/metrics" \
                >/dev/null 2>&1; then

                echo "Metrics endpoint: OK"
            fi

            exit 0
        fi
    fi

    return 0
}


# ============================================================
# Docker detection
# ============================================================

find_docker_container_on_port() {

    DOCKER_CONTAINER_ID=""
    DOCKER_CONTAINER_NAME=""
    DOCKER_CONTAINER_IMAGE=""
    DOCKER_CONTAINER_PORTS=""

    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    while IFS='|' read -r cid cname cimage cports; do

        if echo "$cports" | grep -qE \
            "(^|, )[0-9.:]*:${PORT}->${PORT}/tcp"; then

            DOCKER_CONTAINER_ID="$cid"
            DOCKER_CONTAINER_NAME="$cname"
            DOCKER_CONTAINER_IMAGE="$cimage"
            DOCKER_CONTAINER_PORTS="$cports"

            return 0
        fi

    done < <(
        docker ps \
            --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Ports}}' \
            2>/dev/null
    )

    return 1
}


handle_docker_conflict() {

    echo
    echo "=========================================="
    echo " Docker container detected"
    echo "=========================================="
    echo

    echo "Container ID:"
    echo "  $DOCKER_CONTAINER_ID"

    echo
    echo "Container name:"
    echo "  $DOCKER_CONTAINER_NAME"

    echo
    echo "Image:"
    echo "  $DOCKER_CONTAINER_IMAGE"

    echo
    echo "Port mapping:"
    echo "  $DOCKER_CONTAINER_PORTS"

    echo

    # Show whether Docker Compose manages it
    COMPOSE_PROJECT="$(
        docker inspect \
            -f '{{index .Config.Labels "com.docker.compose.project"}}' \
            "$DOCKER_CONTAINER_ID" \
            2>/dev/null || true
    )"

    COMPOSE_SERVICE="$(
        docker inspect \
            -f '{{index .Config.Labels "com.docker.compose.service"}}' \
            "$DOCKER_CONTAINER_ID" \
            2>/dev/null || true
    )"

    if [ -n "$COMPOSE_PROJECT" ] &&
       [ "$COMPOSE_PROJECT" != "<no value>" ]; then

        echo "Docker Compose project:"
        echo "  $COMPOSE_PROJECT"
    fi

    if [ -n "$COMPOSE_SERVICE" ] &&
       [ "$COMPOSE_SERVICE" != "<no value>" ]; then

        echo "Docker Compose service:"
        echo "  $COMPOSE_SERVICE"
    fi

    echo

    if echo "$DOCKER_CONTAINER_NAME" | grep -qi "1panel"; then
        echo "WARNING:"
        echo "This container appears to be managed by 1Panel."
        echo
        echo "Removing the Docker container does NOT necessarily"
        echo "remove the application from 1Panel."
        echo
        echo "1Panel may recreate it later."
        echo
    fi

    if ! ask_yes_no \
        "Do you want to stop this Docker container?"; then

        echo
        echo "Installation cancelled."
        exit 1
    fi

    echo
    echo "Stopping container..."

    docker stop "$DOCKER_CONTAINER_ID"

    sleep 1

    if port_is_busy; then
        echo
        echo "WARNING: TCP ${PORT} is still occupied after stopping container."
    else
        echo
        echo "TCP ${PORT} released."
    fi

    echo

    if ask_yes_no \
        "Do you want to remove this Docker container?"; then

        docker rm "$DOCKER_CONTAINER_ID"

        echo
        echo "Docker container removed."

        if echo "$DOCKER_CONTAINER_NAME" | grep -qi "1panel"; then
            echo
            echo "IMPORTANT:"
            echo "The container belonged to 1Panel."
            echo "You should also remove/disable the old Node Exporter"
            echo "application inside the 1Panel App Store."
        fi

    else

        echo
        echo "Container stopped but NOT removed."
        echo
        echo "WARNING:"
        echo "It may start again after reboot or by Docker/1Panel."
    fi
}


# ============================================================
# Normal process conflict
# ============================================================

handle_normal_process_conflict() {

    local pid="$1"

    echo
    echo "=========================================="
    echo " Port ${PORT} is already in use"
    echo "=========================================="
    echo

    echo "[Process]"

    ps -p "$pid" \
        -o pid,ppid,user,lstart,cmd \
        --no-headers \
        2>/dev/null || true

    EXECUTABLE="$(
        readlink -f "/proc/${pid}/exe" \
        2>/dev/null || true
    )"

    echo
    echo "[Executable]"
    echo "${EXECUTABLE:-Unknown}"

    echo
    echo "[Listening socket]"

    ss -lntp 2>/dev/null \
        | grep ":${PORT}" || true

    echo

    OLD_SERVICE="$(
        systemctl status "$pid" 2>/dev/null \
        | sed -n \
        's/.*● \([^ ]*\.service\).*/\1/p' \
        | head -n1
    )"

    if [ -n "$OLD_SERVICE" ]; then
        echo "[systemd service]"
        echo "$OLD_SERVICE"
        echo
    fi

    OLD_PACKAGE=""

    if [ -n "$EXECUTABLE" ]; then

        if command -v dpkg >/dev/null 2>&1; then

            OLD_PACKAGE="$(
                dpkg -S "$EXECUTABLE" \
                2>/dev/null \
                | head -n1 \
                | cut -d: -f1
            )"

        elif command -v rpm >/dev/null 2>&1; then

            OLD_PACKAGE="$(
                rpm -qf "$EXECUTABLE" \
                2>/dev/null || true
            )"
        fi
    fi

    if [ -n "$OLD_PACKAGE" ]; then
        echo "[Package]"
        echo "$OLD_PACKAGE"
        echo
    fi

    if ! ask_yes_no \
        "Do you want to stop this program?"; then

        echo
        echo "Installation cancelled."
        exit 1
    fi

    if [ -n "$OLD_SERVICE" ]; then

        echo
        echo "Stopping service: $OLD_SERVICE"

        systemctl stop "$OLD_SERVICE" || true

    else

        echo
        echo "Stopping PID ${pid}"

        kill "$pid" 2>/dev/null || true

        sleep 2

        if kill -0 "$pid" 2>/dev/null; then

            if ask_yes_no \
                "Process is still running. Force kill it?"; then

                kill -9 "$pid" 2>/dev/null || true

            else
                exit 1
            fi
        fi
    fi

    echo

    if ask_yes_no \
        "Do you also want to uninstall/remove this program?"; then

        if [ -n "$OLD_SERVICE" ]; then

            systemctl disable "$OLD_SERVICE" \
                2>/dev/null || true

            SERVICE_FILE="$(
                systemctl show \
                    -p FragmentPath \
                    --value \
                    "$OLD_SERVICE" \
                    2>/dev/null || true
            )"

            #
            # IMPORTANT:
            # Do not manually delete package-owned files here.
            #
            if [ -n "$SERVICE_FILE" ]; then
                echo "Detected service file:"
                echo "$SERVICE_FILE"
            fi
        fi

        if [ -n "$OLD_PACKAGE" ]; then

            echo
            echo "Removing package:"
            echo "$OLD_PACKAGE"
            echo

            if command -v apt-get >/dev/null 2>&1; then

                apt-get remove -y "$OLD_PACKAGE"

            elif command -v dnf >/dev/null 2>&1; then

                dnf remove -y "$OLD_PACKAGE"

            elif command -v yum >/dev/null 2>&1; then

                yum remove -y "$OLD_PACKAGE"

            else
                echo "Unsupported package manager."
            fi

        else

            echo
            echo "Package manager could not identify this program."
            echo "No files will be deleted automatically."
        fi

    else

        echo
        echo "Program stopped but not removed."
    fi
}


# ============================================================
# Handle port conflict
# ============================================================

handle_port_conflict() {

    if ! port_is_busy; then
        echo "TCP ${PORT} is available."
        return
    fi

    echo
    echo "TCP ${PORT} is currently occupied."

    #
    # Docker must be checked FIRST.
    #
    # Otherwise docker-proxy appears to belong to:
    # docker.service / docker-ce
    #
    # and we absolutely do NOT want to uninstall Docker.
    #

    if find_docker_container_on_port; then

        handle_docker_conflict

    else

        PID="$(get_port_pid || true)"

        if [ -z "$PID" ]; then

            echo
            echo "ERROR:"
            echo "TCP ${PORT} is occupied but PID could not be identified."

            ss -lntp | grep ":${PORT}" || true

            exit 1
        fi

        handle_normal_process_conflict "$PID"
    fi

    sleep 1

    #
    # Important special case:
    #
    # Our native node_exporter may already start automatically
    # after the old service/container releases port 9100.
    #

    if port_is_busy; then

        PID="$(get_port_pid || true)"

        if [ -n "$PID" ]; then

            CURRENT_EXE="$(
                readlink -f "/proc/${PID}/exe" \
                2>/dev/null || true
            )"

            if [ "$CURRENT_EXE" = "$INSTALL_PATH" ]; then

                echo
                echo "TCP ${PORT} is now occupied by:"
                echo "$INSTALL_PATH"
                echo
                echo "This is our native Node Exporter."

                if curl -fsS \
                    "http://127.0.0.1:${PORT}/metrics" \
                    >/dev/null 2>&1; then

                    echo "Metrics endpoint: OK"

                    CURRENT_VERSION="$(
                        "$INSTALL_PATH" --version 2>&1 \
                        | head -n1
                    )"

                    echo "$CURRENT_VERSION"

                    exit 0
                fi
            fi
        fi

        echo
        echo "ERROR: TCP ${PORT} is still occupied."

        ss -lntp | grep ":${PORT}" || true

        exit 1
    fi

    echo
    echo "TCP ${PORT} is now available."
}


# ============================================================
# Start
# ============================================================

echo "[0/8] Checking TCP ${PORT}..."

handle_port_conflict


# ============================================================
# Architecture
# ============================================================

ARCH_RAW="$(uname -m)"

case "$ARCH_RAW" in

    x86_64|amd64)
        ARCH="amd64"
        ;;

    aarch64|arm64)
        ARCH="arm64"
        ;;

    armv7l|armv7)
        ARCH="armv7"
        ;;

    armv6l|armv6)
        ARCH="armv6"
        ;;

    *)
        echo "ERROR: Unsupported architecture: $ARCH_RAW"
        exit 1
        ;;

esac


echo
echo "[1/8] Architecture: linux-${ARCH}"


# ============================================================
# Download
# ============================================================

DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-${ARCH}.tar.gz"

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT


echo "[2/8] Preparing downloader..."


if ! command -v curl >/dev/null 2>&1 &&
   ! command -v wget >/dev/null 2>&1; then

    if command -v apt-get >/dev/null 2>&1; then

        apt-get update
        apt-get install -y curl

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y curl

    elif command -v yum >/dev/null 2>&1; then

        yum install -y curl

    else

        echo "ERROR: curl/wget not found."
        exit 1
    fi
fi


echo "[3/8] Downloading Node Exporter ${VERSION}..."


if command -v curl >/dev/null 2>&1; then

    curl -fL \
        "$DOWNLOAD_URL" \
        -o "$TMP_DIR/node_exporter.tar.gz"

else

    wget \
        -O "$TMP_DIR/node_exporter.tar.gz" \
        "$DOWNLOAD_URL"
fi


echo "[4/8] Installing binary..."


tar -xzf \
    "$TMP_DIR/node_exporter.tar.gz" \
    -C "$TMP_DIR"


install \
    -m 0755 \
    "$TMP_DIR/node_exporter-${VERSION}.linux-${ARCH}/node_exporter" \
    "$INSTALL_PATH"


# ============================================================
# User
# ============================================================

echo "[5/8] Creating service account..."


if ! id node_exporter >/dev/null 2>&1; then

    useradd \
        --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        node_exporter
fi


# ============================================================
# systemd
# ============================================================

echo "[6/8] Creating systemd service..."


cat >/etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple

User=node_exporter
Group=node_exporter

ExecStart=${INSTALL_PATH} \\
  --web.listen-address=:${PORT}

Restart=on-failure
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF


echo "[7/8] Starting Node Exporter..."


systemctl daemon-reload

systemctl enable --now node_exporter


sleep 2


# ============================================================
# Verify
# ============================================================

echo "[8/8] Verification..."


if ! systemctl is-active \
    --quiet node_exporter; then

    echo
    echo "ERROR: Node Exporter failed to start."
    echo

    journalctl \
        -u node_exporter \
        -n 50 \
        --no-pager

    exit 1
fi


if ! curl -fsS \
    "http://127.0.0.1:${PORT}/metrics" \
    >/dev/null; then

    echo
    echo "ERROR:"
    echo "Node Exporter is running but metrics endpoint failed."

    exit 1
fi


echo
echo "=========================================="
echo " Node Exporter successfully installed"
echo "=========================================="
echo

"$INSTALL_PATH" --version | head -n1

echo
echo "Service:"
echo "  active"

echo
echo "Metrics:"
echo "  http://127.0.0.1:${PORT}/metrics"

echo
echo "Listening:"
ss -lntp | grep ":${PORT}" || true

echo
echo "Useful commands:"
echo
echo "  systemctl status node_exporter"
echo "  systemctl restart node_exporter"
echo "  journalctl -u node_exporter -f"
echo
