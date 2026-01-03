#!/bin/bash
#
# MediaMTX 스트리밍 서버 설치 스크립트
# Ubuntu 24.04 + Docker 기반
# 저지연, 저사양(1GB RAM) 최적화
#

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 설치 디렉토리
INSTALL_DIR="/opt/mediamtx"

# 기본값
DEFAULT_RTMP_PORT=1935
DEFAULT_RTSP_PORT=8554
DEFAULT_HLS_PORT=8888
DEFAULT_API_PORT=9997

# 비대화형 모드 플래그
AUTO_MODE=false

# 함수: 로그 출력
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

# 함수: root 권한 확인
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "이 스크립트는 root 권한으로 실행해야 합니다."
        echo "사용법: sudo $0"
        exit 1
    fi
}

# 함수: Ubuntu 확인
check_ubuntu() {
    if [ ! -f /etc/os-release ]; then
        log_error "지원되지 않는 운영체제입니다."
        exit 1
    fi

    . /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        log_warn "Ubuntu가 아닌 환경입니다. 계속 진행하시겠습니까? (y/n)"
        read -r response
        if [ "$response" != "y" ]; then
            exit 1
        fi
    fi
    log_info "운영체제: $PRETTY_NAME"
}

# 함수: 랜덤 문자열 생성
generate_random_string() {
    local length=${1:-16}
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

# 함수: 서버 IP 가져오기
get_server_ip() {
    # 공인 IP 시도
    local public_ip
    public_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "")

    if [ -n "$public_ip" ]; then
        echo "$public_ip"
    else
        # 로컬 IP 사용
        hostname -I | awk '{print $1}'
    fi
}

# 함수: Docker 설치
install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker가 이미 설치되어 있습니다."
        docker --version
        return 0
    fi

    log_info "Docker를 설치합니다..."

    # 필수 패키지 설치
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    # Docker 공식 GPG 키 추가
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Docker 저장소 추가
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Docker 설치
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Docker 서비스 시작
    if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null; then
        systemctl enable docker
        systemctl start docker
    else
        log_warn "systemd가 없습니다. Docker 데몬을 수동으로 시작합니다."
        # Docker 데몬이 이미 실행 중인지 확인
        if ! docker info &> /dev/null; then
            # Docker 소켓이 마운트되어 있는지 확인
            if [ -S /var/run/docker.sock ]; then
                log_info "Docker 소켓이 이미 존재합니다."
            else
                log_error "Docker 데몬을 시작할 수 없습니다. systemd가 필요합니다."
                exit 1
            fi
        fi
    fi

    log_success "Docker 설치 완료"
    docker --version
}

# 함수: 대화형 설정
interactive_setup() {
    echo ""
    echo "=========================================="
    echo "   MediaMTX 스트리밍 서버 설정"
    echo "=========================================="
    echo ""

    if [ "$AUTO_MODE" = true ]; then
        # 비대화형 모드: 기본값 또는 환경변수 사용
        RTMP_PORT=${RTMP_PORT:-$DEFAULT_RTMP_PORT}
        RTSP_PORT=${RTSP_PORT:-$DEFAULT_RTSP_PORT}
        HLS_PORT=${HLS_PORT:-$DEFAULT_HLS_PORT}
        API_PORT=${API_PORT:-$DEFAULT_API_PORT}
        if [ -z "$STREAM_KEY" ]; then
            STREAM_KEY=$(generate_random_string 16)
        fi
        log_info "비대화형 모드: 기본값 사용"
    else
        # RTMP 포트
        read -p "RTMP 포트 (OBS 송출) [기본: $DEFAULT_RTMP_PORT]: " RTMP_PORT
        RTMP_PORT=${RTMP_PORT:-$DEFAULT_RTMP_PORT}

        # RTSP 포트
        read -p "RTSP 포트 (VLC 재생) [기본: $DEFAULT_RTSP_PORT]: " RTSP_PORT
        RTSP_PORT=${RTSP_PORT:-$DEFAULT_RTSP_PORT}

        # HLS 포트
        read -p "HLS 포트 (웹 브라우저) [기본: $DEFAULT_HLS_PORT]: " HLS_PORT
        HLS_PORT=${HLS_PORT:-$DEFAULT_HLS_PORT}

        # API 포트
        read -p "API 포트 (관리용) [기본: $DEFAULT_API_PORT]: " API_PORT
        API_PORT=${API_PORT:-$DEFAULT_API_PORT}

        # 스트림 키
        echo ""
        echo "스트림 키는 OBS에서 방송할 때 필요한 비밀번호입니다."
        read -p "스트림 키 [Enter시 자동생성]: " STREAM_KEY
        if [ -z "$STREAM_KEY" ]; then
            STREAM_KEY=$(generate_random_string 16)
            log_info "스트림 키 자동 생성됨: $STREAM_KEY"
        fi

        echo ""
        read -p "이 설정으로 진행하시겠습니까? (y/n) [y]: " confirm
        confirm=${confirm:-y}
        if [ "$confirm" != "y" ]; then
            log_warn "설치가 취소되었습니다."
            exit 0
        fi
    fi

    echo ""
    echo "설정 확인:"
    echo "  RTMP 포트: $RTMP_PORT"
    echo "  RTSP 포트: $RTSP_PORT"
    echo "  HLS 포트: $HLS_PORT"
    echo "  API 포트: $API_PORT"
    echo "  스트림 키: $STREAM_KEY"
}

# 함수: mediamtx.yml 생성
create_mediamtx_config() {
    log_info "mediamtx.yml 설정 파일 생성 중..."

    cat > "$INSTALL_DIR/mediamtx.yml" << EOF
###############################################
# MediaMTX 설정 파일
# 저지연, 저사양(1GB RAM) 최적화
###############################################

# 로깅 설정 (최소화)
logLevel: warn
logDestinations: [stdout]

###############################################
# RTMP (OBS 입력용)
###############################################
rtmp: yes
rtmpAddress: :${RTMP_PORT}

###############################################
# RTSP (VLC 출력용)
###############################################
rtsp: yes
rtspAddress: :${RTSP_PORT}
rtspTransports: [tcp]

###############################################
# HLS (웹 브라우저용) - 저지연 설정
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
# API (관리용)
###############################################
api: yes
apiAddress: :${API_PORT}

###############################################
# 성능 최적화 (저사양 시스템용)
###############################################
writeQueueSize: 256
udpMaxPayloadSize: 1472
readTimeout: 10s
writeTimeout: 10s

###############################################
# 불필요한 프로토콜 비활성화 (리소스 절약)
###############################################
webrtc: no
srt: no

###############################################
# 인증 설정
# OBS 송출 URL: rtmp://서버IP:1935/live?user=publisher&pass=${STREAM_KEY}
# 시청: 인증 없음 (누구나 가능)
###############################################
authMethod: internal
authInternalUsers:
  # 송출자 - 스트림 키로 인증 필요
  - user: publisher
    pass: ${STREAM_KEY}
    ips: []
    permissions:
      - action: publish
        path:
  # 시청자 - 누구나 시청 가능
  - user: any
    pass:
    ips: []
    permissions:
      - action: read
        path:
      - action: playback
        path:
  # 로컬 API 접근 (Docker 및 내부 네트워크)
  - user: any
    pass:
    ips: ['127.0.0.1', '::1', '172.17.0.0/16', '192.168.0.0/16', '10.0.0.0/8']
    permissions:
      - action: api
      - action: metrics
      - action: pprof

###############################################
# 스트림 경로 설정
###############################################
paths:
  all:
EOF

    log_success "mediamtx.yml 생성 완료"
}

# 함수: docker-compose.yml 생성
create_docker_compose() {
    log_info "docker-compose.yml 생성 중..."

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

    log_success "docker-compose.yml 생성 완료"
}

# 함수: 자격 증명 파일 생성
create_credentials_file() {
    log_info "credentials.txt 생성 중..."

    local server_ip
    server_ip=$(get_server_ip)

    cat > "$INSTALL_DIR/credentials.txt" << EOF
============================================
MediaMTX 스트리밍 서버 접속 정보
생성일: $(date '+%Y-%m-%d %H:%M:%S')
============================================

[OBS 설정]
서버 URL: rtmp://${server_ip}:${RTMP_PORT}/live?user=publisher&pass=${STREAM_KEY}
스트림 키: (URL에 포함됨)

[시청 방법]
VLC: rtsp://${server_ip}:${RTSP_PORT}/live
브라우저: http://${server_ip}:${HLS_PORT}/live

[관리 API]
URL: http://${server_ip}:${API_PORT}/v3/paths/list

[포트 정보]
RTMP: ${RTMP_PORT}
RTSP: ${RTSP_PORT}
HLS: ${HLS_PORT}
API: ${API_PORT}

============================================
EOF

    chmod 600 "$INSTALL_DIR/credentials.txt"
    log_success "credentials.txt 생성 완료"
}

# 함수: 방화벽 설정
configure_firewall() {
    if command -v ufw &> /dev/null; then
        log_info "UFW 방화벽 포트 설정 중..."

        ufw allow "$RTMP_PORT"/tcp comment 'MediaMTX RTMP'
        ufw allow "$RTSP_PORT"/tcp comment 'MediaMTX RTSP'
        ufw allow "$HLS_PORT"/tcp comment 'MediaMTX HLS'
        ufw allow "$API_PORT"/tcp comment 'MediaMTX API'

        log_success "방화벽 포트 열기 완료"
    else
        log_warn "UFW가 설치되어 있지 않습니다. 수동으로 방화벽을 설정하세요."
        echo "필요한 포트: $RTMP_PORT, $RTSP_PORT, $HLS_PORT, $API_PORT (TCP)"
    fi
}

# 함수: Docker 컨테이너 시작
start_container() {
    log_info "MediaMTX 컨테이너 시작 중..."

    cd "$INSTALL_DIR"

    # 기존 컨테이너 정리
    docker compose down 2>/dev/null || true

    # HLS 디렉토리 생성
    mkdir -p /tmp/hls

    # 컨테이너 시작
    docker compose up -d

    # 시작 대기
    sleep 3

    # 상태 확인
    if docker ps | grep -q mediamtx; then
        log_success "MediaMTX 컨테이너가 정상적으로 시작되었습니다."
    else
        log_error "컨테이너 시작에 실패했습니다. 로그를 확인하세요:"
        docker logs mediamtx
        exit 1
    fi
}

# 함수: 설치 완료 메시지
print_completion_message() {
    local server_ip
    server_ip=$(get_server_ip)

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         MediaMTX 스트리밍 서버 설치 완료!                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "${GREEN}📡 OBS 설정:${NC}"
    echo "   서버 URL: rtmp://${server_ip}:${RTMP_PORT}/live?user=publisher&pass=${STREAM_KEY}"
    echo "   스트림 키: (URL에 포함됨)"
    echo ""
    echo -e "${GREEN}📺 시청 방법:${NC}"
    echo "   VLC: rtsp://${server_ip}:${RTSP_PORT}/live"
    echo "   브라우저: http://${server_ip}:${HLS_PORT}/live"
    echo ""
    echo -e "${GREEN}🔧 관리:${NC}"
    echo "   API: http://${server_ip}:${API_PORT}/v3/paths/list"
    echo ""
    echo "   서비스 시작: docker compose -f ${INSTALL_DIR}/docker-compose.yml up -d"
    echo "   서비스 중지: docker compose -f ${INSTALL_DIR}/docker-compose.yml down"
    echo "   로그 확인: docker logs -f mediamtx"
    echo "   상태 확인: docker ps | grep mediamtx"
    echo ""
    echo -e "${YELLOW}💡 VLC 저지연 팁:${NC}"
    echo "   도구 > 환경설정 > 입력/코덱 > 네트워크 캐싱 = 50ms"
    echo ""
    echo -e "${YELLOW}💡 OBS 설정 팁:${NC}"
    echo "   서버 URL에 인증 정보가 포함되어 있으므로 스트림 키 칸은 비워두세요"
    echo ""
    echo -e "${BLUE}📁 설정 파일: ${INSTALL_DIR}/credentials.txt${NC}"
    echo ""
}

# 함수: 사용법 출력
show_usage() {
    echo "사용법: $0 [옵션]"
    echo ""
    echo "옵션:"
    echo "  -y, --yes       비대화형 모드 (기본값 사용)"
    echo "  -h, --help      도움말 출력"
    echo ""
    echo "환경변수 (비대화형 모드에서 사용):"
    echo "  RTMP_PORT       RTMP 포트 (기본: 1935)"
    echo "  RTSP_PORT       RTSP 포트 (기본: 8554)"
    echo "  HLS_PORT        HLS 포트 (기본: 8888)"
    echo "  API_PORT        API 포트 (기본: 9997)"
    echo "  STREAM_KEY      스트림 키 (기본: 자동생성)"
    echo ""
    echo "예시:"
    echo "  sudo $0                           # 대화형 모드"
    echo "  sudo $0 -y                        # 기본값으로 설치"
    echo "  sudo STREAM_KEY=mykey $0 -y       # 스트림 키 지정"
}

# 함수: 인자 파싱
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
                log_error "알 수 없는 옵션: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# 메인 실행
main() {
    # 인자 파싱
    parse_args "$@"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         MediaMTX 스트리밍 서버 설치 스크립트                    ║"
    echo "║         Ubuntu 24.04 + Docker 기반                           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # 사전 확인
    check_root
    check_ubuntu

    # Docker 설치
    install_docker

    # 대화형 설정
    interactive_setup

    # 설치 디렉토리 생성
    log_info "설치 디렉토리 생성: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    # 설정 파일 생성
    create_mediamtx_config
    create_docker_compose
    create_credentials_file

    # 방화벽 설정
    configure_firewall

    # 컨테이너 시작
    start_container

    # 완료 메시지
    print_completion_message
}

# 스크립트 실행
main "$@"
