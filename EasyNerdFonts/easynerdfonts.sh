#!/usr/bin/env bash

set -Eeuo pipefail

readonly APP_NAME="Linuxroom Easy Nerd Fonts Installer"
readonly APP_VERSION="1.0.0"
readonly GITHUB_API="https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest"

# sudo로 실행했을 경우 실제 사용자 계정에 설치
if [[ ${EUID} -eq 0 && -n ${SUDO_USER:-} && ${SUDO_USER} != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
else
    TARGET_USER="$(id -un)"
    TARGET_HOME="${HOME}"
fi

readonly TARGET_USER
readonly TARGET_HOME
readonly FONT_DIR="${TARGET_HOME}/.local/share/fonts/NerdFonts"

TEMP_DIR=""
RELEASE_DATA=""
RELEASE_VERSION=""

cleanup() {
    if [[ -n ${TEMP_DIR} && -d ${TEMP_DIR} ]]; then
        rm -rf -- "${TEMP_DIR}"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT TERM

show_error() {
    whiptail \
        --title "${APP_NAME}" \
        --msgbox "$1" \
        10 70
}

show_info() {
    local dialog_height

    dialog_height=$(( $(wc -l <<< "$1") + 8 ))
    (( dialog_height < 10 )) && dialog_height=10
    (( dialog_height > 22 )) && dialog_height=22

    whiptail \
        --title "${APP_NAME}" \
        --msgbox "$1" \
        "${dialog_height}" 78
}

show_yesno() {
    local dialog_height

    dialog_height=$(( $(wc -l <<< "$1") + 8 ))
    (( dialog_height < 12 )) && dialog_height=12
    (( dialog_height > 22 )) && dialog_height=22

    whiptail \
        --title "${APP_NAME}" \
        --yesno "$1" \
        "${dialog_height}" 78
}

run_as_target() {
    if [[ ${EUID} -eq 0 && ${TARGET_USER} != "root" ]]; then
        sudo -u "${TARGET_USER}" -- "$@"
    else
        "$@"
    fi
}

install_dependencies() {
    local missing=()
    local command_name

    for command_name in curl jq tar xz whiptail fc-cache; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            missing+=("${command_name}")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        return 0
    fi

    echo "필요한 패키지를 설치합니다: ${missing[*]}"

    local sudo_cmd=()

    if [[ ${EUID} -ne 0 ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "오류: 의존성 설치를 위해 sudo가 필요합니다." >&2
            echo "필요한 명령: curl jq tar xz whiptail fc-cache" >&2
            exit 1
        fi

        sudo_cmd=(sudo)
    fi

    if command -v apt-get >/dev/null 2>&1; then
        "${sudo_cmd[@]}" apt-get update
        "${sudo_cmd[@]}" apt-get install -y \
            curl jq tar xz-utils whiptail fontconfig

    elif command -v dnf >/dev/null 2>&1; then
        "${sudo_cmd[@]}" dnf install -y \
            curl jq tar xz newt fontconfig

    elif command -v yum >/dev/null 2>&1; then
        "${sudo_cmd[@]}" yum install -y \
            curl jq tar xz newt fontconfig

    elif command -v pacman >/dev/null 2>&1; then
        "${sudo_cmd[@]}" pacman -Sy --needed \
            curl jq tar xz libnewt fontconfig

    elif command -v zypper >/dev/null 2>&1; then
        "${sudo_cmd[@]}" zypper --non-interactive install \
            curl jq tar xz newt fontconfig

    elif command -v apk >/dev/null 2>&1; then
        "${sudo_cmd[@]}" apk add \
            curl jq tar xz newt fontconfig

    elif command -v xbps-install >/dev/null 2>&1; then
        "${sudo_cmd[@]}" xbps-install -Sy \
            curl jq tar xz newt fontconfig

    else
        echo "지원되는 패키지 관리자를 찾지 못했습니다." >&2
        echo "다음 명령을 직접 설치해 주세요:" >&2
        echo "curl jq tar xz whiptail fc-cache" >&2
        exit 1
    fi

    for command_name in curl jq tar xz whiptail fc-cache; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            echo "오류: ${command_name} 명령을 사용할 수 없습니다." >&2
            exit 1
        fi
    done
}

prepare_environment() {
    TEMP_DIR="$(mktemp -d)"

    if [[ -z ${TARGET_HOME} || ${TARGET_HOME} == "/" ]]; then
        echo "올바른 사용자 홈 디렉터리를 확인할 수 없습니다." >&2
        exit 1
    fi

    run_as_target mkdir -p "${FONT_DIR}"
}

load_release_data() {
    if [[ -n ${RELEASE_DATA} ]]; then
        return 0
    fi

    RELEASE_DATA="$(
        curl -fsSL \
            --retry 3 \
            --connect-timeout 15 \
            -H "Accept: application/vnd.github+json" \
            -H "User-Agent: nerd-fonts-tui-installer" \
            "${GITHUB_API}"
    )" || {
        show_error "Nerd Fonts 릴리스 정보를 가져오지 못했습니다.

인터넷 연결 또는 GitHub API 접속 상태를 확인해 주세요."
        return 1
    }

    RELEASE_VERSION="$(
        jq -r '.tag_name // empty' <<< "${RELEASE_DATA}"
    )"

    if [[ -z ${RELEASE_VERSION} ]]; then
        RELEASE_DATA=""
        show_error "최신 Nerd Fonts 버전을 확인하지 못했습니다."
        return 1
    fi
}

get_available_fonts() {
    load_release_data || return 1

    jq -r '
        .assets[]
        | select(.name | endswith(".tar.xz"))
        | select(.name != "NerdFontsSymbolsOnly.tar.xz")
        | select(.name != "NerdFonts.tar.xz")
        | [
            (.name | sub("\\.tar\\.xz$"; "")),
            .browser_download_url
          ]
        | @tsv
    ' <<< "${RELEASE_DATA}" | sort -f
}

refresh_font_cache() {
    if ! run_as_target fc-cache -f >/dev/null 2>&1; then
        show_error "폰트 캐시 갱신에 실패했습니다.

설치 또는 삭제 자체는 완료되었을 수 있습니다."
        return 1
    fi
}

install_font() {
    local font_name="$1"
    local download_url="$2"
    local archive_path="${TEMP_DIR}/${font_name}.tar.xz"
    local destination="${FONT_DIR}/${font_name}"
    local staging_dir="${TEMP_DIR}/extract-${font_name}"

    rm -rf -- "${staging_dir}"
    mkdir -p "${staging_dir}"

    if ! curl -fL \
        --retry 3 \
        --connect-timeout 15 \
        --progress-bar \
        -o "${archive_path}" \
        "${download_url}"; then
        rm -f -- "${archive_path}"
        return 1
    fi

    if ! tar -xJf "${archive_path}" -C "${staging_dir}"; then
        rm -f -- "${archive_path}"
        rm -rf -- "${staging_dir}"
        return 1
    fi

    run_as_target rm -rf -- "${destination}"
    run_as_target mkdir -p "${destination}"

    # 폰트 파일만 복사
    while IFS= read -r -d '' font_file; do
        run_as_target cp -f -- "${font_file}" "${destination}/"
    done < <(
        find "${staging_dir}" -type f \
            \( -iname "*.ttf" -o -iname "*.otf" \) \
            -print0
    )

    rm -f -- "${archive_path}"
    rm -rf -- "${staging_dir}"

    if ! find "${destination}" -maxdepth 1 -type f \
        \( -iname "*.ttf" -o -iname "*.otf" \) \
        -print -quit | grep -q .; then
        run_as_target rm -rf -- "${destination}"
        return 1
    fi
}

install_selected_fonts() {
    local -a selected_fonts=("$@")
    local available_data="$2"
}

install_fonts_from_list() {
    local list_file="$1"
    local total
    local current=0
    local success=0
    local failed=0
    local font_name
    local download_url
    local percent
    local status_file="${TEMP_DIR}/install-status"

    total="$(wc -l < "${list_file}")"

    if (( total == 0 )); then
        show_info "설치할 Nerd Font가 선택되지 않았습니다."
        return 0
    fi

    : > "${status_file}"

    while IFS=$'\t' read -r font_name download_url; do
        ((current += 1))
        percent=$((current * 100 / total))

        echo "XXX"
        echo "${percent}"
        echo "${font_name} 다운로드 및 설치 중... (${current}/${total})"
        echo "XXX"

        if install_font "${font_name}" "${download_url}" \
            >>"${status_file}" 2>&1; then
            ((success += 1))
        else
            printf '%s\n' "${font_name}" >> "${status_file}"
            ((failed += 1))
        fi
    done < "${list_file}"

    echo "XXX"
    echo "100"
    echo "폰트 캐시를 갱신하는 중..."
    echo "XXX"

    refresh_font_cache || true

    printf '%s\n%s\n' "${success}" "${failed}" \
        > "${TEMP_DIR}/install-summary"
}

show_install_result() {
    local -a summary=()
    local success
    local failed
    local status_file="${TEMP_DIR}/install-status"

    mapfile -t summary < "${TEMP_DIR}/install-summary"
    success="${summary[0]:-0}"
    failed="${summary[1]:-0}"

    if (( failed == 0 )); then
        show_info "Nerd Font 설치가 완료되었습니다.

버전: ${RELEASE_VERSION}
설치 완료: ${success}개
설치 위치:
${FONT_DIR}"
    else
        local failed_names
        failed_names="$(tail -n "${failed}" "${status_file}")"

        show_error "일부 Nerd Font 설치에 실패했습니다.

성공: ${success}개
실패: ${failed}개

실패한 폰트:
${failed_names}"
    fi
}

install_all_fonts() {
    local list_file="${TEMP_DIR}/all-fonts.tsv"

    get_available_fonts > "${list_file}" || return 1

    local font_count
    font_count="$(wc -l < "${list_file}")"

    if (( font_count == 0 )); then
        show_error "설치 가능한 Nerd Font 목록을 찾지 못했습니다."
        return 1
    fi

    if ! show_yesno "최신 Nerd Fonts ${RELEASE_VERSION}의 폰트 ${font_count}개를 모두 설치합니다.

다운로드 용량과 설치 용량이 매우 클 수 있습니다.

계속하시겠습니까?"; then
        return 0
    fi

    install_fonts_from_list "${list_file}" |
        whiptail \
            --title "${APP_NAME}" \
            --gauge "전체 Nerd Font 설치 준비 중..." \
            9 70 0

    show_install_result
}

install_recommended_fonts() {
    local available_file="${TEMP_DIR}/available-fonts.tsv"
    local recommended_file="${TEMP_DIR}/recommended-fonts.tsv"
    local font_count
    local font_name
    local recommended_name
    local recommended_names
    local -a recommended_fonts=(
        D2Coding
        JetBrainsMono
        Hack
        Noto
        FiraCode
        CascadiaCode
        Meslo
        SourceCodePro
    )

    get_available_fonts > "${available_file}" || return 1

    : > "${recommended_file}"
    while IFS=$'\t' read -r font_name _; do
        if [[ -d ${FONT_DIR}/${font_name} ]]; then
            continue
        fi

        for recommended_name in "${recommended_fonts[@]}"; do
            if [[ ${font_name} == "${recommended_name}" ]]; then
                awk -F '\t' -v recommended="${font_name}" \
                    '$1 == recommended { print $0 }' \
                    "${available_file}" >> "${recommended_file}"
                break
            fi
        done
    done < "${available_file}"

    font_count="$(wc -l < "${recommended_file}")"
    recommended_names="$(printf '%s\n' "${recommended_fonts[@]}")"

    if (( font_count == 0 )); then
        show_info "추천 Nerd Font는 모두 설치되어 있습니다.

${recommended_names}"
        return 0
    fi

    if ! show_yesno "다음 추천 Nerd Font를 설치합니다.

${recommended_names}

폰트가 이미 설치되어 있는 경우 설치를 건너뜁니다.

계속하시겠습니까?"; then
        return 0
    fi

    install_fonts_from_list "${recommended_file}" |
        whiptail \
            --title "${APP_NAME}" \
            --gauge "추천 Nerd Font 설치 준비 중..." \
            9 70 0

    show_install_result
}

select_fonts_to_install() {
    local available_file="${TEMP_DIR}/available-fonts.tsv"
    local selected_file="${TEMP_DIR}/selected-fonts.txt"
    local install_file="${TEMP_DIR}/install-fonts.tsv"
    local -a checklist_items=()
    local font_name
    local download_url

    get_available_fonts > "${available_file}" || return 1

    while IFS=$'\t' read -r font_name download_url; do
        if [[ -d ${FONT_DIR}/${font_name} ]]; then
            continue
        fi

        checklist_items+=("${font_name}" "미설치" "OFF")
    done < "${available_file}"

    if (( ${#checklist_items[@]} == 0 )); then
        show_info "설치할 수 있는 미설치 Nerd Font가 없습니다."
        return 0
    fi

    if ! whiptail \
        --title "Nerd Font 선택 설치 - ${RELEASE_VERSION}" \
        --checklist \
        "미설치 폰트만 표시됩니다. Space: 선택/해제 · 방향키: 이동 · Enter: 확인" \
        24 78 16 \
        --separate-output \
        "${checklist_items[@]}" \
        2>"${selected_file}"; then
        return 0
    fi

    : > "${install_file}"

    while IFS= read -r font_name; do
        awk -F '\t' -v selected="${font_name}" \
            '$1 == selected { print $0 }' \
            "${available_file}" >> "${install_file}"
    done < "${selected_file}"

    if [[ ! -s ${install_file} ]]; then
        show_info "설치할 Nerd Font가 선택되지 않았습니다."
        return 0
    fi

    install_fonts_from_list "${install_file}" |
        whiptail \
            --title "${APP_NAME}" \
            --gauge "선택한 Nerd Font 설치 준비 중..." \
            9 70 0

    show_install_result
}

get_installed_fonts() {
    if [[ ! -d ${FONT_DIR} ]]; then
        return 0
    fi

    find "${FONT_DIR}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' |
        sort -f
}

delete_fonts_from_list() {
    local list_file="$1"
    local total
    local current=0
    local deleted=0
    local font_name
    local percent
    local status_file="${TEMP_DIR}/delete-status"

    total="$(wc -l < "${list_file}")"
    : > "${status_file}"

    while IFS= read -r font_name; do
        [[ -n ${font_name} ]] || continue

        ((current += 1))
        percent=$((current * 100 / total))

        echo "XXX"
        echo "${percent}"
        echo "${font_name} 삭제 중... (${current}/${total})"
        echo "XXX"

        if [[ -d ${FONT_DIR}/${font_name} ]] && \
            run_as_target rm -rf -- "${FONT_DIR:?}/${font_name}"; then
            ((deleted += 1))
        fi
    done < "${list_file}"

    printf '%s\n' "${deleted}" > "${status_file}"
}

delete_all_fonts() {
    local installed_count
    local list_file="${TEMP_DIR}/delete-all.txt"

    get_installed_fonts > "${list_file}"
    installed_count="$(wc -l < "${list_file}")"

    if (( installed_count == 0 )); then
        show_info "이 프로그램으로 설치된 Nerd Font가 없습니다."
        return 0
    fi

    if ! show_yesno "이 프로그램으로 설치한 Nerd Font ${installed_count}개를 모두 삭제합니다.

삭제 경로:
${FONT_DIR}

계속하시겠습니까?"; then
        return 0
    fi

    delete_fonts_from_list "${list_file}" |
        whiptail \
            --title "${APP_NAME}" \
            --gauge "전체 Nerd Font 삭제 준비 중..." \
            9 70 0

    run_as_target mkdir -p "${FONT_DIR}"
    refresh_font_cache || true

    show_info "Nerd Font ${installed_count}개를 모두 삭제했습니다."
}

select_fonts_to_delete() {
    local selected_file="${TEMP_DIR}/delete-selected.txt"
    local -a checklist_items=()
    local font_name
    local deleted=0

    while IFS= read -r font_name; do
        [[ -n ${font_name} ]] || continue
        checklist_items+=("${font_name}" "설치됨" "OFF")
    done < <(get_installed_fonts)

    if (( ${#checklist_items[@]} == 0 )); then
        show_info "이 프로그램으로 설치된 Nerd Font가 없습니다."
        return 0
    fi

    if ! whiptail \
        --title "Nerd Font 선택 삭제" \
        --checklist \
        "삭제할 폰트을 선택해 주세요." \
        24 78 16 \
        --separate-output \
        "${checklist_items[@]}" \
        2>"${selected_file}"; then
        return 0
    fi

    if [[ ! -s ${selected_file} ]]; then
        show_info "삭제할 Nerd Font가 선택되지 않았습니다."
        return 0
    fi

    local selected_count
    selected_count="$(wc -l < "${selected_file}")"

    if ! show_yesno "선택한 Nerd Font ${selected_count}개를 삭제하시겠습니까?"; then
        return 0
    fi

    delete_fonts_from_list "${selected_file}" |
        whiptail \
            --title "${APP_NAME}" \
            --gauge "선택한 Nerd Font 삭제 준비 중..." \
            9 70 0

    deleted="$(<"${TEMP_DIR}/delete-status")"

    refresh_font_cache || true

    show_info "선택한 Nerd Font ${deleted}개를 삭제했습니다."
}

main_menu() {
    local choice

    while true; do
        choice="$(
            whiptail \
                --title "${APP_NAME} v${APP_VERSION}" \
                --menu \
                "작업을 선택해 주세요.

설치 계정: ${TARGET_USER}" \
                20 76 10 \
                "1" "Nerd Font 추천 설치" \
                "2" "Nerd Font 전체 설치" \
                "3" "Nerd Font 선택 설치" \
                "4" "Nerd Font 전체 삭제" \
                "5" "Nerd Font 선택 삭제" \
                "6" "종료" \
                3>&1 1>&2 2>&3
        )" || break

        case "${choice}" in
            1)
                install_recommended_fonts
                ;;
            2)
                install_all_fonts
                ;;
            3)
                select_fonts_to_install
                ;;
            4)
                delete_all_fonts
                ;;
            5)
                select_fonts_to_delete
                ;;
            6)
                break
                ;;
        esac
    done

    clear
    echo "${APP_NAME}를 종료합니다."
}

main() {
    install_dependencies
    prepare_environment
    main_menu
}

main "$@"