#!/usr/bin/env bash

# Pi-hole + Unbound + Squid
# Safe uninstaller.

set -Eeuo pipefail

SCRIPT_VERSION="2.0.1"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
MANIFEST_FILE="${SCRIPT_DIR}/.pihole-unbound-manifest"

PIHOLE_DIR="${SCRIPT_DIR}/etc-pihole"
UNBOUND_DIR="${SCRIPT_DIR}/unbound"
SQUID_CONF_DIR="${SCRIPT_DIR}/squid-conf"
SQUID_CACHE_DIR="${SCRIPT_DIR}/squid-cache"
SQUID_LOG_DIR="${SCRIPT_DIR}/squid-logs"

PURGE_DATA=false
DRY_RUN=false
ASSUME_YES=false

COMPOSE_CMD=()
RUNTIME=""

COLOR_RESET=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""
COLOR_CYAN=""

if [[ -t 1 ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_BLUE=$'\033[34m'
    COLOR_CYAN=$'\033[36m'
fi

info() {
    printf '%b[%s]%b %s\n' "${COLOR_BLUE}" "INFO" "${COLOR_RESET}" "$*"
}

success() {
    printf '%b[%s]%b %s\n' "${COLOR_GREEN}" " OK " "${COLOR_RESET}" "$*"
}

warn() {
    printf '%b[%s]%b %s\n' "${COLOR_YELLOW}" "WARN" "${COLOR_RESET}" "$*"
}

error() {
    printf '%b[%s]%b %s\n' "${COLOR_RED}" "ERROR" "${COLOR_RESET}" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

usage() {
    cat <<EOF
Usage:
  ./uninstall.sh [OPTIONS]

Options:
  --purge-data    Remove persistent Pi-hole, Unbound, and Squid data.
  --dry-run       Show what would be removed without changing anything.
  --yes           Skip confirmation prompts.
  --help          Show this help message.
EOF
}

for arg in "$@"; do
    case "${arg}" in
        --purge-data) PURGE_DATA=true ;;
        --dry-run) DRY_RUN=true ;;
        --yes) ASSUME_YES=true ;;
        --help|-h) usage; exit 0 ;;
        *) usage; die "Unknown option: ${arg}" ;;
    esac
done

[[ -n "${SCRIPT_DIR}" ]] || die "SCRIPT_DIR is empty."
[[ "${SCRIPT_DIR}" != "/" ]] || die "Refusing to operate on filesystem root."
[[ -d "${SCRIPT_DIR}" ]] || die "Project directory does not exist: ${SCRIPT_DIR}"

safe_path() {
    local target="$1"
    [[ -n "${target}" ]] || return 1
    case "${target}" in
        "${SCRIPT_DIR}"/*) ;;
        *) return 1 ;;
    esac
    [[ "${target}" != "${SCRIPT_DIR}" ]] || return 1
    return 0
}

remove_path() {
    local target="$1"
    safe_path "${target}" || die "Safety check rejected path: ${target}"
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        return 0
    fi
    if [[ "${DRY_RUN}" == true ]]; then
        printf '  would remove: %s\n' "${target}"
        return 0
    fi
    rm -rf -- "${target}"
}

detect_runtime() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
            RUNTIME="docker"
            COMPOSE_CMD=(docker compose)
            return
        fi
    fi
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        if podman compose version >/dev/null 2>&1; then
            RUNTIME="podman"
            COMPOSE_CMD=(podman compose)
            return
        elif command -v podman-compose >/dev/null 2>&1 && podman-compose version >/dev/null 2>&1; then
            RUNTIME="podman"
            COMPOSE_CMD=(podman-compose)
            return
        fi
    fi
}

compose() {
    "${COMPOSE_CMD[@]}" "$@"
}

confirm() {
    [[ "${ASSUME_YES}" == true ]] && return 0
    printf '\n'
    if [[ "${PURGE_DATA}" == true ]]; then
        printf '%bWARNING:%b This will permanently remove:\n' "${COLOR_RED}" "${COLOR_RESET}"
        printf '  - Pi-hole configuration and database\n'
        printf '  - Unbound configuration\n'
        printf '  - Squid configuration, cache, and logs\n'
        printf '  - Containers and networks\n'
    else
        printf '%bThis will remove service containers and generated configuration files.%b\n' "${COLOR_YELLOW}" "${COLOR_RESET}"
        printf 'Persistent service data will be preserved.\n'
    fi
    printf '\nContinue? [y/N] '
    read -r answer
    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
        *) printf 'Cancelled.\n'; exit 0 ;;
    esac
}

stop_stack() {
    [[ -f "${COMPOSE_FILE}" ]] || { warn "docker-compose.yml not found."; return 0; }
    [[ ${#COMPOSE_CMD[@]} -gt 0 ]] || { warn "No Compose runtime found."; return 0; }
    info "Stopping Compose services..."
    if [[ "${DRY_RUN}" == true ]]; then
        printf '  would run: %s down --remove-orphans\n' "${COMPOSE_CMD[*]}"
        return 0
    fi
    local env_arg=()
    [[ -f "${ENV_FILE}" ]] && env_arg=("--env-file" "${ENV_FILE}")
    compose "${env_arg[@]}" -f "${COMPOSE_FILE}" down --remove-orphans || warn "Compose shutdown returned non-zero."
}

remove_known_containers() {
    for c in pihole unbound squid; do
        if [[ "${DRY_RUN}" == true ]]; then
            printf '  would remove container: %s\n' "$c"
            continue
        fi
        [[ "${RUNTIME}" == "docker" ]] && docker rm -f "$c" >/dev/null 2>&1 || true
        [[ "${RUNTIME}" == "podman" ]] && podman rm -f "$c" >/dev/null 2>&1 || true
    done
}

remove_known_networks() {
    local proj
    proj="$(basename "${SCRIPT_DIR}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')"
    for net in "${proj}_dns" "${proj}_proxy" "pihole-unbound_dns" "pihole-unbound_proxy"; do
        if [[ "${DRY_RUN}" == true ]]; then
            printf '  would remove network: %s\n' "$net"
            continue
        fi
        [[ "${RUNTIME}" == "docker" ]] && docker network rm "$net" >/dev/null 2>&1 || true
        [[ "${RUNTIME}" == "podman" ]] && podman network rm "$net" >/dev/null 2>&1 || true
    done
}

remove_generated_files() {
    info "Removing generated project files..."
    remove_path "${COMPOSE_FILE}"
    remove_path "${ENV_FILE}"
    if [[ "${PURGE_DATA}" == true ]]; then
        info "Removing persistent service data directories..."
        remove_path "${PIHOLE_DIR}"
        remove_path "${UNBOUND_DIR}"
        remove_path "${SQUID_CONF_DIR}"
        remove_path "${SQUID_CACHE_DIR}"
        remove_path "${SQUID_LOG_DIR}"
    else
        info "Preserving persistent service data."
        remove_path "${SQUID_CONF_DIR}"
    fi
    remove_path "${MANIFEST_FILE}"
}

main() {
    printf '\n%bPi-hole + Unbound + Squid Uninstaller%b\n' "${COLOR_CYAN}" "${COLOR_RESET}"
    printf 'Version %s\nProject directory: %s\n\n' "${SCRIPT_VERSION}" "${SCRIPT_DIR}"
    confirm
    detect_runtime
    [[ -n "${RUNTIME}" ]] && info "Container runtime: ${RUNTIME}" || warn "No active container runtime detected."
    stop_stack
    remove_known_containers
    remove_known_networks
    remove_generated_files
    printf '\n'
    if [[ "${DRY_RUN}" == true ]]; then
        success "Dry run complete. Nothing changed."
        exit 0
    fi
    success "Uninstallation complete."
    [[ "${PURGE_DATA}" != true ]] && printf '\nPersistent data preserved. Run with --purge-data to clean entirely.\n'
    printf '\n'
}

main "$@"
