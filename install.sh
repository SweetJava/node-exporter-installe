#!/usr/bin/env bash

set -euo pipefail

VERSION="1.12.1"
PORT="9100"

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

ask_yes_no() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "${prompt} [y/N]: " answer
        case "${answer:-N}" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No|"")
                return 1
                ;;
            *)
                echo "Please enter y or n."
                ;;
        esac
    done
}

get_port_pid() {
    ss -lntp 2>/dev/null \
        | awk -v port=":${PORT}" '$4 ~ port"$"' \
        | grep -oE 'pid=[0-9]+' \
        | head -n1 \
        | cut -d= -f2 || true
}

show_process_info() {
    local pid="$1"

    echo
    echo "=========================================="
    echo " Port ${PORT} is already in use"
    echo "=========================================="

    echo
    echo "[Process]"
    ps -p "$pid" -o pid,ppid,user,lstart,cmd --no-headers 2>/dev/null || true

    echo
    echo "[Executable]"
    readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "Unknown"

    echo
    echo "[Command line]"
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true
    echo

    echo
    echo "[Listening socket]"
    ss -lntp 2>/dev/null | grep ":${PORT}" || true

    SERVICE_NAME="$(systemctl status "$pid" 2>/dev/null \
        | sed -n 's/.*● \([^ ]*\.service\).*/\1/p' \
        | head -n1 || true)"

    if [ -n "${SERVICE_NAME:-}" ]; then
        echo
        echo "[systemd service]"
        echo "$SERVICE_NAME"
    fi

    EXECUTABLE="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"

    PACKAGE_NAME=""

    if [ -n "$EXECUTABLE" ]; then
        if command -v dpkg >/dev/null 2>&1; then
            PACKAGE_NAME="$(dpkg -S "$EXECUTABLE" 2>/dev/null \
                | head -n1 \
                | cut -d: -f1 || true)"
        elif command -v rpm >/dev/null 2>&1; then
            PACKAGE_NAME="$(rpm -qf "$EXECUTABLE" 2>/dev/null || true)"
        fi
    fi

    if [ -n "${PACKAGE_NAME:-}" ]; then
        echo
        echo "[Package]"
        echo "$PACKAGE_NAME"
    fi

    DOCKER_CONTAINER=""

    if command -v docker >/dev/null 2>&1; then
        DOCKER_CONTAINER="$(docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' 2>/dev/null \
            | grep -E "(0\.0\.0\.0:|:::|127\.0\.0\.1:)${PORT}->" \
            | head -n1 || true)"
    fi

    if [ -n "${DOCKER_CONTAINER:-}" ]; then
        echo
        echo "[Docker container]"
        echo "$DOCKER_CONTAINER"
    fi
}

remove_existing_program() {
    local pid="$1"

    echo
    echo "Trying to identify how this program is managed..."

    if [ -n "${DOCKER_CONTAINER:-}" ]; then
        local container_id
        container_id="$(echo "$DOCKER_CONTAINER" | awk '{print $1}')"

        echo
        echo "Detected Docker container:"
        docker inspect \
            --format 'Name={{.Name}} Image={{.Config.Image}}' \
            "$container_id" 2>/dev/null || true

        if ask_yes_no "Remove this Docker container?"; then
            docker rm -f "$container_id"
            echo "Docker container removed."
        fi

        return
    fi

    if [ -n "${SERVICE_NAME:-}" ]; then
        echo
        echo "Detected systemd service: ${SERVICE_NAME}"

        if ask_yes_no "Disable this service from starting automatically?"; then
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        fi

        if ask_yes_no "Remove systemd service file ${SERVICE_NAME}?"; then
            SERVICE_FILE="$(systemctl show \
                -p FragmentPath \
                --value \
                "$SERVICE_NAME" 2>/dev/null || true)"

            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true

            if [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ]; then
                echo "Removing:"
                echo "$SERVICE_FILE"
                rm -f "$SERVICE_FILE"
                systemctl daemon-reload
            else
                echo "Service file could not be safely identified."
            fi
        fi
    fi

    if [ -n "${PACKAGE_NAME:-}" ]; then
        echo
        echo "Detected package: ${PACKAGE_NAME}"

        if ask_yes_no "Uninstall package ${PACKAGE_NAME}?"; then

            if command -v apt-get >/dev/null 2>&1; then
                apt-get remove -y "$PACKAGE_NAME"

            elif command -v dnf >/dev/null 2>&1; then
                dnf remove -y "$PACKAGE_NAME"

            elif command -v yum >/dev/null 2>&1; then
                yum remove -y "$PACKAGE_NAME"

            else
                echo "No supported package manager found."
                echo "Package was NOT removed."
            fi
        fi
    elif [ -z "${SERVICE_NAME:-}" ] && [ -z "${DOCKER_CONTAINER:-}" ]; then

        echo
        echo "WARNING:"
        echo "The installer cannot safely determine how this program was installed."
        echo "It will NOT delete files automatically."

        if [ -n "${EXECUTABLE:-}" ]; then
            echo
            echo "Executable:"
            echo "$EXECUTABLE"
        fi
    fi
}

handle_port_conflict() {
    local pid
    pid="$(get_port_pid)"

    if [ -z "$pid" ]; then
        return 0
    fi

    show_process_info "$pid"

    echo
    echo "Another program is using TCP ${PORT}."

    if ! ask_yes_no "Do you want to stop this program?"; then
        echo
        echo "Installation cancelled."
        echo "TCP ${PORT} must be free before Node Exporter can start."
        exit 1
    fi

    echo
    echo "Stopping PID ${pid}..."

    if [ -n "${SERVICE_NAME:-}" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    elif [ -n "${DOCKER_CONTAINER:-}" ]; then
        container_id="$(echo "$DOCKER_CONTAINER" | awk '{print $1}')"
        docker stop "$container_id" 2>/dev/null || true
    else
        kill "$pid" 2>/dev/null || true
        sleep 2

        if kill -0 "$pid" 2>/dev/null; then
            echo "Process is still running."
            if ask_yes_no "Force kill PID ${pid}?"; then
                kill -9 "$pid"
            else
                echo "Installation cancelled."
                exit 1
            fi
        fi
    fi

    sleep 1

    echo
    if ask_yes_no "Do you also want to uninstall/remove the program that was using ${PORT}?"; then
        remove_existing_program "$pid"
    else
        echo "Existing program was stopped but not removed."
        echo "WARNING: it may start again after reboot."
    fi

    sleep 1

    local remaining_pid
    remaining_pid="$(get_port_pid)"

    if [ -n "$remaining_pid" ]; then
        echo
        echo "ERROR: TCP ${PORT} is still occupied."
        ss -lntp | grep ":${PORT}" || true
        exit 1
    fi

    echo
    echo "TCP ${PORT} is now available."
}

echo "[0/8] Checking TCP ${PORT}..."

handle_port_conflict

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

DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-${ARCH}.tar.gz"

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

echo "[2/8] Preparing downloader..."

if ! command -v curl >/dev/null 2>&1 && \
   ! command -v wget >/dev/null 2>&1; then

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl
    else
        echo "ERROR: curl/wget is missing."
        exit 1
    fi
fi

echo "[3/8] Downloading Node Exporter..."

if command -v curl >/dev/null 2>&1; then
    curl -fL "$DOWNLOAD_URL" \
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
    /usr/local/bin/node_exporter

echo "[5/8] Creating service account..."

if ! id node_exporter >/dev/null 2>&1; then
    useradd \
        --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        node_exporter
fi

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

ExecStart=/usr/local/bin/node_exporter \\
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

echo "[8/8] Verification..."

if ! systemctl is-active --quiet node_exporter; then
    echo
    echo "ERROR: Node Exporter failed to start."
    echo
    journalctl \
        -u node_exporter \
        -n 50 \
        --no-pager
    exit 1
fi

echo
echo "=========================================="
echo " Node Exporter successfully installed"
echo "=========================================="

echo
echo "Version:"
/usr/local/bin/node_exporter --version | head -n1

echo
echo "Service:"
systemctl is-active node_exporter

echo
echo "Listening:"
ss -lntp | grep ":${PORT}" || true

echo
echo "Metrics test:"

if curl -fsS \
    "http://127.0.0.1:${PORT}/metrics" \
    >/dev/null; then

    echo "OK: http://127.0.0.1:${PORT}/metrics"
else
    echo "ERROR: local metrics endpoint failed."
fi

echo
echo "Useful commands:"
echo
echo "  systemctl status node_exporter"
echo "  systemctl restart node_exporter"
echo "  journalctl -u node_exporter -f"
echo
