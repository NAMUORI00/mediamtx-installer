# MediaMTX 스트리밍 서버 설치 스크립트

Ubuntu 24.04 + Docker 기반 저지연 스트리밍 서버를 한 줄 명령어로 설치합니다.

## 워크플로우

```
OBS (RTMP) → MediaMTX → VLC (RTSP) / 브라우저 (HLS)
```

## Installation

### Interactive Mode (Recommended)

```bash
wget -O install-mediamtx.sh https://raw.githubusercontent.com/NAMUORI00/mediamtx-installer/master/install-mediamtx.sh && sudo bash install-mediamtx.sh
```

### Non-interactive Mode (Use defaults)

```bash
wget -O install-mediamtx.sh https://raw.githubusercontent.com/NAMUORI00/mediamtx-installer/master/install-mediamtx.sh && sudo bash install-mediamtx.sh -y
```

### Specify Stream Key

```bash
wget -O install-mediamtx.sh https://raw.githubusercontent.com/NAMUORI00/mediamtx-installer/master/install-mediamtx.sh && sudo STREAM_KEY=mySecretKey bash install-mediamtx.sh -y
```

## 설정 옵션

| 환경변수 | 기본값 | 설명 |
|----------|--------|------|
| `RTMP_PORT` | 1935 | OBS 송출 포트 |
| `RTSP_PORT` | 8554 | VLC 재생 포트 |
| `HLS_PORT` | 8888 | 웹 브라우저 포트 |
| `API_PORT` | 9997 | 관리 API 포트 |
| `STREAM_KEY` | (자동생성) | OBS 스트림 키 |

### 포트 변경 예시

```bash
curl -fsSL https://raw.githubusercontent.com/NAMUORI00/mediamtx-installer/master/install-mediamtx.sh | sudo RTMP_PORT=1936 HLS_PORT=8080 bash -s -- -y
```

## 설치 후 사용법

### OBS 설정

설치 완료 후 출력되는 URL을 OBS에 입력합니다:

- **서버 URL**: `rtmp://서버IP:1935/live?user=publisher&pass=스트림키`
- **스트림 키**: (URL에 포함됨, 비워두세요)

### 시청 방법

| 방법 | URL |
|------|-----|
| VLC | `rtsp://서버IP:8554/live` |
| 브라우저 | `http://서버IP:8888/live` |

### VLC 저지연 설정

1. 도구 > 환경설정
2. 입력/코덱 > 네트워크 캐싱 = **50ms**

## 서비스 관리

```bash
# 시작
docker compose -f /opt/mediamtx/docker-compose.yml up -d

# 중지
docker compose -f /opt/mediamtx/docker-compose.yml down

# 로그 확인
docker logs -f mediamtx

# 상태 확인
docker ps | grep mediamtx
```

## 설정 파일 위치

| 파일 | 경로 |
|------|------|
| 설정 파일 | `/opt/mediamtx/mediamtx.yml` |
| Docker Compose | `/opt/mediamtx/docker-compose.yml` |
| 접속 정보 | `/opt/mediamtx/credentials.txt` |

## 시스템 요구사항

- **OS**: Ubuntu 24.04
- **메모리**: 1GB RAM (512MB 제한)
- **CPU**: 2 vCPU 권장
- **네트워크**: TCP 포트 1935, 8554, 8888, 9997

## 기능

- 스트림 키 인증 (송출만 인증, 시청은 자유)
- Low-Latency HLS 지원
- Docker 자동 설치
- UFW 방화벽 자동 설정
- 1GB RAM 환경 최적화

## 라이선스

MIT License
