#!/bin/bash
set -euo pipefail

# === Ländercodes (ipdeny nutzt ISO-2 in lowercase) ===
COUNTRY_CODES=(cn ru sg)

# Netfilter chains
CHAIN4="GEO_BLOCK4"
CHAIN6="GEO_BLOCK6"
LOGTAG="geoip-block"

# ipdeny URL-Basen
IPDENY_V4_BASE="https://www.ipdeny.com/ipblocks/data/countries"
IPDENY_V6_BASE="https://www.ipdeny.com/ipv6/ipaddresses/aggregated"

RETRY_MAX=12
RETRY_SLEEP=5
CURL_TIMEOUT=20

log() {
  logger -t "$LOGTAG" "$*"
  echo "[$(date -Is)] $*" >&2
}

wait_for_dns() {
  local host="www.ipdeny.com"
  for ((i=1; i<=RETRY_MAX; i++)); do
    if getent ahosts "$host" >/dev/null 2>&1; then
      log "DNS OK for ${host}"
      return 0
    fi
    log "DNS not ready (${i}/${RETRY_MAX}); sleep ${RETRY_SLEEP}s"
    sleep "$RETRY_SLEEP"
  done
  log "DNS still not ready; continuing"
  return 0
}

# Gibt NUR den Body auf stdout aus (wichtig!)
fetch_body_with_retry() {
  local url="$1"
  for ((i=1; i<=RETRY_MAX; i++)); do
    if curl -fsSL \
      --connect-timeout "$CURL_TIMEOUT" \
      --max-time "$CURL_TIMEOUT" \
      "$url"; then
      return 0
    fi
    log "Fetch failed (${i}/${RETRY_MAX}) for ${url}; sleep ${RETRY_SLEEP}s"
    sleep "$RETRY_SLEEP"
  done
  log "Fetch ultimately failed for ${url}"
  return 1
}

# Filtert nur gültige CIDRs raus
filter_cidrs() {
  local family="$1" # inet|inet6
  if [[ "$family" == "inet" ]]; then
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true
  else
    # akzeptiert übliches IPv6 CIDR-Format
    grep -E '^[0-9a-fA-F:]+/[0-9]+$' || true
  fi
}

update_ipset_atomic() {
  local set_name="$1"
  local family="$2" # inet|inet6
  local url="$3"
  local tmp_set="${set_name}_tmp"

  ipset create "$set_name" hash:net family "$family" -exist
  ipset create "$tmp_set"  hash:net family "$family" -exist
  ipset flush "$tmp_set"

  fetch_body_with_retry "$url" | filter_cidrs "$family" | while read -r net; do
    [[ -n "${net:-}" ]] || continue
    ipset add "$tmp_set" "$net" -exist
  done

  ipset swap "$set_name" "$tmp_set"
  ipset destroy "$tmp_set"
}

# Wichtig: bestehende Regeln bleiben erhalten.
# Wir flushen nur unsere eigene GEO_BLOCK*-Chain und hängen/halten nur den Jump von INPUT auf diese Chain.
ensure_chain4() {
  iptables -nL "$CHAIN4" >/dev/null 2>&1 || iptables -N "$CHAIN4"
  iptables -F "$CHAIN4"

  # Jump-Regel additiv ganz nach oben (ohne andere INPUT-Regeln anzutasten)
  if ! iptables -C INPUT -j "$CHAIN4" >/dev/null 2>&1; then
    iptables -I INPUT 1 -j "$CHAIN4"
  fi
}

ensure_chain6() {
  ip6tables -nL "$CHAIN6" >/dev/null 2>&1 || ip6tables -N "$CHAIN6"
  ip6tables -F "$CHAIN6"

  if ! ip6tables -C INPUT -j "$CHAIN6" >/dev/null 2>&1; then
    ip6tables -I INPUT 1 -j "$CHAIN6"
  fi
}

set_name_v4() { local cc="$1"; echo "geo_${cc}4"; }
set_name_v6() { local cc="$1"; echo "geo_${cc}6"; }

url_v4() { local cc="$1"; echo "${IPDENY_V4_BASE}/${cc}.zone"; }
url_v6() { local cc="$1"; echo "${IPDENY_V6_BASE}/${cc}-aggregated.zone"; }

main() {
  log "Start update (v4+v6)"
  wait_for_dns

  # IPv4 ipsets
  for cc in "${COUNTRY_CODES[@]}"; do
    local set_name
    local url
    set_name="$(set_name_v4 "$cc")"
    url="$(url_v4 "$cc")"
    log "Updating ${set_name} (inet) from ${url}"
    update_ipset_atomic "$set_name" "inet" "$url"
  done

  # IPv6 ipsets
  for cc in "${COUNTRY_CODES[@]}"; do
    local set_name
    local url
    set_name="$(set_name_v6 "$cc")"
    url="$(url_v6 "$cc")"
    log "Updating ${set_name} (inet6) from ${url}"
    update_ipset_atomic "$set_name" "inet6" "$url"
  done

  # Chains + Regeln (dynamisch aus COUNTRY_CODES)
  log "Ensure chain ${CHAIN4}"
  ensure_chain4
  for cc in "${COUNTRY_CODES[@]}"; do
    iptables -A "$CHAIN4" -m set --match-set "$(set_name_v4 "$cc")" src -j DROP
  done
  iptables -A "$CHAIN4" -j RETURN

  log "Ensure chain ${CHAIN6}"
  ensure_chain6
  for cc in "${COUNTRY_CODES[@]}"; do
    ip6tables -A "$CHAIN6" -m set --match-set "$(set_name_v6 "$cc")" src -j DROP
  done
  ip6tables -A "$CHAIN6" -j RETURN

  log "Done (v4+v6)"
}

main "$@"
