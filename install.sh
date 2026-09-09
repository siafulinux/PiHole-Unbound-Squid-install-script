#!/usr/bin/env bash

# Pi-hole + Unbound + Squid
# Cross-runtime installer for Docker and Podman.
#
# Supports:
#   - Docker + Compose plugin
#   - Podman + podman compose
#   - Podman + podman-compose
#
# The installer is designed to be:
#   - idempotent
#   - project-scoped
#   - safe to re-run
#   - safe to uninstall
#   - independent of the current working directory

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="3.0.0"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
MANIFEST_FILE="${SCRIPT_DIR}/.pihole-unbound-manifest"
LOCK_FILE="${SCRIPT_DIR}/.install.lock"

PROJECT_NAME="pihole-unbound-squid"

PIHOLE_DIR="${SCRIPT_DIR}/etc-pihole"
UNBOUND_DIR="${SCRIPT_DIR}/unbound"
SQUID_CONF_DIR="${SCRIPT_DIR}/squid-conf"
SQUID_CACHE_DIR="${SCRIPT_DIR}/squid-cache"
SQUID_LOG_DIR="${SCRIPT_DIR}/squid-logs"

COMPOSE_CMD=()
RUNTIME=""

HOST_IP=""
SERVER_IP=""
LAN_SUBNET=""
TZ=""
LOCAL_DOMAIN=""
PIHOLE_PASSWORD=""
SQUID_PORT=""

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


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

info() {
    printf '%b[%s]%b %s\n' \
        "${COLOR_BLUE}" "INFO" "${COLOR_RESET}" "$*"
}

success() {
    printf '%b[%s]%b %s\n' \
        "${COLOR_GREEN}" " OK " "${COLOR_RESET}" "$*"
}

warn() {
    printf '%b[%s]%b %s\n' \
        "${COLOR_YELLOW}" "WARN" "${COLOR_RESET}" "$*"
}

error() {
    printf '%b[%s]%b %s\n' \
        "${COLOR_RED}" "ERROR" "${COLOR_RESET}" "$*" >&2
}

die() {
    error "$*"
    exit 1
}


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

on_error() {
    local exit_code=$?

    error "Installation failed."
    error "Line: ${BASH_LINENO[0]:-unknown}"
    error "Command: ${BASH_COMMAND:-unknown}"

    exit "${exit_code}"
}

trap on_error ERR


# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
    rm -f -- "${LOCK_FILE}" 2>/dev/null || true
}

trap cleanup EXIT


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" ||
        die "Required command not found: $1"
}


is_valid_ipv4() {
    local ip="$1"
    local octet
    local octets

    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        return 1

    IFS='.' read -r -a octets <<< "${ip}"

    for octet in "${octets[@]}"; do
        (( octet >= 0 && octet <= 255 )) ||
            return 1
    done
}


is_valid_port() {
    local port="$1"

    [[ "${port}" =~ ^[0-9]+$ ]] ||
        return 1

    (( port >= 1 && port <= 65535 ))
}


is_valid_subnet() {
    local subnet="$1"

    [[ "${subnet}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
        return 1

    local ip="${subnet%/*}"
    is_valid_ipv4 "${ip}"
}


acquire_lock() {
    if ! ( set -o noclobber; : > "${LOCK_FILE}" ) 2>/dev/null; then
        die "Another installer process appears to be running:
${LOCK_FILE}"
    fi

    printf '%s\n' "$$" > "${LOCK_FILE}"
}


# ---------------------------------------------------------------------------
# Existing configuration
# ---------------------------------------------------------------------------

read_env_value() {
    local key="$1"

    [[ -f "${ENV_FILE}" ]] || return 0

    awk -F= -v key="${key}" '
        $0 !~ /^[[:space:]]*#/ &&
        $1 == key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "${ENV_FILE}"
}


load_existing_env() {
    [[ -f "${ENV_FILE}" ]] || return 0

    info "Existing configuration detected."

    TZ="$(read_env_value TZ || true)"
    SERVER_IP="$(read_env_value SERVER_IP || true)"
    LAN_SUBNET="$(read_env_value LAN_SUBNET || true)"
    LOCAL_DOMAIN="$(read_env_value LOCAL_DOMAIN || true)"
    PIHOLE_PASSWORD="$(read_env_value PIHOLE_PASSWORD || true)"
    SQUID_PORT="$(read_env_value SQUID_PORT || true)"
}


# ---------------------------------------------------------------------------
# Network detection
# ---------------------------------------------------------------------------

detect_host_network() {
    require_command ip

    local route
    local interface
    local address
    local subnet

    route="$(
        ip -4 route get 1.1.1.1 2>/dev/null |
            head -n 1 ||
            true
    )"

    [[ -n "${route}" ]] ||
        die "Unable to determine the active IPv4 route."

    interface="$(
        awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev") {
                        print $(i + 1)
                        exit
                    }
                }
            }
        ' <<< "${route}"
    )"

    [[ -n "${interface}" ]] ||
        die "Unable to determine the active network interface."

    address="$(
        ip -4 -o addr show dev "${interface}" scope global 2>/dev/null |
            awk 'NR == 1 {print $4}' ||
            true
    )"

    [[ -n "${address}" ]] ||
        die "Unable to determine the host IPv4 address."

    HOST_IP="${address%/*}"

    if [[ -z "${SERVER_IP}" ]]; then
        SERVER_IP="${HOST_IP}"
    fi

    if [[ -z "${LAN_SUBNET}" ]]; then
        subnet="$(
            ip -4 route show dev "${interface}" proto kernel scope link 2>/dev/null |
                awk 'NR == 1 {print $1}' ||
                true
        )

        LAN_SUBNET="${subnet:-192.168.0.0/16}"
    fi

    info "Network interface: ${interface}"
    info "Host IPv4:         ${HOST_IP}"
    info "Server address:    ${SERVER_IP}"
    info "LAN subnet:        ${LAN_SUBNET}"
}


# ---------------------------------------------------------------------------
# Runtime detection
# ---------------------------------------------------------------------------

detect_runtime() {

    if command_exists docker &&
       docker info >/dev/null 2>&1 &&
       docker compose version >/dev/null 2>&1; then

        RUNTIME="docker"
        COMPOSE_CMD=(docker compose)

        info "Container runtime: Docker"
        return
    fi


    if command_exists podman &&
       podman info >/dev/null 2>&1; then

        if podman compose version >/dev/null 2>&1; then
            RUNTIME="podman"
            COMPOSE_CMD=(podman compose)

            info "Container runtime: Podman"
            return
        fi

        if command_exists podman-compose &&
           podman-compose version >/dev/null 2>&1; then

            RUNTIME="podman"
            COMPOSE_CMD=(podman-compose)

            info "Container runtime: Podman"
            return
        fi
    fi

    die "No usable container runtime found.

Supported configurations:
  Docker + Compose plugin
  Podman + podman compose
  Podman + podman-compose"
}


compose() {
    "${COMPOSE_CMD[@]}" "$@"
}


# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

set_defaults() {

    if [[ -z "${TZ}" ]]; then
        if command_exists timedatectl; then
            TZ="$(
                timedatectl show \
                    --property=Timezone \
                    --value 2>/dev/null ||
                    true
            )"
        fi

        TZ="${TZ:-UTC}"
    fi

    LOCAL_DOMAIN="${LOCAL_DOMAIN:-home.arpa}"
    SQUID_PORT="${SQUID_PORT:-3128}"
}


validate_configuration() {

    is_valid_ipv4 "${SERVER_IP}" ||
        die "Invalid SERVER_IP: ${SERVER_IP}"

    is_valid_subnet "${LAN_SUBNET}" ||
        die "Invalid LAN_SUBNET: ${LAN_SUBNET}"

    is_valid_port "${SQUID_PORT}" ||
        die "Invalid SQUID_PORT: ${SQUID_PORT}"

    [[ "${LOCAL_DOMAIN}" =~ ^[a-zA-Z0-9.-]+$ ]] ||
        die "Invalid LOCAL_DOMAIN: ${LOCAL_DOMAIN}"

    [[ "${SQUID_PORT}" != "53" ]] ||
        die "SQUID_PORT cannot be 53."

    [[ "${SQUID_PORT}" != "8080" ]] ||
        die "SQUID_PORT cannot be 8080."

    [[ "${SERVER_IP}" != "0.0.0.0" ]] ||
        die "SERVER_IP must be a specific host address."

    info "Configuration validated."
}


# ---------------------------------------------------------------------------
# Password
# ---------------------------------------------------------------------------

generate_password() {

    [[ -n "${PIHOLE_PASSWORD}" ]] && return

    if command_exists openssl; then
        PIHOLE_PASSWORD="$(
            openssl rand -hex 32 |
                cut -c1-24
        )
    else
        PIHOLE_PASSWORD="$(
            od -An -N32 -tx1 /dev/urandom |
                tr -d '[:space:]' |
                cut -c1-24
        )
    fi

    [[ -n "${PIHOLE_PASSWORD}" ]] ||
        die "Unable to generate Pi-hole password."
}


# ---------------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------------

write_env() {

    umask 077

    cat > "${ENV_FILE}" <<EOF
TZ=${TZ}
SERVER_IP=${SERVER_IP}
LAN_SUBNET=${LAN_SUBNET}
LOCAL_DOMAIN=${LOCAL_DOMAIN}
PIHOLE_PASSWORD=${PIHOLE_PASSWORD}
SQUID_PORT=${SQUID_PORT}
COMPOSE_PROJECT_NAME=${PROJECT_NAME}
EOF

    chmod 600 "${ENV_FILE}"
}


# ---------------------------------------------------------------------------
# Unbound
# ---------------------------------------------------------------------------

write_unbound_config() {

    mkdir -p "${UNBOUND_DIR}"

    cat > "${UNBOUND_DIR}/unbound.conf" <<EOF
server:
    verbosity: 1

    interface: 0.0.0.0
    port: 5335

    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    auto-trust-anchor-file: "/var/lib/unbound/root.key"

    hide-identity: yes
    hide-version: yes

    qname-minimisation: yes

    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes

    use-caps-for-id: yes

    prefetch: yes
    prefetch-key: yes

    cache-min-ttl: 3600
    cache-max-ttl: 86400

    access-control: 127.0.0.0/8 allow
    access-control: 10.0.0.0/8 allow
    access-control: 172.16.0.0/12 allow
    access-control: 192.168.0.0/16 allow
    access-control: 169.254.0.0/16 allow
    access-control: 0.0.0.0/0 refuse

    rrset-roundrobin: yes
EOF
}


# ---------------------------------------------------------------------------
# Squid
# ---------------------------------------------------------------------------

write_squid_config() {

    mkdir -p \
        "${SQUID_CONF_DIR}" \
        "${SQUID_CACHE_DIR}" \
        "${SQUID_LOG_DIR}"

    cat > "${SQUID_CONF_DIR}/squid.conf" <<EOF
http_port 3128

visible_hostname pihole-unbound-squid

cache_mem 64 MB
maximum_object_size 50 MB

cache_dir ufs /var/spool/squid 100 16 256

access_log stdio:/var/log/squid/access.log
cache_log /var/log/squid/cache.log

acl localnet src ${LAN_SUBNET}

http_access allow localnet
http_access deny all

via off
forwarded_for delete

request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Cache-Control deny all

reply_header_access Server deny all
reply_header_access Via deny all
EOF
}


# ---------------------------------------------------------------------------
# Compose
# ---------------------------------------------------------------------------

write_compose() {

    cat > "${COMPOSE_FILE}" <<'EOF'
services:

  pihole:
    image: pihole/pihole:latest
    container_name: pihole-unbound-squid-pihole
    hostname: pihole

    environment:
      TZ: ${TZ}
      FTLCONF_webserver_api_password: ${PIHOLE_PASSWORD}
      FTLCONF_dns_upstreams: "unbound#5335"
      FTLCONF_dns_listeningMode: "ALL"
      FTLCONF_dns_domain: ${LOCAL_DOMAIN}

    volumes:
      - ./etc-pihole:/etc/pihole

    ports:
      - "${SERVER_IP}:53:53/tcp"
      - "${SERVER_IP}:53:53/udp"
      - "${SERVER_IP}:8080:80/tcp"

    depends_on:
      - unbound

    restart: unless-stopped

    networks:
      - dns
      - proxy

    labels:
      com.pihole-unbound-squid.project: "pihole-unbound-squid"
      com.pihole-unbound-squid.service: "pihole"


  unbound:
    image: alpinelinux/unbound:latest
    container_name: pihole-unbound-squid-unbound
    hostname: unbound

    volumes:
      - ./unbound/unbound.conf:/etc/unbound/unbound.conf:ro

    expose:
      - "5335/tcp"
      - "5335/udp"

    command:
      - unbound
      - -d
      - -c
      - /etc/unbound/unbound.conf

    restart: unless-stopped

    networks:
      - dns

    labels:
      com.pihole-unbound-squid.project: "pihole-unbound-squid"
      com.pihole-unbound-squid.service: "unbound"


  squid:
    image: ubuntu/squid:latest
    container_name: pihole-unbound-squid-squid
    hostname: squid

    environment:
      TZ: ${TZ}

    ports:
      - "${SERVER_IP}:${SQUID_PORT}:3128"

    volumes:
      - ./squid-conf/squid.conf:/etc/squid/squid.conf:ro
      - ./squid-cache:/var/spool/squid
      - ./squid-logs:/var/log/squid

    restart: unless-stopped

    networks:
      - proxy

    labels:
      com.pihole-unbound-squid.project: "pihole-unbound-squid"
      com.pihole-unbound-squid.service: "squid"


networks:

  dns:
    name: pihole-unbound-squid-dns
    driver: bridge

  proxy:
    name: pihole-unbound-squid-proxy
    driver: bridge
EOF
}


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

write_manifest() {

    cat > "${MANIFEST_FILE}" <<EOF
# Pi-hole + Unbound + Squid
# Installer version: ${SCRIPT_VERSION}
# Project: ${PROJECT_NAME}

etc-pihole
unbound
squid-conf
squid-cache
squid-logs
.env
docker-compose.yml
.pihole-unbound-manifest
EOF

    chmod 600 "${MANIFEST_FILE}"
}


# ---------------------------------------------------------------------------
# Directory preparation
# ---------------------------------------------------------------------------

prepare_directories() {

    mkdir -p \
        "${PIHOLE_DIR}" \
        "${UNBOUND_DIR}" \
        "${SQUID_CONF_DIR}" \
        "${SQUID_CACHE_DIR}" \
        "${SQUID_LOG_DIR}"

    chmod 700 \
        "${PIHOLE_DIR}" \
        "${UNBOUND_DIR}" \
        "${SQUID_CONF_DIR}" \
        "${SQUID_CACHE_DIR}" \
        "${SQUID_LOG_DIR}"
}


# ---------------------------------------------------------------------------
# Compose validation
# ---------------------------------------------------------------------------

validate_compose() {

    info "Validating Compose configuration..."

    compose \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        config >/dev/null

    success "Compose configuration is valid."
}


# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

deploy_stack() {

    info "Pulling container images..."
    compose \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        pull

    info "Starting services..."
    compose \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        up -d --remove-orphans

    success "Services started."
}


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

show_summary() {

    printf '\n'
    printf '%bInstallation complete%b\n' \
        "${COLOR_GREEN}" "${COLOR_RESET}"

    printf '\n'
    printf '  Pi-hole:  http://%s:8080/admin/\n' "${SERVER_IP}"
    printf '  DNS:      %s:53\n' "${SERVER_IP}"
    printf '  Squid:    %s:%s\n' "${SERVER_IP}" "${SQUID_PORT}"
    printf '  Domain:   %s\n' "${LOCAL_DOMAIN}"
    printf '  Runtime:  %s\n' "${RUNTIME}"
    printf '  Project:  %s\n' "${PROJECT_NAME}"

    printf '\n'
    printf '%bPi-hole admin password:%b %s\n' \
        "${COLOR_CYAN}" "${COLOR_RESET}" "${PIHOLE_PASSWORD}"

    printf '\n'
    printf 'Configuration:\n'
    printf '  %s\n' "${ENV_FILE}"

    printf '\n'
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {

    printf '\n'
    printf '%bPi-hole + Unbound + Squid%b\n' \
        "${COLOR_CYAN}" "${COLOR_RESET}"
    printf 'Installer version %s\n\n' "${SCRIPT_VERSION}"

    require_command mkdir
    require_command awk
    require_command cut
    require_command ip
    require_command od
    require_command tr

    acquire_lock

    load_existing_env
    set_defaults

    detect_host_network
    validate_configuration

    generate_password
    detect_runtime

    prepare_directories

    write_env
    write_unbound_config
    write_squid_config
    write_compose
    write_manifest

    validate_compose
    deploy_stack

    show_summary
}


main "$@"
