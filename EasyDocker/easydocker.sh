#!/usr/bin/env bash

set -Eeuo pipefail

TITLE="Linuxroom 쉬운 도커 설치 스크립트"
BACKTITLE="Linuxroom.net"
VERSION="260908"

PORTAINER_CONTAINER="portainer"
PORTAINER_VOLUME="portainer_data"
PORTAINER_PORT="9443"

msg() {
    whiptail \
        --title "$TITLE" \
        --msgbox "$1" \
        20 90
}

error_msg() {
    whiptail \
        --title "$TITLE - ERROR" \
        --msgbox "$1" \
        20 90
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo
        echo "이 스크립트는 root 권한으로 실행해야 합니다."
        echo
        echo "sudo $0"
        echo
        exit 1
    fi
}

get_real_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        REAL_USER="${SUDO_USER}"
    else
        REAL_USER=""
    fi
}

install_whiptail() {
    if command -v whiptail >/dev/null 2>&1; then
        return
    fi

    echo "whiptail을 설치합니다..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y newt

    elif command -v yum >/dev/null 2>&1; then
        yum install -y newt

    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm libnewt

    elif command -v apk >/dev/null 2>&1; then
        apk add newt

    else
        echo "whiptail을 자동으로 설치할 수 없습니다."
        exit 1
    fi
}

install_curl() {
    if command -v curl >/dev/null 2>&1; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl

    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl

    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm curl

    elif command -v apk >/dev/null 2>&1; then
        apk add curl

    else
        error_msg "curl을 자동으로 설치할 수 없습니다."
        return 1
    fi
}

start_docker() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true

    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
    fi
}

add_docker_group() {
    get_real_user

    if [[ -z "${REAL_USER}" ]]; then
        return
    fi

    if ! getent group docker >/dev/null 2>&1; then
        groupadd docker
    fi

    if id -nG "${REAL_USER}" | grep -qw docker; then
        return
    fi

    usermod -aG docker "${REAL_USER}"
}

install_compose() {
    if docker compose version >/dev/null 2>&1; then
        return
    fi

    echo
    echo "Docker Compose Plugin 설치 중..."
    echo

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
        yum install -y docker-compose-plugin
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm docker-compose
    else
        error_msg "Docker Compose Plugin을 자동 설치할 수 없는 배포판입니다."
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        error_msg "Docker Compose 설치 확인에 실패했습니다."
        return 1
    fi
}

install_docker() {
    start_docker
    if command -v docker >/dev/null 2>&1 &&
       docker info >/dev/null 2>&1
    then
        if ! whiptail \
            --title "$TITLE" \
            --yesno "Docker가 이미 설치되어 있습니다. Docker Compose와 docker 그룹 설정을 확인하시겠습니까?" \
            13 65
        then
            return
        fi
        install_compose
        add_docker_group
    else
        if ! whiptail \
            --title "$TITLE" \
            --yesno "Docker를 설치하시겠습니까? 
다음 항목이 자동으로 설치 및 설정됩니다.

• Docker Engine
• Docker Compose 플러그인
• Docker 서비스 자동 시작
• 현재 사용자를 docker 그룹에 추가" \
            17 68
        then
            return
        fi

        clear
        echo
        echo "=========================================="
        echo " Linuxroom.net Docker Installer"
        echo "=========================================="
        echo
        echo "Docker Engine 설치 중..."
        echo

        if command -v pacman >/dev/null 2>&1; then
            pacman -Syu --noconfirm docker docker-compose
        else
            install_curl
            TEMP_SCRIPT="$(mktemp)"

            if ! curl -fsSL https://get.docker.com -o "${TEMP_SCRIPT}"; then
                rm -f "${TEMP_SCRIPT}"
                error_msg "Docker 설치 스크립트를 다운로드하지 못했습니다."
                return 1
            fi

            if ! sh "${TEMP_SCRIPT}"; then
                rm -f "${TEMP_SCRIPT}"
                error_msg "Docker 설치 중 오류가 발생했습니다."
                return 1
            fi

            rm -f "${TEMP_SCRIPT}"
        fi

        start_docker
        install_compose
        add_docker_group
    fi

    DOCKER_VERSION="$(
        docker --version 2>/dev/null ||
        echo "확인 실패"
    )"

    COMPOSE_VERSION="$(
        docker compose version 2>/dev/null ||
        echo "확인 실패"
    )"

    get_real_user

    MESSAGE="Docker 설치 및 설정이 완료되었습니다.

Docker 버전 : ${DOCKER_VERSION}

Docker Compose 버전 : ${COMPOSE_VERSION}"

    if [[ -n "${REAL_USER}" ]]; then
        MESSAGE="${MESSAGE}

사용자 '${REAL_USER}'를 docker 그룹에 추가했습니다.
그룹 권한은 다음 로그인부터 적용됩니다.

바로 적용하려면 newgrp docker 명령을 실행하세요."
    fi
    msg "${MESSAGE}"
}

install_portainer() {
    start_docker
    if ! command -v docker >/dev/null 2>&1 ||
       ! docker info >/dev/null 2>&1
    then
        error_msg "Docker가 설치되어 있지 않거나 실행 중이 아닙니다.

먼저 Docker를 설치하고 서비스를 시작해주세요."
        return
    fi

    if docker ps -a \
        --format '{{.Names}}' \
        2>/dev/null |
        grep -qx "${PORTAINER_CONTAINER}"
    then
        if docker ps \
            --format '{{.Names}}' |
            grep -qx "${PORTAINER_CONTAINER}"
        then
            msg "Portainer가 이미 설치되어 있으며 실행 중입니다."
            return
        else
            if whiptail \
                --title "$TITLE" \
                --yesno "Portainer가 설치되어 있지만 중지되어 있습니다. Portainer를 시작하시겠습니까?" \
                12 65
            then
                docker start "${PORTAINER_CONTAINER}"
                msg "Portainer를 시작했습니다."
            fi
            return
        fi
    fi

    if ! whiptail \
        --title "$TITLE" \
        --yesno "Portainer CE를 설치하시겠습니까?

HTTPS 관리 포트:
${PORTAINER_PORT}" \
        14 65
    then
        return
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl reset-failed docker.service containerd.service 2>/dev/null || true

        if ! systemctl restart containerd; then
            error_msg "containerd 서비스를 재시작하지 못했습니다."
            return 1
        fi

        if ! systemctl restart docker; then
            error_msg "Docker 서비스를 재시작하지 못했습니다.

systemctl status docker.service
journalctl -xeu docker.service"
            return 1
        fi
    fi

    docker image rm -f "portainer/portainer-ce:latest" 2>/dev/null || true
    clear

    echo
    echo "=========================================="
    echo " Portainer CE 설치"
    echo "=========================================="
    echo

    docker volume create "${PORTAINER_VOLUME}" >/dev/null
    if ! docker run -d \
        --name "${PORTAINER_CONTAINER}" \
        --restart=always \
        -p "${PORTAINER_PORT}:9443" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${PORTAINER_VOLUME}:/data" \
        portainer/portainer-ce:latest >/dev/null
    then
        error_msg "Portainer 설치에 실패했습니다."
        return 1
    fi

    SETUP_TOKEN=""
    echo
    echo "=========================================="
    echo " Portainer CE Setup Token 확인 중..."
    echo "=========================================="
    echo

    for _ in {1..15}; do
        SETUP_TOKEN="$(
            docker logs "${PORTAINER_CONTAINER}" 2>&1 |
            sed -nE 's/.*setup_token=([^[:space:]]+).*/\1/p' |
            tail -n 1
        )"

        if [[ -n "${SETUP_TOKEN}" ]]; then
            break
        fi

        sleep 1
    done

    if [[ -n "${SETUP_TOKEN}" ]]; then
        get_real_user

        if [[ -n "${REAL_USER}" ]]; then
            TOKEN_FILE="/home/${REAL_USER}/portainer_token.txt"
        else
            TOKEN_FILE="/root/portainer_token.txt"
        fi

        if ! printf '%s\n' "${SETUP_TOKEN}" > "${TOKEN_FILE}"; then
            error_msg "Setup Token 파일 저장에 실패했습니다.

저장 경로:
${TOKEN_FILE}"
            return 1
        fi

        chmod 600 "${TOKEN_FILE}"

        msg "Portainer 설치가 완료되었습니다.

관리자 계정 설정:
https://127.0.0.1:${PORTAINER_PORT}

위 주소에 접속한 뒤 아래 Setup Token을 입력하세요.

${SETUP_TOKEN}

토큰 텍스트는 다음 파일에도 저장되었습니다. 보안을 위해 설정이 끝난 후 반드시 제거해주세요.
${TOKEN_FILE}"
    else
        msg "Portainer 설치가 완료되었습니다.

관리자 계정 설정:
https://127.0.0.1:${PORTAINER_PORT}

Setup Token을 자동으로 추출하지 못했습니다.
다음 명령으로 확인하세요:

docker logs ${PORTAINER_CONTAINER}"
    fi
}

docker_status() {
    if ! command -v docker >/dev/null 2>&1; then

        msg "Docker가 설치되어 있지 않습니다."
        return
    fi

    if ! DOCKER_VERSION="$(docker --version 2>/dev/null)" ||
       [[ -z "${DOCKER_VERSION}" ]]; then
        msg "Docker가 설치되어 있지 않습니다."
        return
    fi

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_VERSION="$(docker compose version)"
    else
        COMPOSE_VERSION="설치되지 않음"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        SERVICE_STATUS="$(
            systemctl is-active docker 2>/dev/null ||
            echo "inactive"
        )"
    else

        SERVICE_STATUS="확인 불가"
    fi

    CONTAINERS="$(
        docker ps \
            --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
            2>/dev/null ||
        true
    )"

    if [[ -z "${CONTAINERS}" ]]; then
        CONTAINERS="실행 중인 컨테이너가 없습니다."
    fi

    whiptail \
        --title "$TITLE" \
        --scrolltext \
        --msgbox "Docker Service:
${SERVICE_STATUS}

Docker:
${DOCKER_VERSION}

Docker Compose:
${COMPOSE_VERSION}

실행 중인 컨테이너:

${CONTAINERS}" \
        25 95
}

remove_docker() {
    start_docker

    if ! command -v docker >/dev/null 2>&1 ||
       ! docker info >/dev/null 2>&1
    then
        msg "Docker가 설치되어 있지 않습니다."
        return
    fi

    CHOICE=$(whiptail \
        --title "$TITLE" \
        --menu "Docker 제거 방법을 선택하세요." \
        18 72 5 \
        "1" "Docker 패키지만 제거 (데이터 유지)" \
        "2" "Docker + 모든 컨테이너/이미지/볼륨 제거" \
        "0" "취소" \
        3>&1 1>&2 2>&3) || return

    case "${CHOICE}" in
        1)
            if ! whiptail \
                --title "$TITLE" \
                --yesno "Docker를 제거하시겠습니까?
컨테이너, 이미지 및 볼륨 데이터는 유지합니다." \
                13 65
            then
                return
            fi
            ;;

        2)
            if ! whiptail \
                --title "$TITLE - WARNING" \
                --yesno "경고!

Docker 및 다음 데이터가 모두 삭제됩니다.

• 모든 컨테이너
• 모든 이미지
• 모든 Docker 볼륨
• /var/lib/docker
• /var/lib/containerd

이 작업은 되돌릴 수 없습니다.

정말 삭제하시겠습니까?" \
                19 70
            then
                return
            fi
            ;;

        0)
            return
            ;;

    esac
    clear

    echo
    echo "Docker 제거 중..."
    echo

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop docker 2>/dev/null || true
        systemctl stop docker.socket 2>/dev/null || true
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin \
            docker-ce-rootless-extras \
            2>/dev/null || true

        apt-get autoremove -y || true

    elif command -v dnf >/dev/null 2>&1; then

        dnf remove -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin \
            docker-ce-rootless-extras \
            || true

    elif command -v yum >/dev/null 2>&1; then
        yum remove -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin \
            docker-ce-rootless-extras \
            || true

    elif command -v pacman >/dev/null 2>&1; then
        pacman -Rns --noconfirm docker docker-compose || true

    else
        error_msg "현재 배포판에서는 Docker 자동 제거를 지원하지 않습니다."
        return
    fi

    if [[ "${CHOICE}" == "2" ]]; then
        rm -rf /var/lib/docker
        rm -rf /var/lib/containerd
    fi

    msg "Docker 제거가 완료되었습니다."
}

remove_portainer() {
    if ! command -v docker >/dev/null 2>&1; then
        msg "Docker가 설치되어 있지 않습니다."
        return
    fi

    if ! docker ps -a \
        --format '{{.Names}}' |
        grep -qx "${PORTAINER_CONTAINER}"
    then
        msg "Portainer가 설치되어 있지 않습니다."
        return
    fi

    CHOICE=$(whiptail \
        --title "$TITLE" \
        --menu "Portainer 제거 방법을 선택하세요." \
        17 70 4 \
        "1" "Portainer만 제거 (설정 유지)" \
        "2" "Portainer + 설정 데이터 제거" \
        "0" "취소" \
        3>&1 1>&2 2>&3) || return

    case "${CHOICE}" in
        1)
            docker rm -f "${PORTAINER_CONTAINER}"
            msg "Portainer를 제거했습니다.

설정 데이터는 유지됩니다.

Docker Volume:
${PORTAINER_VOLUME}"

            ;;
        2)

            if ! whiptail \
                --title "$TITLE - WARNING" \
                --yesno "Portainer 설정 데이터까지 모두 삭제하시겠습니까?

이 작업은 되돌릴 수 없습니다." \
                13 65
            then
                return
            fi

            docker rm -f \
                "${PORTAINER_CONTAINER}" \
                2>/dev/null || true

            docker volume rm \
                "${PORTAINER_VOLUME}" \
                2>/dev/null || true

            msg "Portainer와 설정 데이터를 모두 제거했습니다."
            ;;

        0)
            return
            ;;
    esac
}

get_status_header() {
    # Docker
    if DOCKER_VER="$(docker --version 2>/dev/null)" &&
       [[ -n "${DOCKER_VER}" ]]; then
        DOCKER_STATE="● Installed   ${DOCKER_VER}"

    else
        DOCKER_STATE="○ Not Installed"
    fi

    # Compose
    if command -v docker >/dev/null 2>&1 &&
       docker compose version >/dev/null 2>&1
    then
        COMPOSE_VER="$(
            docker compose version \
                --short \
                2>/dev/null ||
            echo "Unknown"
        )"
        COMPOSE_STATE="● Installed   ${COMPOSE_VER}"
    else
        COMPOSE_STATE="○ Not Installed"
    fi

    # Portainer
    if command -v docker >/dev/null 2>&1 &&
       docker ps -a \
            --format '{{.Names}}' \
            2>/dev/null |
            grep -qx "${PORTAINER_CONTAINER}"
    then
        PORTAINER_RUNNING="$(
            docker inspect \
                --format '{{.State.Running}}' \
                "${PORTAINER_CONTAINER}" \
                2>/dev/null ||
            echo "false"
        )"

        if [[ "${PORTAINER_RUNNING}" == "true" ]]; then
            PORTAINER_STATE="● Running"
        else
            PORTAINER_STATE="● Stopped"
        fi
    else
        PORTAINER_STATE="○ Not Installed"
    fi

    printf \
"Docker      %s
Compose     %s
Portainer   %s" \
        "${DOCKER_STATE}" \
        "${COMPOSE_STATE}" \
        "${PORTAINER_STATE}"
}

main_menu() {
    while true; do
        STATUS_HEADER="$(get_status_header)"

        CHOICE=$(whiptail \
            --title "${TITLE} v${VERSION}" \
            --backtitle "${BACKTITLE}" \
            --menu "${STATUS_HEADER}

────────────────────────────────────────

원하는 작업을 선택하세요." \
            25 76 10 \
            "1" "Docker 설치" \
            "2" "Portainer 설치" \
            "3" "Docker 상태 확인" \
            "4" "Docker 제거" \
            "5" "Portainer 제거" \
            "0" "종료" \
            3>&1 1>&2 2>&3) || {

                clear
                exit 0
            }

        case "${CHOICE}" in
            1)
                install_docker
                ;;
            2)
                install_portainer
                ;;
            3)
                docker_status
                ;;
            4)
                remove_docker
                ;;
            5)
                remove_portainer
                ;;
            0)
                clear

                echo
                echo "Linuxroom 쉬운 도커 설치 스크립트를 종료합니다."
                echo

                exit 0
                ;;

        esac

    done
}

check_root
install_whiptail
main_menu