#!/usr/bin/env bash
# ============================================================================
#  DDNS Updater for dns24.ch
#
#  Features:
#    - Multi-type DNS records (A, AAAA, CNAME, MX, TXT, CAA, SPF, SRV, etc.)
#    - NS verification via ns1/ns2.dns24.ch after every update
#    - Retry failed records, verify unconfirmed records each cycle
#    - Outage detection with escalating Discord alerts
#    - Periodic drift detection against authoritative NS
#    - IPv4 + IPv6 dual-stack support
#    - Discord notifications and global propagation tracking
#
#  Usage:
#    ./ddns-updater.sh              Normal run
#    ./ddns-updater.sh --test       Full test — validates everything, updates nothing
#    ./ddns-updater.sh --test-prop  Propagation snapshot only
#    ./ddns-updater.sh --startup    First run after container boot
#
#  Record file format (config/records/example.ch):
#    www                    → A record, dynamic IP (backward compatible)
#    @|A                    → root A record, dynamic IP
#    www|AAAA               → AAAA record, dynamic IPv6
#    mail|CNAME|target.com  → static CNAME
#    @|MX|10 mail.host.com  → static MX
#    @|TXT|v=spf1 ...       → static TXT
#    NOROOT                 → skip auto-added root A record
# ============================================================================

set -uo pipefail

# ── Mode ───────────────────────────────────────────────────────────────────
TEST_MODE=false
TEST_PROP_ONLY=false
STARTUP_RUN="${STARTUP_RUN:-false}"

case "${1:-}" in
    --test)       TEST_MODE=true ;;
    --test-prop)  TEST_MODE=true; TEST_PROP_ONLY=true ;;
    --startup)    STARTUP_RUN=true ;;
esac

# ── Paths ──────────────────────────────────────────────────────────────────
CONFIG_DIR="${CONFIG_DIR:-/config}"
ENV_FILE="${CONFIG_DIR}/.env"
META_DIR="${CONFIG_DIR}/meta"
RECORDS_DIR="${CONFIG_DIR}/records"
IP_FILE="${META_DIR}/ipholder.txt"
IP6_FILE="${META_DIR}/ipholder_v6.txt"
HISTORY_FILE="${META_DIR}/iphistory.txt"
PENDING_FILE="${META_DIR}/pending.list"
OUTAGE_FILE="${META_DIR}/outage_counter"
CYCLE_FILE="${META_DIR}/cycle_counter"

# ── Load config ────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    echo "FATAL: Missing ${ENV_FILE}"
    exit 1
fi

set +u
# shellcheck source=/dev/null
source "$ENV_FILE"
set -u

# ── Validate required vars ─────────────────────────────────────────────────
for var in DNS24_USER DNS24_PASS; do
    if [[ -z "${!var:-}" ]]; then
        echo "FATAL: ${var} not set in ${ENV_FILE}"
        exit 1
    fi
done

# Discord is optional
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
DISCORD_ENABLED=false
[[ -n "$DISCORD_WEBHOOK" ]] && DISCORD_ENABLED=true

# ── Apply defaults ─────────────────────────────────────────────────────────
DNS24_API_URL="${DNS24_API_URL:-http://dyn.dns24.ch/update}"
DISCORD_WEBHOOK_PROPAGATION="${DISCORD_WEBHOOK_PROPAGATION:-$DISCORD_WEBHOOK}"
DISCORD_NOTIFY_UNCHANGED="${DISCORD_NOTIFY_UNCHANGED:-false}"
DISCORD_NOTIFY_STARTUP="${DISCORD_NOTIFY_STARTUP:-true}"
DISCORD_PROP_ENABLED=false
[[ -n "$DISCORD_WEBHOOK_PROPAGATION" ]] && DISCORD_PROP_ENABLED=true

CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
RESOLVER_TIMEOUT="${RESOLVER_TIMEOUT:-5}"
DNS24_TIMEOUT="${DNS24_TIMEOUT:-10}"
SELF_HOSTED_RESOLVER="${SELF_HOSTED_RESOLVER:-}"
FORCE_IPV4="${FORCE_IPV4:-true}"
PROPAGATION_ENABLED="${PROPAGATION_ENABLED:-true}"
PROPAGATION_INTERVAL="${PROPAGATION_INTERVAL:-30}"
PROPAGATION_MAX_ROUNDS="${PROPAGATION_MAX_ROUNDS:-10}"
LOG_LEVEL="${LOG_LEVEL:-info}"
KEEP_IP_HISTORY="${KEEP_IP_HISTORY:-true}"
IP_HISTORY_MAX_LINES="${IP_HISTORY_MAX_LINES:-1000}"
DRIFT_CHECK_INTERVAL="${DRIFT_CHECK_INTERVAL:-10}"
NS1="${NS1:-ns1.dns24.ch}"
NS2="${NS2:-ns2.dns24.ch}"

# Treat empty as defaults
[[ -z "$CHECK_INTERVAL" ]]       && CHECK_INTERVAL=30
[[ -z "$RESOLVER_TIMEOUT" ]]     && RESOLVER_TIMEOUT=5
[[ -z "$DNS24_TIMEOUT" ]]        && DNS24_TIMEOUT=10
[[ -z "$PROPAGATION_INTERVAL" ]] && PROPAGATION_INTERVAL=30
[[ -z "$PROPAGATION_MAX_ROUNDS" ]] && PROPAGATION_MAX_ROUNDS=10
[[ -z "$KEEP_IP_HISTORY" ]]      && KEEP_IP_HISTORY=false
[[ -z "$IP_HISTORY_MAX_LINES" ]] && IP_HISTORY_MAX_LINES=0
[[ -z "$PROPAGATION_ENABLED" ]]  && PROPAGATION_ENABLED=false
[[ -z "$DISCORD_NOTIFY_UNCHANGED" ]] && DISCORD_NOTIFY_UNCHANGED=false
[[ -z "$DISCORD_NOTIFY_STARTUP" ]]   && DISCORD_NOTIFY_STARTUP=false
[[ -z "$DRIFT_CHECK_INTERVAL" ]] && DRIFT_CHECK_INTERVAL=10

IFS=',' read -ra PUBLIC_RESOLVER_LIST <<< "${PUBLIC_RESOLVERS:-https://ifconfig.me,https://icanhazip.com,https://api.ipify.org,https://checkip.amazonaws.com}"
IFS=',' read -ra PROP_ZONE_LIST <<< "${PROPAGATION_ZONES:-Cloudflare|Anycast|1.1.1.1,Google DNS|Anycast|8.8.8.8,OpenDNS|Anycast|208.67.222.222}"

IP_RESOLVERS=()
[[ -n "$SELF_HOSTED_RESOLVER" ]] && IP_RESOLVERS+=("$SELF_HOSTED_RESOLVER")
IP_RESOLVERS+=("${PUBLIC_RESOLVER_LIST[@]}")

CURL_IP_FLAG=""
[[ "$FORCE_IPV4" == "true" ]] && CURL_IP_FLAG="-4"

# ── Ensure directories / files ─────────────────────────────────────────────
mkdir -p "$META_DIR" "$RECORDS_DIR"
touch "$IP_FILE"
[[ "$KEEP_IP_HISTORY" == "true" ]] && touch "$HISTORY_FILE"
touch "$PENDING_FILE"
[[ -f "$OUTAGE_FILE" ]] || echo "0" > "$OUTAGE_FILE"
[[ -f "$CYCLE_FILE" ]]  || echo "0" > "$CYCLE_FILE"

# ══════════════════════════════════════════════════════════════════════════
#  LOGGING
# ══════════════════════════════════════════════════════════════════════════

log_ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')]"; }
log_info()  { [[ "$LOG_LEVEL" == "info" ]] && echo "$(log_ts) INFO  $*" || true; }
log_warn()  { [[ "$LOG_LEVEL" =~ ^(info|warn)$ ]] && echo "$(log_ts) WARN  $*" || true; }
log_error() { echo "$(log_ts) ERROR $*"; }

# ══════════════════════════════════════════════════════════════════════════
#  IP RESOLUTION
# ══════════════════════════════════════════════════════════════════════════

is_valid_ipv4() {
    local ip
    ip=$(echo "$1" | tr -d '[:space:]')
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

is_valid_ipv6() {
    local ip
    ip=$(echo "$1" | tr -d '[:space:]')
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]
}

resolve_ip() {
    local source="$1" flag="${2:-}"
    local result
    result=$(curl ${flag:+"$flag"} -s --max-time "$RESOLVER_TIMEOUT" "$source" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$flag" && "$flag" == "-6" ]]; then
        is_valid_ipv6 "$result" && echo "$result"
    else
        is_valid_ipv4 "$result" && echo "$result"
    fi
}

IP_SOURCE="" IP_SELF="" IP_PUBLIC=""

get_current_ip() {
    local self_hosted_ip="" public_ip=""
    local _ip_result_file="${META_DIR}/.ip_result"

    if [[ -n "$SELF_HOSTED_RESOLVER" ]]; then
        self_hosted_ip=$(resolve_ip "$SELF_HOSTED_RESOLVER" "$CURL_IP_FLAG")
    fi

    for resolver in "${PUBLIC_RESOLVER_LIST[@]}"; do
        public_ip=$(resolve_ip "$resolver" "$CURL_IP_FLAG")
        [[ -n "$public_ip" ]] && break
    done

    _write_ip_result() {
        cat > "$_ip_result_file" <<-IPEOF
IP_SOURCE="$1"
IP_SELF="$2"
IP_PUBLIC="$3"
IPEOF
    }

    if [[ -n "$self_hosted_ip" && -n "$public_ip" ]]; then
        if [[ "$self_hosted_ip" == "$public_ip" ]]; then
            echo "$self_hosted_ip"
            _write_ip_result "self-hosted (confirmed by public)" "$self_hosted_ip" "$public_ip"
        else
            echo "$public_ip"
            _write_ip_result "MISMATCH self=${self_hosted_ip} pub=${public_ip} using public" "$self_hosted_ip" "$public_ip"
        fi
    elif [[ -n "$self_hosted_ip" ]]; then
        echo "$self_hosted_ip"
        _write_ip_result "self-hosted only (public unreachable)" "$self_hosted_ip" "n/a"
    elif [[ -n "$public_ip" ]]; then
        echo "$public_ip"
        if [[ -n "$SELF_HOSTED_RESOLVER" ]]; then
            _write_ip_result "public fallback (self-hosted down)" "down" "$public_ip"
        else
            _write_ip_result "public resolver" "disabled" "$public_ip"
        fi
    else
        _write_ip_result "ALL RESOLVERS FAILED" "fail" "fail"
        return 1
    fi
}

get_current_ipv6() {
    for resolver in "${PUBLIC_RESOLVER_LIST[@]}"; do
        local ip
        ip=$(resolve_ip "$resolver" "-6")
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

load_ip_result() {
    if [[ -f "${META_DIR}/.ip_result" ]]; then
        source "${META_DIR}/.ip_result"
        rm -f "${META_DIR}/.ip_result"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  DISCORD HELPERS
# ══════════════════════════════════════════════════════════════════════════

discord_embed() {
    local webhook="$1" title="$2" description="$3" color="${4:-3447003}"
    [[ -z "$webhook" ]] && return 0
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    curl -s -H "Content-Type: application/json" -d "{
        \"embeds\": [{
            \"title\": \"${title}\",
            \"description\": \"${description}\",
            \"color\": ${color},
            \"timestamp\": \"${timestamp}\",
            \"footer\": {\"text\": \"DDNS Updater • $(hostname)\"}
        }]
    }" "$webhook" >/dev/null 2>&1
    return $?
}

discord_send() { [[ "$DISCORD_ENABLED" == true ]] && discord_embed "$DISCORD_WEBHOOK" "$@" || true; }
discord_prop() { [[ "$DISCORD_PROP_ENABLED" == true ]] && discord_embed "$DISCORD_WEBHOOK_PROPAGATION" "$@" || true; }

COLOR_GREEN=3066993
COLOR_YELLOW=16776960
COLOR_RED=15158332
COLOR_BLUE=3447003
COLOR_PURPLE=10181046
COLOR_CYAN=1752220
COLOR_ORANGE=15105570
COLOR_GREY=9807270

# ══════════════════════════════════════════════════════════════════════════
#  RECORD FILE PARSER
# ══════════════════════════════════════════════════════════════════════════
#
# Parses record files into arrays. Each entry is:
#   hostname|type|data|category
#
# Categories:
#   dynamic  = A/AAAA with auto IP (data will be filled at runtime)
#   static   = everything else (data from file)
#
# Examples:
#   www          → www|A||dynamic
#   @|AAAA       → @|AAAA||dynamic
#   mail|CNAME|x → mail|CNAME|x|static

PARSED_RECORDS=()
HAS_AAAA=false

parse_record_files() {
    PARSED_RECORDS=()
    HAS_AAAA=false

    if [[ ! -d "$RECORDS_DIR" ]]; then return; fi

    for domain_file in "$RECORDS_DIR"/*; do
        [[ -f "$domain_file" ]] || continue
        [[ "$(basename "$domain_file")" == ".gitkeep" ]] && continue

        local domain auto_root=true
        domain=$(basename "$domain_file")

        # Check for NOROOT
        if grep -qi "^NOROOT" "$domain_file" 2>/dev/null; then
            auto_root=false
        fi

        # Auto-add root A if no NOROOT
        if [[ "$auto_root" == true ]]; then
            PARSED_RECORDS+=("@|A||dynamic|${domain}")
        fi

        while IFS= read -r line || [[ -n "$line" ]]; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$line" || "$line" == \#* ]] && continue
            [[ "${line^^}" == "NOROOT" ]] && continue

            local hostname="" rectype="" recdata="" category=""

            # Parse pipe-delimited fields
            IFS='|' read -r hostname rectype recdata <<< "$line"
            hostname=$(echo "$hostname" | tr -d '[:space:]')
            rectype=$(echo "${rectype:-}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
            recdata="${recdata:-}"

            # Default: bare hostname = A record, dynamic
            if [[ -z "$rectype" ]]; then
                rectype="A"
            fi

            # Determine category
            if [[ "$rectype" == "A" || "$rectype" == "AAAA" ]]; then
                if [[ -z "$recdata" ]]; then
                    category="dynamic"
                else
                    category="static"
                fi
            else
                category="static"
            fi

            # Track if AAAA exists
            [[ "$rectype" == "AAAA" && "$category" == "dynamic" ]] && HAS_AAAA=true

            # Skip duplicate auto-root (user explicitly added @|A)
            if [[ "$hostname" == "@" && "$rectype" == "A" && "$category" == "dynamic" && "$auto_root" == true ]]; then
                # Already added above, skip duplicate
                continue
            fi

            PARSED_RECORDS+=("${hostname}|${rectype}|${recdata}|${category}|${domain}")
        done < "$domain_file"
    done
}

# ══════════════════════════════════════════════════════════════════════════
#  DNS24 API
# ══════════════════════════════════════════════════════════════════════════

# URL-encode a string
url_encode() {
    local string="$1"
    local encoded=""
    local i c
    for (( i=0; i<${#string}; i++ )); do
        c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            ' ') encoded+="%20" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$encoded"
}

# Update a DNS record via dns24 API
# Args: hostname type data
# For dynamic A: update_dns24_record "@.example.ch" "A" "client"
# For static:    update_dns24_record "mail.example.ch" "CNAME" "target.com"
update_dns24_record() {
    local hostname="$1" rectype="$2" recdata="$3"

    if [[ "$TEST_MODE" == true ]]; then
        echo "good (TEST — not sent)"
        return 0
    fi

    local encoded_data
    encoded_data=$(url_encode "$recdata")

    curl ${CURL_IP_FLAG:+"$CURL_IP_FLAG"} -s --max-time "$DNS24_TIMEOUT" --digest \
        --user "${DNS24_USER}:${DNS24_PASS}" \
        "${DNS24_API_URL}?hostname=${hostname}&type=${rectype}&data=${encoded_data}" 2>&1
}

# Check API result for success
is_api_success() {
    local result="$1"
    [[ "$result" == *"good"* || "$result" == *"nochg"* || "$result" == *"Transaction successful"* ]]
}

# Strip HTML from API error responses to a clean one-liner
clean_api_response() {
    local result="$1"
    # Already clean?
    if [[ "$result" == *"good"* || "$result" == *"nochg"* || "$result" == *"Transaction successful"* ]]; then
        echo "$result"
        return
    fi
    # Extract HTTP error from HTML title or legend
    if [[ "$result" == *"<title>"* ]]; then
        local extracted
        extracted=$(echo "$result" | sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' | head -1)
        [[ -n "$extracted" ]] && { echo "$extracted"; return; }
    fi
    if [[ "$result" == *"<legend>"* ]]; then
        local extracted
        extracted=$(echo "$result" | sed -n 's/.*<legend>\([^<]*\)<\/legend>.*/\1/p' | head -1)
        [[ -n "$extracted" ]] && { echo "$extracted"; return; }
    fi
    # Curl error or short message — return as-is (truncated)
    echo "${result:0:120}"
}

# ══════════════════════════════════════════════════════════════════════════
#  NS VERIFICATION
# ══════════════════════════════════════════════════════════════════════════

# Query authoritative NS for a record
# Args: fqdn type [ns_server]
ns_query() {
    local fqdn="$1" rectype="$2" ns="${3:-$NS1}"
    dig +short +time=5 +tries=1 "@${ns}" "$fqdn" "$rectype" 2>/dev/null | tr -d '[:space:]'
}

# Check if dns24 nameservers are reachable
ns_health_check() {
    local result
    result=$(dig +short +time=5 +tries=1 "@${NS1}" "dns24.ch" A 2>/dev/null)
    [[ -n "$result" ]]
}

# Verify a record against both NS servers
# Args: fqdn type expected_data
# Returns: 0 = confirmed, 1 = mismatch/stale, 2 = NS unreachable
ns_verify_record() {
    local fqdn="$1" rectype="$2" expected="$3"

    local ns1_result ns2_result
    ns1_result=$(ns_query "$fqdn" "$rectype" "$NS1")
    ns2_result=$(ns_query "$fqdn" "$rectype" "$NS2")

    # NS unreachable
    if [[ -z "$ns1_result" && -z "$ns2_result" ]]; then
        return 2
    fi

    # Normalize for comparison (trim, lowercase for text records)
    local ns1_clean ns2_clean expected_clean
    ns1_clean=$(echo "$ns1_result" | tr -d '"' | tr '[:upper:]' '[:lower:]')
    ns2_clean=$(echo "$ns2_result" | tr -d '"' | tr '[:upper:]' '[:lower:]')
    expected_clean=$(echo "$expected" | tr -d '"' | tr '[:upper:]' '[:lower:]')

    # For A/AAAA: exact IP match
    # For others: check if expected data appears in the response
    if [[ "$rectype" == "A" || "$rectype" == "AAAA" ]]; then
        if [[ "$ns1_clean" == "$expected_clean" || "$ns2_clean" == "$expected_clean" ]]; then
            return 0
        fi
    else
        if [[ "$ns1_clean" == *"$expected_clean"* || "$ns2_clean" == *"$expected_clean"* ]]; then
            return 0
        fi
    fi

    return 1
}

# ══════════════════════════════════════════════════════════════════════════
#  PENDING LIST MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════
#
# Format: hostname|type|domain|data|status|attempts|timestamp
# Status: failed | unconfirmed | static_pending
#
# failed          = API returned error, needs retry
# unconfirmed     = API ok but NS hasn't confirmed yet
# static_pending  = static record not yet verified on NS

pending_add() {
    local hostname="$1" rectype="$2" domain="$3" data="$4" status="$5"
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    # Remove any existing entry for same record
    pending_remove "$hostname" "$rectype" "$domain"
    echo "${hostname}|${rectype}|${domain}|${data}|${status}|1|${ts}" >> "$PENDING_FILE"
}

pending_remove() {
    local hostname="$1" rectype="$2" domain="$3"
    if [[ -f "$PENDING_FILE" ]]; then
        grep -v "^${hostname}|${rectype}|${domain}|" "$PENDING_FILE" > "${PENDING_FILE}.tmp" 2>/dev/null || true
        mv "${PENDING_FILE}.tmp" "$PENDING_FILE"
    fi
}

pending_increment() {
    local hostname="$1" rectype="$2" domain="$3"
    if [[ -f "$PENDING_FILE" ]]; then
        local line
        line=$(grep "^${hostname}|${rectype}|${domain}|" "$PENDING_FILE" 2>/dev/null | head -1)
        if [[ -n "$line" ]]; then
            local data status attempts ts
            IFS='|' read -r _ _ _ data status attempts ts <<< "$line"
            ((attempts++)) || true
            pending_remove "$hostname" "$rectype" "$domain"
            echo "${hostname}|${rectype}|${domain}|${data}|${status}|${attempts}|${ts}" >> "$PENDING_FILE"
        fi
    fi
}

pending_count() {
    [[ -f "$PENDING_FILE" ]] && grep -c '.' "$PENDING_FILE" 2>/dev/null || echo 0
}

# ══════════════════════════════════════════════════════════════════════════
#  OUTAGE DETECTION
# ══════════════════════════════════════════════════════════════════════════

get_outage_count() {
    [[ -f "$OUTAGE_FILE" ]] && cat "$OUTAGE_FILE" 2>/dev/null | tr -d '[:space:]' || echo "0"
}

increment_outage() {
    local count
    count=$(get_outage_count)
    ((count++)) || true
    echo "$count" > "$OUTAGE_FILE"
    echo "$count"
}

reset_outage() {
    local prev
    prev=$(get_outage_count)
    echo "0" > "$OUTAGE_FILE"
    echo "$prev"
}

# Evaluate outage status and send appropriate Discord alerts
handle_outage() {
    local count
    count=$(increment_outage)

    # Check if NS is also down
    local ns_down=false
    if ! ns_health_check; then
        ns_down=true
    fi

    local detail=""
    if [[ "$ns_down" == true ]]; then
        detail="API **and** nameservers (${NS1}, ${NS2}) are unreachable.\\ndns24.ch appears to be completely down."
    else
        detail="API is failing but nameservers are responding.\\nPossible: rate limit, auth issue, or partial outage."
    fi

    if [[ $count -eq 1 ]]; then
        log_warn "dns24 API failure (attempt ${count}), will retry"
    elif [[ $count -ge 2 && $count -le 4 ]]; then
        log_warn "dns24 API failure (attempt ${count})"
        discord_send "⚠️ DDNS — dns24 API Issues" \
            "API has failed **${count} consecutive** times.\\n\\n${detail}\\n\\nUpdates are queued and will be applied on recovery." \
            "$COLOR_YELLOW"
    elif [[ $count -ge 5 ]]; then
        local mins=$(( count * CHECK_INTERVAL / 60 ))
        log_error "dns24 API down for ~${mins} minutes (${count} failures)"
        if [[ $(( count % 5 )) -eq 0 ]]; then
            discord_send "🚨 DDNS — dns24 Down" \
                "API has been failing for **~${mins} minutes** (${count} consecutive failures).\\n\\n${detail}\\n\\nAll updates are queued. Recovery will trigger automatic retry." \
                "$COLOR_RED"
        fi
    fi
}

handle_recovery() {
    local prev
    prev=$(reset_outage)
    if [[ "$prev" -ge 2 ]]; then
        log_info "dns24 recovered after ${prev} failures"
        discord_send "🟢 DDNS — dns24 Recovered" \
            "API is back online after **${prev}** consecutive failures.\\nProcessing queued updates..." \
            "$COLOR_GREEN"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  DNS LOOKUP / PROPAGATION
# ══════════════════════════════════════════════════════════════════════════

dns_lookup() {
    local domain="$1" dns_server="$2" rectype="${3:-A}"
    if command -v dig &>/dev/null; then
        dig +short +time=3 +tries=1 "@${dns_server}" "$domain" "$rectype" 2>/dev/null \
            | head -1 | tr -d '[:space:]'
        return
    fi
    curl -s --max-time "$RESOLVER_TIMEOUT" \
        "https://dns.google/resolve?name=${domain}&type=${rectype}" 2>/dev/null \
        | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | tr -d '[:space:]'
}

format_elapsed() {
    local secs="$1"
    if (( secs >= 60 )); then echo "$((secs/60))m $((secs%60))s"
    else echo "${secs}s"; fi
}

check_propagation() {
    local domain="$1" expected_ip="$2"
    local max_rounds="$PROPAGATION_MAX_ROUNDS"
    local interval="$PROPAGATION_INTERVAL"

    [[ "$TEST_MODE" == true ]] && { max_rounds=1; interval=0; }

    local start_time=$SECONDS
    local total_zones=${#PROP_ZONE_LIST[@]}

    discord_prop "🌍 Propagation — Tracking Started" \
        "**Domain:** \`${domain}\`\\n**Expected IP:** \`${expected_ip}\`\\n\\nMonitoring **${total_zones} zones** every **${interval}s**\\nMax rounds: ${max_rounds}" \
        "$COLOR_CYAN"

    for ((round=1; round<=max_rounds; round++)); do
        local all_done=true status_lines="" ok_count=0

        for zone_entry in "${PROP_ZONE_LIST[@]}"; do
            IFS='|' read -r zone_label provider dns_ip <<< "$zone_entry"
            local resolved
            resolved=$(dns_lookup "$domain" "$dns_ip")

            if [[ "$resolved" == "$expected_ip" ]]; then
                status_lines+="✅ **${zone_label}** — ${provider} (\`${dns_ip}\`) → \`${resolved}\`\\n"
                ((ok_count++)) || true
            elif [[ -n "$resolved" ]]; then
                status_lines+="🔄 **${zone_label}** — ${provider} (\`${dns_ip}\`) → \`${resolved}\` _(stale)_\\n"
                all_done=false
            else
                status_lines+="❓ **${zone_label}** — ${provider} (\`${dns_ip}\`) → _timeout_\\n"
                all_done=false
            fi
        done

        local elapsed=$(( SECONDS - start_time ))
        local elapsed_fmt
        elapsed_fmt=$(format_elapsed "$elapsed")
        local bar=""
        for ((i=0; i<total_zones; i++)); do
            if ((i < ok_count)); then bar+="🟢"; else bar+="⚫"; fi
        done

        if [[ "$all_done" == true ]]; then
            discord_prop "✅ Propagation — Complete!" \
                "**${domain}** → \`${expected_ip}\`\\n\\n${bar} **${ok_count}/${total_zones}** zones confirmed\\n⏱️ **${elapsed_fmt}**\\n\\n${status_lines}" \
                "$COLOR_GREEN"
            log_info "Propagation complete: ${domain} in ${elapsed_fmt}"
            return 0
        fi

        if [[ "$TEST_MODE" == true ]]; then
            discord_prop "🧪 Propagation — Test Snapshot" \
                "**${domain}** → \`${expected_ip}\`\\n\\n${bar} **${ok_count}/${total_zones}** zones\\n\\n${status_lines}" \
                "$COLOR_ORANGE"
            return 0
        fi

        local embed_color=$COLOR_ORANGE
        ((ok_count >= 4)) && embed_color=$COLOR_YELLOW
        ((ok_count >= 2)) && embed_color=$COLOR_PURPLE

        discord_prop "🌐 Propagation — Round ${round}/${max_rounds}" \
            "**${domain}** → \`${expected_ip}\`\\n\\n${bar} **${ok_count}/${total_zones}** zones\\n⏱️ **${elapsed_fmt}**\\n\\n${status_lines}" \
            "$embed_color"
        log_info "Propagation round ${round}: ${ok_count}/${total_zones}"

        ((round < max_rounds)) && sleep "$interval" || true
    done

    local elapsed=$(( SECONDS - start_time ))
    discord_prop "⚠️ Propagation — Incomplete" \
        "**${domain}** not fully propagated after **${max_rounds} rounds** ($(format_elapsed "$elapsed")).\\n\\n${status_lines}" \
        "$COLOR_YELLOW"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════
#  IP HISTORY
# ══════════════════════════════════════════════════════════════════════════

save_ip() {
    local ip="$1" file="$2"
    echo "$ip" > "$file"

    if [[ "$KEEP_IP_HISTORY" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${ip}" >> "$HISTORY_FILE"
        if [[ "$IP_HISTORY_MAX_LINES" -gt 0 ]]; then
            local lines
            lines=$(wc -l < "$HISTORY_FILE" 2>/dev/null || echo 0)
            if (( lines > IP_HISTORY_MAX_LINES )); then
                tail -n "$IP_HISTORY_MAX_LINES" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
                mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
            fi
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  PROCESS PENDING RECORDS
# ══════════════════════════════════════════════════════════════════════════

process_pending() {
    [[ ! -s "$PENDING_FILE" ]] && return 0

    local new_pending="" processed=0 resolved=0 still_pending=0
    local ns_confirmed_log="" static_pushed_log="" retry_log=""

    while IFS='|' read -r hostname rectype domain data status attempts ts; do
        [[ -z "$hostname" ]] && continue
        ((processed++)) || true

        local fqdn="${hostname}.${domain}"
        [[ "$hostname" == "@" ]] && fqdn="@.${domain}"

        case "$status" in
            failed)
                # Retry API call
                log_info "Retrying ${fqdn} (${rectype}, attempt ${attempts})"
                local result
                result=$(update_dns24_record "$fqdn" "$rectype" "$data")
                if is_api_success "$result"; then
                    handle_recovery
                    new_pending+="${hostname}|${rectype}|${domain}|${data}|unconfirmed|${attempts}|${ts}\n"
                    log_info "Retry succeeded for ${fqdn}, awaiting NS confirmation"
                    retry_log+="✅ \`${fqdn}\` ${rectype} — retry OK, verifying\\n"
                    ((still_pending++)) || true
                else
                    handle_outage
                    ((attempts++)) || true
                    new_pending+="${hostname}|${rectype}|${domain}|${data}|failed|${attempts}|${ts}\n"
                    log_warn "Retry failed for ${fqdn} (attempt ${attempts}): $(clean_api_response "$result")"
                    retry_log+="❌ \`${fqdn}\` ${rectype} — retry failed (attempt ${attempts})\\n"
                    ((still_pending++)) || true
                fi
                ;;

            unconfirmed)
                # Check NS for confirmation
                local fqdn_ns="${hostname}.${domain}"
                [[ "$hostname" == "@" ]] && fqdn_ns="${domain}"

                if ns_verify_record "$fqdn_ns" "$rectype" "$data"; then
                    log_info "NS confirmed: ${fqdn} ${rectype}"
                    ns_confirmed_log+="✅ \`${fqdn}\` ${rectype} → \`${data}\`\\n"
                    ((resolved++)) || true
                else
                    local verify_rc=$?
                    if [[ $verify_rc -eq 2 ]]; then
                        log_warn "NS unreachable checking ${fqdn}"
                    fi
                    ((attempts++)) || true
                    if [[ $attempts -gt 20 ]]; then
                        log_warn "Giving up on NS confirmation for ${fqdn} after ${attempts} attempts"
                        ns_confirmed_log+="⚠️ \`${fqdn}\` ${rectype} — gave up after ${attempts} checks\\n"
                        ((resolved++)) || true
                    else
                        new_pending+="${hostname}|${rectype}|${domain}|${data}|unconfirmed|${attempts}|${ts}\n"
                        ((still_pending++)) || true
                    fi
                fi
                ;;

            static_pending)
                # Verify static record via NS
                local fqdn_ns="${hostname}.${domain}"
                [[ "$hostname" == "@" ]] && fqdn_ns="${domain}"

                if ns_verify_record "$fqdn_ns" "$rectype" "$data"; then
                    log_info "Static record confirmed: ${fqdn} ${rectype}"
                    static_pushed_log+="✅ \`${fqdn}\` ${rectype} — already correct\\n"
                    ((resolved++)) || true
                else
                    # Push static record
                    log_info "Pushing static record: ${fqdn} ${rectype} → ${data}"
                    local result
                    result=$(update_dns24_record "$fqdn" "$rectype" "$data")
                    if is_api_success "$result"; then
                        handle_recovery
                        new_pending+="${hostname}|${rectype}|${domain}|${data}|unconfirmed|${attempts}|${ts}\n"
                        static_pushed_log+="🔄 \`${fqdn}\` ${rectype} → pushed, verifying\\n"
                        ((still_pending++)) || true
                    else
                        handle_outage
                        ((attempts++)) || true
                        new_pending+="${hostname}|${rectype}|${domain}|${data}|static_pending|${attempts}|${ts}\n"
                        static_pushed_log+="❌ \`${fqdn}\` ${rectype} → push failed\\n"
                        ((still_pending++)) || true
                    fi
                fi
                ;;
        esac
    done < "$PENDING_FILE"

    # Write new pending file
    echo -ne "$new_pending" > "$PENDING_FILE"

    if [[ $processed -gt 0 ]]; then
        log_info "Pending: ${resolved} resolved, ${still_pending} remaining"
    fi

    # ── Discord: NS verification results ──
    if [[ -n "$ns_confirmed_log" ]]; then
        discord_send "🔍 DDNS — NS Verified" \
            "Confirmed on ${NS1} / ${NS2}:\\n\\n${ns_confirmed_log}" \
            "$COLOR_GREEN"
    fi

    # ── Discord: Static record activity ──
    if [[ -n "$static_pushed_log" ]]; then
        discord_send "📌 DDNS — Static Records" \
            "Static record verification:\\n\\n${static_pushed_log}" \
            "$COLOR_BLUE"
    fi

    # ── Discord: Retry activity ──
    if [[ -n "$retry_log" ]]; then
        local retry_color=$COLOR_YELLOW
        [[ "$retry_log" != *"❌"* ]] && retry_color=$COLOR_GREEN
        discord_send "🔄 DDNS — Retry Queue" \
            "Retried pending records:\\n\\n${retry_log}" \
            "$retry_color"
    fi

    # ── Discord: Pending queue status (if items remain) ──
    if [[ $still_pending -gt 0 ]]; then
        discord_send "📋 DDNS — Pending Queue" \
            "**${still_pending}** record(s) still pending (${resolved} resolved this cycle).\\nWill retry next cycle." \
            "$COLOR_ORANGE"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
#  DRIFT DETECTION
# ══════════════════════════════════════════════════════════════════════════

check_drift() {
    local current_ipv4
    current_ipv4=$(cat "$IP_FILE" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$current_ipv4" ]] && return 0

    # Pick a random dynamic A record to check
    local candidates=()
    for rec in "${PARSED_RECORDS[@]}"; do
        IFS='|' read -r hostname rectype recdata category domain <<< "$rec"
        [[ "$category" == "dynamic" && "$rectype" == "A" ]] && candidates+=("$rec")
    done

    [[ ${#candidates[@]} -eq 0 ]] && return 0

    # Pick random
    local idx=$(( RANDOM % ${#candidates[@]} ))
    local check="${candidates[$idx]}"
    IFS='|' read -r hostname rectype recdata category domain <<< "$check"

    local fqdn="${domain}"
    [[ "$hostname" != "@" ]] && fqdn="${hostname}.${domain}"

    local ns_result
    ns_result=$(ns_query "$fqdn" "A" "$NS1")

    if [[ -z "$ns_result" ]]; then
        log_warn "Drift check: NS unreachable for ${fqdn}"
        return 0
    fi

    if [[ "$ns_result" != "$current_ipv4" ]]; then
        log_warn "DRIFT detected: ${fqdn} resolves to ${ns_result} but should be ${current_ipv4}"
        discord_send "⚠️ DDNS — Drift Detected" \
            "**${fqdn}** resolves to \`${ns_result}\` on ${NS1}\\nExpected: \`${current_ipv4}\`\\n\\nRe-pushing all dynamic records..." \
            "$COLOR_YELLOW"
        # Return 1 to trigger a full update
        return 1
    fi

    log_info "Drift check OK: ${fqdn} → ${ns_result}"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════
#  TEST MODE
# ══════════════════════════════════════════════════════════════════════════

test_run() {
    echo "╔══════════════════════════════════════════════════╗"
    echo "║        DDNS Updater — TEST MODE                  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo

    local pass=0 fail=0 warn=0

    # ── 1. Config ──
    echo "━━━ 1/8 Configuration ━━━"
    echo "  Config dir:       ${CONFIG_DIR}"
    echo "  DNS24 user:       ${DNS24_USER}"
    echo "  DNS24 pass:       $(echo "$DNS24_PASS" | sed 's/./*/g')"
    echo "  DNS24 API:        ${DNS24_API_URL}"
    echo "  Nameservers:      ${NS1}, ${NS2}"
    if [[ "$DNS24_PASS" == "CHANGE_ME" || "$DNS24_PASS" == "your-password-here" ]]; then
        echo "  ⚠️  Password is still the default placeholder!"
        ((warn++)) || true
    else
        echo "  ✅ Password is set"
        ((pass++)) || true
    fi
    echo

    # ── 2. Settings ──
    echo "━━━ 2/8 Settings ━━━"
    echo "  Check interval:   ${CHECK_INTERVAL}s"
    echo "  Resolver timeout: ${RESOLVER_TIMEOUT}s"
    echo "  DNS24 timeout:    ${DNS24_TIMEOUT}s"
    echo "  Force IPv4:       ${FORCE_IPV4}"
    echo "  Drift check:      every ${DRIFT_CHECK_INTERVAL} cycles"
    echo "  Log level:        ${LOG_LEVEL}"
    if [[ "$KEEP_IP_HISTORY" == "true" ]]; then
        local max_disp="${IP_HISTORY_MAX_LINES}"
        [[ "$max_disp" == "0" ]] && max_disp="unlimited"
        echo "  IP history:       on (max ${max_disp} lines)"
    else
        echo "  IP history:       off"
    fi
    echo "  Self-hosted:      ${SELF_HOSTED_RESOLVER:-disabled}"
    echo "  Discord:          $( [[ "$DISCORD_ENABLED" == true ]] && echo "on" || echo "off" )"
    echo "  Discord prop:     $( [[ "$DISCORD_PROP_ENABLED" == true ]] && echo "on" || echo "off" )"
    echo "  Public resolvers: ${#PUBLIC_RESOLVER_LIST[@]}"
    for r in "${PUBLIC_RESOLVER_LIST[@]}"; do echo "    → $r"; done
    echo "  Propagation:      ${PROPAGATION_ENABLED}"
    if [[ "$PROPAGATION_ENABLED" == "true" ]]; then
        echo "    Interval:       ${PROPAGATION_INTERVAL}s"
        echo "    Max rounds:     ${PROPAGATION_MAX_ROUNDS}"
        echo "    Max wait:       $(( PROPAGATION_INTERVAL * PROPAGATION_MAX_ROUNDS ))s"
        echo "    Zones:          ${#PROP_ZONE_LIST[@]}"
        for z in "${PROP_ZONE_LIST[@]}"; do
            IFS='|' read -r zl zp zi <<< "$z"
            echo "      ${zl} — ${zp} (${zi})"
        done
    fi
    ((pass++)) || true
    echo

    # ── 3. Discord Webhooks ──
    echo "━━━ 3/8 Discord Webhooks ━━━"
    if [[ "$DISCORD_ENABLED" != true ]]; then
        echo "  ⏭️  Main webhook: disabled"
        ((warn++)) || true
    else
        echo "  Main:        ${DISCORD_WEBHOOK:0:60}..."
        if discord_embed "$DISCORD_WEBHOOK" "🧪 DDNS Test — Main Webhook" \
            "Main webhook is working!" "$COLOR_BLUE"; then
            echo "  ✅ Main webhook — sent"
            ((pass++)) || true
        else
            echo "  ❌ Main webhook — failed"
            ((fail++)) || true
        fi
    fi
    if [[ "$DISCORD_PROP_ENABLED" != true ]]; then
        echo "  ⏭️  Propagation webhook: disabled"
    elif [[ "$DISCORD_WEBHOOK_PROPAGATION" == "$DISCORD_WEBHOOK" ]]; then
        echo "  Propagation: same as main"
    else
        echo "  Propagation: ${DISCORD_WEBHOOK_PROPAGATION:0:60}..."
        if discord_embed "$DISCORD_WEBHOOK_PROPAGATION" "🧪 DDNS Test — Propagation Webhook" \
            "Propagation webhook working!" "$COLOR_CYAN"; then
            echo "  ✅ Propagation webhook — sent"
            ((pass++)) || true
        else
            echo "  ❌ Propagation webhook — failed"
            ((fail++)) || true
        fi
    fi
    echo

    # ── 4. IP Resolution ──
    echo "━━━ 4/8 IP Resolution ━━━"
    local resolved_ip="" resolved_ipv6=""

    for resolver in "${IP_RESOLVERS[@]}"; do
        local ip
        ip=$(resolve_ip "$resolver" "$CURL_IP_FLAG")
        if [[ -n "$ip" ]]; then
            echo "  ✅ ${resolver} → ${ip}"
            ((pass++)) || true
        else
            if [[ "$resolver" == "$SELF_HOSTED_RESOLVER" ]]; then
                echo "  ⚠️  ${resolver} → unreachable (self-hosted)"
                ((warn++)) || true
            else
                echo "  ❌ ${resolver} → failed"
                ((fail++)) || true
            fi
        fi
    done

    IP_SOURCE="" IP_SELF="" IP_PUBLIC=""
    resolved_ip=$(get_current_ip) || true
    load_ip_result

    if [[ -n "$resolved_ip" ]]; then
        echo "  ─────────────────"
        echo "  IPv4:  ${resolved_ip} (${IP_SOURCE})"
        ((pass++)) || true
    else
        echo "  ❌ Could not resolve IPv4"
        ((fail++)) || true
    fi

    # IPv6 check
    if [[ "$HAS_AAAA" == true ]]; then
        resolved_ipv6=$(get_current_ipv6) || true
        if [[ -n "$resolved_ipv6" ]]; then
            echo "  IPv6:  ${resolved_ipv6}"
            ((pass++)) || true
        else
            echo "  ⚠️  AAAA records configured but no IPv6 available"
            ((warn++)) || true
        fi
    fi
    echo

    # ── 5. Record Files ──
    echo "━━━ 5/8 Record Files ━━━"
    parse_record_files

    if [[ ${#PARSED_RECORDS[@]} -eq 0 ]]; then
        echo "  ❌ No records found"
        ((fail++)) || true
    else
        local current_domain="" dyn_count=0 static_count=0
        for rec in "${PARSED_RECORDS[@]}"; do
            IFS='|' read -r hostname rectype recdata category domain <<< "$rec"

            if [[ "$domain" != "$current_domain" ]]; then
                [[ -n "$current_domain" ]] && echo
                echo "  📁 ${domain}"
                current_domain="$domain"
            fi

            local fqdn="${hostname}.${domain}"
            [[ "$hostname" == "@" ]] && fqdn="@.${domain}"

            if [[ "$category" == "dynamic" ]]; then
                echo "     📝 ${fqdn} ${rectype} → <dynamic IP>"
                ((dyn_count++)) || true
            else
                echo "     📝 ${fqdn} ${rectype} → ${recdata}"
                ((static_count++)) || true
            fi
        done
        echo
        echo "  ✅ ${#PARSED_RECORDS[@]} records (${dyn_count} dynamic, ${static_count} static)"
        ((pass++)) || true
    fi
    echo

    # ── 6. DNS24 Connectivity ──
    echo "━━━ 6/8 DNS24 Connectivity ━━━"
    local dns24_host
    dns24_host="${DNS24_API_URL#*://}"
    dns24_host="${dns24_host%%/*}"
    local dns24_scheme
    dns24_scheme="${DNS24_API_URL%%://*}"
    if curl ${CURL_IP_FLAG:+"$CURL_IP_FLAG"} -s --max-time "$DNS24_TIMEOUT" "${dns24_scheme}://${dns24_host}" >/dev/null 2>&1; then
        echo "  ✅ ${dns24_host} reachable"
        ((pass++)) || true
    else
        echo "  ❌ ${dns24_host} unreachable"
        ((fail++)) || true
    fi
    echo

    # ── 7. NS Verification ──
    echo "━━━ 7/8 Nameserver Check ━━━"
    if ns_health_check; then
        echo "  ✅ ${NS1} reachable"
        ((pass++)) || true
    else
        echo "  ❌ ${NS1} unreachable"
        ((fail++)) || true
    fi

    local ns2_result
    ns2_result=$(dig +short +time=5 +tries=1 "@${NS2}" "dns24.ch" A 2>/dev/null)
    if [[ -n "$ns2_result" ]]; then
        echo "  ✅ ${NS2} reachable"
        ((pass++)) || true
    else
        echo "  ❌ ${NS2} unreachable"
        ((fail++)) || true
    fi

    # Spot-check a record if possible
    if [[ -n "$resolved_ip" && ${#PARSED_RECORDS[@]} -gt 0 ]]; then
        local first_rec="${PARSED_RECORDS[0]}"
        IFS='|' read -r hostname rectype recdata category domain <<< "$first_rec"
        local fqdn_check="${domain}"
        [[ "$hostname" != "@" ]] && fqdn_check="${hostname}.${domain}"

        local ns_check
        ns_check=$(ns_query "$fqdn_check" "$rectype" "$NS1")
        if [[ -n "$ns_check" ]]; then
            echo "  NS lookup: ${fqdn_check} ${rectype} → ${ns_check}"
        else
            echo "  NS lookup: ${fqdn_check} ${rectype} → (no result)"
        fi
    fi

    # Pending records
    local pending_n
    pending_n=$(pending_count)
    if [[ "$pending_n" -gt 0 ]]; then
        echo "  ⚠️  ${pending_n} pending record(s) in retry queue"
        ((warn++)) || true
    fi
    echo

    # ── 8. Propagation Test ──
    echo "━━━ 8/8 DNS Propagation ━━━"
    if [[ "$PROPAGATION_ENABLED" != "true" ]]; then
        echo "  ⏭️  Propagation disabled"
    else
        if command -v dig &>/dev/null; then
            echo "  ✅ dig available"
            ((pass++)) || true
        else
            echo "  ⚠️  dig not found — using fallback"
            ((warn++)) || true
        fi
        if [[ -n "${resolved_ip:-}" && ${#PARSED_RECORDS[@]} -gt 0 ]]; then
            local first_domain
            for rec in "${PARSED_RECORDS[@]}"; do
                IFS='|' read -r _ _ _ _ domain <<< "$rec"
                first_domain="$domain"
                break
            done
            if [[ -n "$first_domain" ]]; then
                echo "  Running snapshot for ${first_domain}..."
                echo
                check_propagation "$first_domain" "$resolved_ip"
            fi
        else
            echo "  ⏭️  Skipping (no IP or no records)"
        fi
    fi
    echo

    # ── Summary ──
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  TEST RESULTS                                    ║"
    echo "╠══════════════════════════════════════════════════╣"
    printf "║  ✅ Passed:   %-34s║\n" "$pass"
    printf "║  ⚠️  Warnings: %-34s║\n" "$warn"
    printf "║  ❌ Failed:   %-34s║\n" "$fail"
    echo "╠══════════════════════════════════════════════════╣"
    if [[ $fail -eq 0 ]]; then
        echo "║  🟢 Ready to go!                                 ║"
    else
        echo "║  🔴 Fix the failures above before running.       ║"
    fi
    echo "╚══════════════════════════════════════════════════╝"

    local summary_color=$COLOR_GREEN summary_title="🧪 Test — All Passed!"
    [[ $fail -gt 0 ]] && { summary_color=$COLOR_RED; summary_title="🧪 Test — ${fail} Failures"; }
    [[ $fail -eq 0 && $warn -gt 0 ]] && { summary_color=$COLOR_YELLOW; summary_title="🧪 Test — Passed (${warn} warnings)"; }

    local dyn_info="${dyn_count:-0} dynamic"
    [[ "${static_count:-0}" -gt 0 ]] && dyn_info+=", ${static_count} static"
    [[ "$HAS_AAAA" == true ]] && dyn_info+=" (includes AAAA)"

    discord_send "$summary_title" \
        "**Results:** ✅ ${pass} · ⚠️ ${warn} · ❌ ${fail}\\n\\n**IP:** \`${resolved_ip:-unknown}\`\\n**Records:** ${dyn_info}\\n**NS:** ${NS1}, ${NS2}" \
        "$summary_color"
}

# ══════════════════════════════════════════════════════════════════════════
#  MAIN LOGIC
# ══════════════════════════════════════════════════════════════════════════

main() {
    parse_record_files

    # ── Startup notification ──
    if [[ "$STARTUP_RUN" == "true" && "$DISCORD_NOTIFY_STARTUP" == "true" ]]; then
        local dyn_count=0 static_count=0
        for rec in "${PARSED_RECORDS[@]}"; do
            IFS='|' read -r _ _ _ category _ <<< "$rec"
            [[ "$category" == "dynamic" ]] && ((dyn_count+=1)) || ((static_count+=1))
        done

        discord_send "🟢 DDNS Updater — Started" \
            "Container started on \`$(hostname)\`\\n\\n**Config:**\\nCheck interval: \`${CHECK_INTERVAL}s\`\\nRecords: \`${#PARSED_RECORDS[@]}\` (${dyn_count} dynamic, ${static_count} static)\\nPropagation: \`${PROPAGATION_ENABLED}\`\\nDrift check: every ${DRIFT_CHECK_INTERVAL} cycles\\nNS: ${NS1}, ${NS2}" \
            "$COLOR_BLUE"

        # On startup, queue all static records for verification
        for rec in "${PARSED_RECORDS[@]}"; do
            IFS='|' read -r hostname rectype recdata category domain <<< "$rec"
            [[ "$category" == "static" ]] && pending_add "$hostname" "$rectype" "$domain" "$recdata" "static_pending"
        done
    fi

    # ── Resolve IPs ──
    local old_ip new_ip=""
    old_ip=$(cat "$IP_FILE" 2>/dev/null | tr -d '[:space:]')

    IP_SOURCE="" IP_SELF="" IP_PUBLIC=""
    new_ip=$(get_current_ip) || true
    load_ip_result

    if [[ -z "$new_ip" ]]; then
        log_error "All IP resolvers failed"
        discord_send "🚨 DDNS — All Resolvers Failed" \
            "Could not determine public IP.\\nSelf-hosted: \`${IP_SELF}\`\\nPublic: \`${IP_PUBLIC}\`" \
            "$COLOR_RED"
        # Still process pending records
        process_pending || true
        return 1
    fi

    log_info "Old: ${old_ip:-none} | New: ${new_ip} | Source: ${IP_SOURCE} | Status: $([[ "$new_ip" == "$old_ip" ]] && echo unchanged || echo updated)"

    # IPv6 if needed
    local new_ipv6=""
    if [[ "$HAS_AAAA" == true ]]; then
        new_ipv6=$(get_current_ipv6) || true
        if [[ -n "$new_ipv6" ]]; then
            local old_ipv6
            old_ipv6=$(cat "$IP6_FILE" 2>/dev/null | tr -d '[:space:]')
            if [[ "$new_ipv6" != "$old_ipv6" ]]; then
                log_info "IPv6: ${old_ipv6:-none} → ${new_ipv6}"
                discord_send "🔷 DDNS — IPv6 Changed" \
                    "**Old:** \`${old_ipv6:-first-run}\`\\n**New:** \`${new_ipv6}\`" \
                    "$COLOR_BLUE"
            fi
        else
            log_warn "AAAA records configured but no IPv6 available"
            discord_send "⚠️ DDNS — No IPv6 Available" \
                "AAAA records are configured but IPv6 could not be detected.\\nAAAA updates will be skipped until IPv6 is available." \
                "$COLOR_YELLOW"
        fi
    fi

    if [[ "$IP_SOURCE" == *"MISMATCH"* ]]; then
        discord_send "⚠️ DDNS — IP Resolver Mismatch" \
            "🏠 Self-hosted: \`${IP_SELF}\`\\n🌐 Public: \`${IP_PUBLIC}\`\\n\\nUsing public IP. **Check self-hosted resolver.**" \
            "$COLOR_YELLOW"
    fi

    # ── Determine if update needed ──
    local ip_changed=false force_update=false
    [[ "$new_ip" != "$old_ip" ]] && ip_changed=true

    local old_ipv6=""
    if [[ "$HAS_AAAA" == true && -n "$new_ipv6" ]]; then
        old_ipv6=$(cat "$IP6_FILE" 2>/dev/null | tr -d '[:space:]')
        [[ "$new_ipv6" != "$old_ipv6" ]] && ip_changed=true
    fi

    # Drift check on stable cycles
    if [[ "$ip_changed" == false ]]; then
        local cycle
        cycle=$(cat "$CYCLE_FILE" 2>/dev/null | tr -d '[:space:]')
        cycle=${cycle:-0}
        ((cycle++)) || true
        echo "$cycle" > "$CYCLE_FILE"

        if (( cycle % DRIFT_CHECK_INTERVAL == 0 )); then
            if ! check_drift; then
                force_update=true
                log_warn "Drift detected, forcing full update"
            fi
        fi
    else
        echo "0" > "$CYCLE_FILE"
    fi

    # ── No change, no drift ──
    if [[ "$ip_changed" == false && "$force_update" == false ]]; then
        if [[ "$DISCORD_NOTIFY_UNCHANGED" == "true" ]]; then
            discord_send "ℹ️ DDNS — No Change" \
                "IP still \`${new_ip}\`" "$COLOR_GREY"
        fi
        # Still process pending records
        process_pending || true
        return 0
    fi

    # ── IP changed or drift — update dynamic records ──
    local update_log="" errors=0 total=0
    local -a propagation_domains=()
    local any_api_success=false

    for rec in "${PARSED_RECORDS[@]}"; do
        IFS='|' read -r hostname rectype recdata category domain <<< "$rec"
        [[ "$category" != "dynamic" ]] && continue

        local fqdn="${hostname}.${domain}"
        [[ "$hostname" == "@" ]] && fqdn="@.${domain}"

        # Determine data to send
        local send_data="client"
        if [[ "$rectype" == "AAAA" ]]; then
            if [[ -z "$new_ipv6" ]]; then
                update_log+="⏭️ \`${fqdn}\` ${rectype} — no IPv6 available\\n"
                continue
            fi
            send_data="$new_ipv6"
        fi

        log_info "Updating ${fqdn} (${rectype})"
        local result
        result=$(update_dns24_record "$fqdn" "$rectype" "$send_data")
        ((total++)) || true

        if is_api_success "$result"; then
            any_api_success=true
            update_log+="✅ \`${fqdn}\` ${rectype}\\n"
            propagation_domains+=("$domain")
            # Queue for NS verification
            local verify_data="$new_ip"
            [[ "$rectype" == "AAAA" ]] && verify_data="$new_ipv6"
            pending_add "$hostname" "$rectype" "$domain" "$verify_data" "unconfirmed"
        else
            local clean_result
            clean_result=$(clean_api_response "$result")
            update_log+="❌ \`${fqdn}\` ${rectype} — ${clean_result}\\n"
            ((errors++)) || true
            local fail_data="$new_ip"
            [[ "$rectype" == "AAAA" ]] && fail_data="$new_ipv6"
            pending_add "$hostname" "$rectype" "$domain" "$fail_data" "failed"
        fi
    done

    # Handle outage/recovery based on results
    if [[ $total -gt 0 ]]; then
        if [[ "$any_api_success" == true ]]; then
            handle_recovery
        fi
        if [[ $errors -eq $total ]]; then
            handle_outage
        fi
    fi

    # ── Save IPs ──
    save_ip "$new_ip" "$IP_FILE"
    [[ -n "$new_ipv6" ]] && save_ip "$new_ipv6" "$IP6_FILE"

    # ── Discord summary ──
    local title color
    if [[ $errors -eq 0 ]]; then
        title="✅ DDNS — IP Changed & Updated"
        color=$COLOR_GREEN
    elif [[ $errors -lt $total ]]; then
        title="⚠️ DDNS — IP Changed (${errors}/${total} failed)"
        color=$COLOR_YELLOW
    else
        title="🚨 DDNS — IP Changed (all updates failed)"
        color=$COLOR_RED
    fi

    local ip_info="**Old:** \`${old_ip:-first-run}\` → **New:** \`${new_ip}\`"
    [[ -n "$new_ipv6" ]] && ip_info+="\\n**IPv6:** \`${new_ipv6}\`"

    local succeeded=$(( total - errors ))

    discord_send "$title" \
        "${ip_info}\\nSource: ${IP_SOURCE}\\n\\n**Records:** ${succeeded}/${total} succeeded\\n${update_log}" \
        "$color"

    log_info "Done. ${succeeded} succeeded, ${errors} failed (${total} total)."

    # ── Process pending (includes newly added) ──
    process_pending || true

    # ── Propagation tracking ──
    if [[ "$PROPAGATION_ENABLED" == "true" && ${#propagation_domains[@]} -gt 0 && $errors -lt $total ]]; then
        log_info "Starting propagation checks..."
        # Deduplicate domains
        local -A seen_domains=()
        for d in "${propagation_domains[@]}"; do
            if [[ -z "${seen_domains[$d]:-}" ]]; then
                seen_domains[$d]=1
                check_propagation "$d" "$new_ip" || true
            fi
        done
    fi

    return 0
}

# ══════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════

if [[ "$TEST_MODE" == true ]]; then
    parse_record_files
    if [[ "$TEST_PROP_ONLY" == true ]]; then
        echo "Running propagation test only..."
        IP_SOURCE="" IP_SELF="" IP_PUBLIC=""
        resolved_ip=$(get_current_ip) || true
        load_ip_result
        first_domain=""
        for rec in "${PARSED_RECORDS[@]}"; do
            IFS='|' read -r _ _ _ _ domain <<< "$rec"
            first_domain="$domain"
            break
        done
        if [[ -n "$resolved_ip" && -n "$first_domain" ]]; then
            check_propagation "$first_domain" "$resolved_ip"
        else
            echo "❌ Need a resolved IP and at least one record file"
            exit 1
        fi
    else
        test_run
    fi
else
    main "$@"
fi
