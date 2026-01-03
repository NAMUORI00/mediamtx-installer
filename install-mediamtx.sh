#!/bin/bash
#
# MediaMTX Streaming Server Installation Script
# Ubuntu 24.04 + Docker based
# Low-latency, Low-resource (1GB RAM) optimized
#

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Installation directory
INSTALL_DIR="/opt/mediamtx"

# Default values
DEFAULT_RTMP_PORT=1935
DEFAULT_RTSP_PORT=8554
DEFAULT_HLS_PORT=8888
DEFAULT_API_PORT=9997

# Non-interactive mode flag
AUTO_MODE=false

# Function: Log output
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function: Check root permission
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root."
        echo "Usage: sudo $0"
        exit 1
    fi
}

# Function: Check Ubuntu
check_ubuntu() {
    if [ ! -f /etc/os-release ]; then
        log_error "Unsupported operating system."
        exit 1
    fi

    . /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        log_warn "This is not Ubuntu. Continue anyway? (y/n)"
        read -r response
        if [ "$response" != "y" ]; then
            exit 1
        fi
    fi
    log_info "OS: $PRETTY_NAME"
}

# Function: Generate random string
generate_random_string() {
    local length=${1:-16}
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

# Function: Get server IP (IPv4 preferred)
get_server_ip() {
    local public_ip

    # Try public IPv4 first (force IPv4 with -4 flag)
    public_ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
    if [ -n "$public_ip" ]; then
        echo "$public_ip"
        return
    fi

    # Fallback: try icanhazip with IPv4
    public_ip=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null)
    if [ -n "$public_ip" ]; then
        echo "$public_ip"
        return
    fi

    # Fallback: try api.ipify.org (IPv4 only service)
    public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    if [ -n "$public_ip" ]; then
        echo "$public_ip"
        return
    fi

    # Last resort: use local IPv4 address
    hostname -I | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1
}

# Function: Install Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed."
        docker --version
        return 0
    fi

    log_info "Installing Docker..."

    # Install required packages
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    # Add Docker official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start Docker service
    if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null; then
        systemctl enable docker
        systemctl start docker
    else
        log_warn "systemd not found. Starting Docker daemon manually."
        # Check if Docker daemon is already running
        if ! docker info &> /dev/null; then
            # Check if Docker socket is mounted
            if [ -S /var/run/docker.sock ]; then
                log_info "Docker socket already exists."
            else
                log_error "Cannot start Docker daemon. systemd is required."
                exit 1
            fi
        fi
    fi

    log_success "Docker installation complete"
    docker --version
}

# Function: Interactive setup
interactive_setup() {
    echo ""
    echo "=========================================="
    echo "   MediaMTX Streaming Server Setup"
    echo "=========================================="
    echo ""

    if [ "$AUTO_MODE" = true ]; then
        # Non-interactive mode: use defaults or environment variables
        RTMP_PORT=${RTMP_PORT:-$DEFAULT_RTMP_PORT}
        RTSP_PORT=${RTSP_PORT:-$DEFAULT_RTSP_PORT}
        HLS_PORT=${HLS_PORT:-$DEFAULT_HLS_PORT}
        API_PORT=${API_PORT:-$DEFAULT_API_PORT}
        if [ -z "$STREAM_KEY" ]; then
            STREAM_KEY=$(generate_random_string 16)
        fi
        log_info "Non-interactive mode: using defaults"
    else
        # RTMP port
        read -p "RTMP port (OBS streaming) [default: $DEFAULT_RTMP_PORT]: " RTMP_PORT
        RTMP_PORT=${RTMP_PORT:-$DEFAULT_RTMP_PORT}

        # RTSP port
        read -p "RTSP port (VLC playback) [default: $DEFAULT_RTSP_PORT]: " RTSP_PORT
        RTSP_PORT=${RTSP_PORT:-$DEFAULT_RTSP_PORT}

        # HLS port
        read -p "HLS port (Web browser) [default: $DEFAULT_HLS_PORT]: " HLS_PORT
        HLS_PORT=${HLS_PORT:-$DEFAULT_HLS_PORT}

        # API port
        read -p "API port (Management) [default: $DEFAULT_API_PORT]: " API_PORT
        API_PORT=${API_PORT:-$DEFAULT_API_PORT}

        # Stream key
        echo ""
        echo "Stream key is the password required for OBS broadcasting."
        read -p "Stream key [Press Enter to auto-generate]: " STREAM_KEY
        if [ -z "$STREAM_KEY" ]; then
            STREAM_KEY=$(generate_random_string 16)
            log_info "Stream key auto-generated: $STREAM_KEY"
        fi

        echo ""
        read -p "Proceed with these settings? (y/n) [y]: " confirm
        confirm=${confirm:-y}
        if [ "$confirm" != "y" ]; then
            log_warn "Installation cancelled."
            exit 0
        fi
    fi

    echo ""
    echo "Configuration:"
    echo "  RTMP port: $RTMP_PORT"
    echo "  RTSP port: $RTSP_PORT"
    echo "  HLS port: $HLS_PORT"
    echo "  API port: $API_PORT"
    echo "  Stream key: $STREAM_KEY"
}

# Function: Create mediamtx.yml
create_mediamtx_config() {
    log_info "Creating mediamtx.yml configuration file..."

    cat > "$INSTALL_DIR/mediamtx.yml" << EOF
###############################################
# MediaMTX Configuration
# Low-latency, Low-resource (1GB RAM) optimized
###############################################

# Logging settings (minimal)
logLevel: warn
logDestinations: [stdout]

###############################################
# RTMP (OBS input)
###############################################
rtmp: yes
rtmpAddress: :${RTMP_PORT}

###############################################
# RTSP (VLC output)
###############################################
rtsp: yes
rtspAddress: :${RTSP_PORT}
rtspTransports: [tcp]

###############################################
# HLS (Web browser) - Low-latency settings
###############################################
hls: yes
hlsAddress: :${HLS_PORT}
hlsVariant: lowLatency
hlsSegmentCount: 7
hlsSegmentDuration: 1s
hlsPartDuration: 200ms
hlsDirectory: /tmp/hls
hlsAlwaysRemux: no
hlsEncryption: no

###############################################
# API (Management)
###############################################
api: yes
apiAddress: :${API_PORT}

###############################################
# Performance optimization (Low-resource)
###############################################
writeQueueSize: 256
udpMaxPayloadSize: 1472
readTimeout: 10s
writeTimeout: 10s

###############################################
# Disable unnecessary protocols (Save resources)
###############################################
webrtc: no
srt: no

###############################################
# Authentication settings
# OBS URL: rtmp://SERVER_IP:1935/live?user=publisher&pass=STREAM_KEY
# Viewing: No authentication (anyone can watch)
###############################################
authMethod: internal
authInternalUsers:
  # Publisher - Stream key authentication required
  - user: publisher
    pass: ${STREAM_KEY}
    ips: []
    permissions:
      - action: publish
        path:
  # Viewer - Anyone can watch
  - user: any
    pass:
    ips: []
    permissions:
      - action: read
        path:
      - action: playback
        path:
  # Local API access (Docker and internal networks)
  - user: any
    pass:
    ips: ['127.0.0.1', '::1', '172.17.0.0/16', '192.168.0.0/16', '10.0.0.0/8']
    permissions:
      - action: api
      - action: metrics
      - action: pprof

###############################################
# Stream path settings
###############################################
paths:
  all:
EOF

    log_success "mediamtx.yml created"
}

# Function: Create docker-compose.yml
create_docker_compose() {
    log_info "Creating docker-compose.yml..."

    cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:
  mediamtx:
    image: bluenviron/mediamtx:latest-ffmpeg
    container_name: mediamtx
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${INSTALL_DIR}/mediamtx.yml:/mediamtx.yml:ro
      - /tmp/hls:/tmp/hls
    environment:
      - MTX_LOGLEVEL=warn
    deploy:
      resources:
        limits:
          memory: 512M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_success "docker-compose.yml created"
}

# Function: Create credentials file
create_credentials_file() {
    log_info "Creating credentials.txt..."

    local server_ip
    server_ip=$(get_server_ip)

    cat > "$INSTALL_DIR/credentials.txt" << EOF
============================================
MediaMTX Streaming Server Connection Info
Created: $(date '+%Y-%m-%d %H:%M:%S')
============================================

[OBS Settings]
Server URL: rtmp://${server_ip}:${RTMP_PORT}/live?user=publisher&pass=${STREAM_KEY}
Stream Key: (included in URL)

[Viewing]
VLC: rtsp://${server_ip}:${RTSP_PORT}/live
Browser: http://${server_ip}:${HLS_PORT}/live

[Management API]
URL: http://${server_ip}:${API_PORT}/v3/paths/list

[Port Info]
RTMP: ${RTMP_PORT}
RTSP: ${RTSP_PORT}
HLS: ${HLS_PORT}
API: ${API_PORT}

============================================
EOF

    chmod 600 "$INSTALL_DIR/credentials.txt"
    log_success "credentials.txt created"
}

# Function: Configure firewall
configure_firewall() {
    if command -v ufw &> /dev/null; then
        log_info "Configuring UFW firewall ports..."

        ufw allow "$RTMP_PORT"/tcp comment 'MediaMTX RTMP'
        ufw allow "$RTSP_PORT"/tcp comment 'MediaMTX RTSP'
        ufw allow "$HLS_PORT"/tcp comment 'MediaMTX HLS'
        ufw allow "$API_PORT"/tcp comment 'MediaMTX API'

        log_success "Firewall ports opened"
    else
        log_warn "UFW not installed. Please configure firewall manually."
        echo "Required ports: $RTMP_PORT, $RTSP_PORT, $HLS_PORT, $API_PORT (TCP)"
    fi
}

# Function: Start Docker container
start_container() {
    log_info "Starting MediaMTX container..."

    cd "$INSTALL_DIR"

    # Clean up existing container
    docker compose down 2>/dev/null || true

    # Create HLS directory
    mkdir -p /tmp/hls

    # Start container
    docker compose up -d

    # Wait for startup
    sleep 3

    # Check status
    if docker ps | grep -q mediamtx; then
        log_success "MediaMTX container started successfully."
    else
        log_error "Container failed to start. Check logs:"
        docker logs mediamtx
        exit 1
    fi
}

# Function: Print completion message
print_completion_message() {
    local server_ip
    server_ip=$(get_server_ip)

    echo ""
    echo "============================================================"
    echo "       MediaMTX Streaming Server Installation Complete!"
    echo "============================================================"
    echo ""
    echo -e "${GREEN}[OBS Settings]${NC}"
    echo "   Server URL: rtmp://${server_ip}:${RTMP_PORT}/live?user=publisher&pass=${STREAM_KEY}"
    echo "   Stream Key: (included in URL, leave empty in OBS)"
    echo ""
    echo -e "${GREEN}[Viewing]${NC}"
    echo "   VLC: rtsp://${server_ip}:${RTSP_PORT}/live"
    echo "   Browser: http://${server_ip}:${HLS_PORT}/live"
    echo ""
    echo -e "${GREEN}[Management]${NC}"
    echo "   API: http://${server_ip}:${API_PORT}/v3/paths/list"
    echo ""
    echo "   Start service: docker compose -f ${INSTALL_DIR}/docker-compose.yml up -d"
    echo "   Stop service: docker compose -f ${INSTALL_DIR}/docker-compose.yml down"
    echo "   View logs: docker logs -f mediamtx"
    echo "   Check status: docker ps | grep mediamtx"
    echo ""
    echo -e "${YELLOW}[VLC Low-latency Tip]${NC}"
    echo "   Tools > Preferences > Input/Codecs > Network caching = 50ms"
    echo ""
    echo -e "${BLUE}[Config File]${NC} ${INSTALL_DIR}/credentials.txt"
    echo ""
    echo "                        made by Ori_M"
    echo ""
}

# Function: Show usage
show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -y, --yes       Non-interactive mode (use defaults)"
    echo "  -h, --help      Show this help"
    echo ""
    echo "Environment variables (for non-interactive mode):"
    echo "  RTMP_PORT       RTMP port (default: 1935)"
    echo "  RTSP_PORT       RTSP port (default: 8554)"
    echo "  HLS_PORT        HLS port (default: 8888)"
    echo "  API_PORT        API port (default: 9997)"
    echo "  STREAM_KEY      Stream key (default: auto-generated)"
    echo ""
    echo "Examples:"
    echo "  sudo $0                           # Interactive mode"
    echo "  sudo $0 -y                        # Install with defaults"
    echo "  sudo STREAM_KEY=mykey $0 -y       # Specify stream key"
}

# Function: Parse arguments
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)
                AUTO_MODE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    # Parse arguments
    parse_args "$@"

    echo ""
    echo "============================================================"
    echo "       MediaMTX Streaming Server Installation Script"
    echo "       Ubuntu 24.04 + Docker"
    echo "============================================================"
    echo "                        made by Ori_M"
    echo ""

    # Pre-checks
    check_root
    check_ubuntu

    # Install Docker
    install_docker

    # Interactive setup
    interactive_setup

    # Create installation directory
    log_info "Creating installation directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    # Create config files
    create_mediamtx_config
    create_docker_compose
    create_credentials_file

    # Configure firewall
    configure_firewall

    # Start container
    start_container

    # Print completion message
    print_completion_message
}

# Run script
main "$@"
