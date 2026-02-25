#!/usr/bin/env bash
# ============================================================================
#  DDNS Updater — Container Entrypoint
#
#  Handles:
#    - First-run config bootstrapping (auto-copy .env.example)
#    - Credential and config validation with clear error messages
#    - Record type parsing (A, AAAA, CNAME, MX, TXT, etc.)
#    - Settings overview printed to logs on every start
#    - Daemon loop, test, and test-prop modes
# ============================================================================

set -uo pipefail

VERSION="2.0.0"
SCRIPT="/opt/ddns-updater/ddns-updater.sh"
EXAMPLE="/opt/ddns-updater/.env.example"
CONFIG_DIR="${CONFIG_DIR:-/config}"
ENV_FILE="${CONFIG_DIR}/.env"
RECORDS_DIR="${CONFIG_DIR}/records"

# Detect mode early — test modes should never enter wait loops
RUN_MODE="daemon"
case "${1:-}" in
    --test)      RUN_MODE="test" ;;
    --test-prop) RUN_MODE="test-prop" ;;
esac

# ── Helpers ────────────────────────────────────────────────────────────────

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

log_banner() { echo -e "${CYAN}${BOLD}$*${NC}"; }
log_ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
log_warn()   { echo -e "  ${YELLOW}!${NC} $*"; }
log_err()    { echo -e "  ${RED}✗${NC} $*"; }
log_info()   { echo -e "  ${DIM}·${NC} $*"; }
log_fatal()  { echo -e "\n${RED}${BOLD}FATAL:${NC} $*\n"; }

# ── Banner ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║        DDNS Updater for dns24.ch  v${VERSION}        ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ── Step 1: Ensure config directory is mounted ─────────────────────────────

if [[ ! -d "$CONFIG_DIR" ]] || [[ ! -w "$CONFIG_DIR" ]]; then
    log_fatal "Config directory not found or not writable: ${CONFIG_DIR}"
    echo "  Mount a config directory when starting the container:"
    echo ""
    echo "    docker run -v /path/to/config:/config ddns-updater"
    echo ""
    exit 1
fi

# Ensure subdirectories exist
mkdir -p "${CONFIG_DIR}/meta" "${CONFIG_DIR}/records"

# ── Step 2: Bootstrap .env on first run ────────────────────────────────────

if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$EXAMPLE" ]]; then
        cp "$EXAMPLE" "$ENV_FILE"
        echo ""
        log_banner "FIRST RUN — Config created"
        echo ""
        log_ok "Copied default config to ${ENV_FILE}"
        echo ""
        log_err "You need to edit config/.env before the updater can run:"
        echo ""
        echo "    1. Set your dns24.ch credentials:"
        echo "       DNS24_USER='your-email@example.com'"
        echo "       DNS24_PASS='your-password'"
        echo ""
        echo "    2. Create domain files in config/records/"
        echo "       Example: echo -e 'www\\nmail' > config/records/yourdomain.ch"
        echo ""
        echo "       Extended format (optional):"
        echo "         www              → A record, auto IP"
        echo "         @|AAAA           → AAAA record, auto IPv6"
        echo "         mail|CNAME|x.com → static CNAME"
        echo "         @|MX|10 mx.com   → static MX"
        echo "         @|TXT|v=spf1...  → static TXT"
        echo "         NOROOT           → skip auto root A record"
        echo ""
        echo "    3. (Optional) Add Discord webhook URLs"
        echo ""
        log_info "The container will check again in 30 seconds..."
        log_info "Waiting for configuration..."
        echo ""

        # In test mode, don't wait — just report and run
        if [[ "$RUN_MODE" != "daemon" ]]; then
            log_warn "Config has placeholder credentials — test will report this"
            echo ""
        else
            # Daemon mode: wait for user to edit config
            while true; do
                set +u
                source "$ENV_FILE" 2>/dev/null
                set -u
                if [[ "${DNS24_USER:-}" != "your-email@example.com" && -n "${DNS24_USER:-}" && \
                      "${DNS24_PASS:-}" != "your-password-here" && -n "${DNS24_PASS:-}" ]]; then
                    echo ""
                    log_ok "Credentials detected! Starting updater..."
                    echo ""
                    break
                fi
                sleep 30
                echo "[$(date '+%H:%M:%S')] Waiting for config... Edit config/.env and the container will auto-detect changes."
            done
        fi
    else
        log_fatal "No config found at ${ENV_FILE} and no example template available."
        echo "  This shouldn't happen. Rebuild the image:"
        echo "    docker-compose build --no-cache"
        exit 1
    fi
fi

# ── Step 3: Load and validate config ──────────────────────────────────────

set +u
source "$ENV_FILE" 2>/dev/null
set -u

ERRORS=0
WARNINGS=0

log_banner "Configuration Check"
echo ""

# Required: DNS24 credentials
if [[ -z "${DNS24_USER:-}" ]]; then
    log_err "DNS24_USER is not set"
    ((ERRORS++))
elif [[ "$DNS24_USER" == "your-email@example.com" ]]; then
    log_err "DNS24_USER is still the placeholder — edit config/.env"
    ((ERRORS++))
else
    log_ok "DNS24_USER: ${DNS24_USER}"
fi

if [[ -z "${DNS24_PASS:-}" ]]; then
    log_err "DNS24_PASS is not set"
    ((ERRORS++))
elif [[ "$DNS24_PASS" == "your-password-here" ]]; then
    log_err "DNS24_PASS is still the placeholder — edit config/.env"
    ((ERRORS++))
else
    local_masked=$(echo "$DNS24_PASS" | sed 's/./*/g')
    log_ok "DNS24_PASS: ${local_masked}"
fi

# Required: at least one domain record file
RECORD_COUNT=0
if [[ -d "$RECORDS_DIR" ]]; then
    for f in "$RECORDS_DIR"/*; do
        [[ -f "$f" ]] && [[ "$(basename "$f")" != ".gitkeep" ]] && ((RECORD_COUNT++)) || true
    done
fi

if [[ $RECORD_COUNT -eq 0 ]]; then
    log_err "No domain files in config/records/"
    log_info "Create files named after your domains with subdomains inside:"
    log_info "  echo -e 'www\\nmail' > config/records/yourdomain.ch"
    ((ERRORS++))
else
    log_ok "Domain files: ${RECORD_COUNT}"
    for f in "$RECORDS_DIR"/*; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == ".gitkeep" ]] && continue
        local_domain=$(basename "$f")
        local_root="@ + "
        if grep -qi "^NOROOT" "$f" 2>/dev/null; then
            local_root="NOROOT, "
        fi
        local_dyn=0 local_static=0
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            _line=$(echo "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$_line" || "$_line" == \#* ]] && continue
            [[ "${_line^^}" == "NOROOT" ]] && continue
            IFS='|' read -r _h _t _d <<< "$_line"
            _t=$(echo "${_t:-A}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
            if [[ "$_t" == "A" || "$_t" == "AAAA" ]] && [[ -z "${_d:-}" ]]; then
                ((local_dyn++)) || true
            else
                ((local_static++)) || true
            fi
        done < "$f"
        local_detail="${local_root}${local_dyn} dynamic"
        [[ $local_static -gt 0 ]] && local_detail+=", ${local_static} static"
        log_info "  ${local_domain} (${local_detail})"
    done
fi

echo ""

# Fatal if required config is missing
if [[ $ERRORS -gt 0 ]]; then
    log_fatal "${ERRORS} configuration error(s) — cannot start"
    echo "  Edit config/.env and restart the container."
    echo ""

    # In test mode, pass through to the test script (it has its own validation)
    if [[ "$RUN_MODE" != "daemon" ]]; then
        log_warn "Running ${RUN_MODE} with config errors — results will reflect issues"
        echo ""
    else
        echo "  The container will stay running and re-check every 30 seconds."
        echo ""
        while true; do
            set +u
            source "$ENV_FILE" 2>/dev/null
            set -u
            local_ok=true
            [[ -z "${DNS24_USER:-}" || "${DNS24_USER:-}" == "your-email@example.com" ]] && local_ok=false
            [[ -z "${DNS24_PASS:-}" || "${DNS24_PASS:-}" == "your-password-here" ]] && local_ok=false

            local_rc=0
            for f in "$RECORDS_DIR"/*; do [[ -f "$f" ]] && ((local_rc++)) || true; done
            [[ $local_rc -eq 0 ]] && local_ok=false

            if [[ "$local_ok" == "true" ]]; then
                echo ""
                log_ok "Configuration updated! Starting updater..."
                echo ""
                exec "$0" "$@"
            fi
            sleep 30
            echo "[$(date '+%H:%M:%S')] Waiting for valid config... (${ERRORS} errors remaining)"
        done
    fi
fi

# ── Step 4: Settings overview ──────────────────────────────────────────────

# Apply defaults for display (same logic as the script)
local_api="${DNS24_API_URL:-http://dyn.dns24.ch/update}"
local_interval="${CHECK_INTERVAL:-30}"
local_res_timeout="${RESOLVER_TIMEOUT:-5}"
local_dns_timeout="${DNS24_TIMEOUT:-10}"
local_ipv4="${FORCE_IPV4:-true}"
local_self="${SELF_HOSTED_RESOLVER:-}"
local_log="${LOG_LEVEL:-info}"
local_history="${KEEP_IP_HISTORY:-true}"
local_history_max="${IP_HISTORY_MAX_LINES:-1000}"
local_prop="${PROPAGATION_ENABLED:-true}"
local_prop_int="${PROPAGATION_INTERVAL:-30}"
local_prop_max="${PROPAGATION_MAX_ROUNDS:-10}"

# Empty = default
[[ -z "$local_interval" ]]    && local_interval=30
[[ -z "$local_res_timeout" ]] && local_res_timeout=5
[[ -z "$local_dns_timeout" ]] && local_dns_timeout=10
[[ -z "$local_history" ]]     && local_history=false
[[ -z "$local_prop" ]]        && local_prop=false
[[ -z "$local_prop_int" ]]    && local_prop_int=30
[[ -z "$local_prop_max" ]]    && local_prop_max=10

log_banner "Active Settings"
echo ""

echo -e "  ${BOLD}Credentials${NC}"
log_info "DNS24 user:          ${DNS24_USER}"
log_info "DNS24 API:           ${local_api}"
echo ""

echo -e "  ${BOLD}Timing${NC}"
log_info "Check interval:      ${local_interval}s"
log_info "Resolver timeout:    ${local_res_timeout}s"
log_info "DNS24 timeout:       ${local_dns_timeout}s"
echo ""

echo -e "  ${BOLD}IP Resolution${NC}"
if [[ -n "$local_self" ]]; then
    log_info "Self-hosted:         ${local_self}"
else
    log_info "Self-hosted:         disabled"
fi
log_info "Force IPv4:          ${local_ipv4}"

# Count public resolvers
IFS=',' read -ra _pub_res <<< "${PUBLIC_RESOLVERS:-https://ifconfig.me,https://icanhazip.com,https://api.ipify.org,https://checkip.amazonaws.com}"
log_info "Public resolvers:    ${#_pub_res[@]}"
for r in "${_pub_res[@]}"; do
    log_info "  ${r}"
done
echo ""

echo -e "  ${BOLD}Discord${NC}"
if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
    log_ok "Main webhook:        set"
else
    log_info "Main webhook:        disabled"
    ((WARNINGS++))
fi
if [[ -n "${DISCORD_WEBHOOK_PROPAGATION:-}" ]]; then
    if [[ "${DISCORD_WEBHOOK_PROPAGATION:-}" == "${DISCORD_WEBHOOK:-}" ]]; then
        log_info "Propagation webhook: same as main"
    else
        log_ok "Propagation webhook: set (separate channel)"
    fi
else
    log_info "Propagation webhook: disabled"
fi
log_info "Notify on startup:   ${DISCORD_NOTIFY_STARTUP:-true}"
log_info "Notify unchanged:    ${DISCORD_NOTIFY_UNCHANGED:-false}"
echo ""

echo -e "  ${BOLD}Propagation${NC}"
if [[ "$local_prop" == "true" ]]; then
    log_ok "Enabled"
    log_info "Interval:            ${local_prop_int}s"
    log_info "Max rounds:          ${local_prop_max}"
    log_info "Max wait:            $(( local_prop_int * local_prop_max ))s"

    IFS=',' read -ra _zones <<< "${PROPAGATION_ZONES:-Cloudflare|Anycast|1.1.1.1,Google DNS|Anycast|8.8.8.8,OpenDNS|Anycast|208.67.222.222}"
    log_info "Zones:               ${#_zones[@]}"
    for z in "${_zones[@]}"; do
        IFS='|' read -r _zl _zp _zi <<< "$z"
        log_info "  ${_zl} — ${_zp} (${_zi})"
    done
else
    log_info "Disabled"
fi
echo ""

local_ns1="${NS1:-ns1.dns24.ch}"
local_ns2="${NS2:-ns2.dns24.ch}"
local_drift="${DRIFT_CHECK_INTERVAL:-10}"
[[ -z "$local_drift" ]] && local_drift=10

echo -e "  ${BOLD}Verification${NC}"
log_info "Nameservers:         ${local_ns1}, ${local_ns2}"
log_info "Drift check:         every ${local_drift} cycles (~$(( local_drift * local_interval ))s)"
log_info "NS verification:     enabled (auto after every update)"
echo ""

echo -e "  ${BOLD}Logging${NC}"
log_info "Log level:           ${local_log}"
if [[ "$local_history" == "true" ]]; then
    local_hmax="${local_history_max}"
    [[ "$local_hmax" == "0" || -z "$local_hmax" ]] && local_hmax="unlimited"
    log_info "IP history:          on (max ${local_hmax} lines)"
else
    log_info "IP history:          off"
fi
echo ""

# Warnings summary
if [[ $WARNINGS -gt 0 ]]; then
    log_warn "${WARNINGS} warning(s) — updater will run but some features are disabled"
    echo ""
fi

# ── Step 5: Run ────────────────────────────────────────────────────────────

case "$RUN_MODE" in
    test)
        log_banner "Running test mode..."
        echo ""
        exec bash "$SCRIPT" --test
        ;;
    test-prop)
        log_banner "Running propagation test..."
        echo ""
        exec bash "$SCRIPT" --test-prop
        ;;
esac

# Daemon mode
echo -e "${GREEN}${BOLD}Starting daemon — checking every ${local_interval}s${NC}"
echo ""

# First run with startup flag
bash "$SCRIPT" --startup || echo "[$(date '+%Y-%m-%d %H:%M:%S')] Startup run had errors (will retry)"

# Loop
while true; do
    sleep "$local_interval"
    bash "$SCRIPT" || echo "[$(date '+%Y-%m-%d %H:%M:%S')] Run failed, retrying next cycle"
done
