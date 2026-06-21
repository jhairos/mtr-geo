#!/usr/bin/env bash
# mtr-geo — MTR con resumen (ASN | ORG | GEO | RTTavg)
# Uso:
#   mtr-geo <host|ip>
#   mtr-geo -c 20 <host|ip>
#   mtr-geo -6 <host|ip>
#
# Fuentes de datos:
#   1. mtr --aslookup (ASN directo)
#   2. ip-api.com batch API (geo + org, sin clave, gratuito)
#   3. Fallback a UNKNOWN si no hay red
set -euo pipefail

COUNT=3
IPV6=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -6|--ipv6) IPV6=1; shift ;;
    -c|--count) COUNT="${2:-3}"; shift 2 ;;
    -h|--help) echo "Uso: $0 [-6] [-c N] <host|ip>"; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done
[[ -z "${TARGET:-}" ]] && { echo "Uso: $0 [-6] [-c N] <host|ip>" >&2; exit 1; }

command -v mtr  >/dev/null 2>&1 || { echo "❌ Falta 'mtr' (apt install mtr-tiny)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "❌ Falta 'curl'"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "❌ Falta 'jq' (apt install jq)"; exit 1; }

is_private_ip() {
  local ip="$1"
  [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^169\.254\.|^0\.0\.0\.0$ ]] && return 0
  [[ "$ip" == fe80:* || "$ip" == fc* || "$ip" == fd* || "$ip" == ::1 ]] && return 0
  return 1
}

trim_len() {
  local s="${1:-}" max="${2:-32}"
  (( ${#s} <= max )) && echo "$s" || echo "${s:0:max-1}…"
}

normalize_org() {
  local s="$1"
  s="${s//CLOUDFLARENET/Cloudflare}"
  s="${s//Cloudflare, Inc./Cloudflare}"
  s="${s//GOOGLE LLC/Google}"
  s="${s//Google LLC/Google}"
  s="${s//AMAZON-02/Amazon}"
  s="${s//Amazon.com, Inc./Amazon}"
  echo "$s" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g'
}

# Ejecutar mtr
if [[ $IPV6 -eq 1 ]]; then
  MTR_CMD=(mtr -6 -rnc "$COUNT" "$TARGET" --aslookup)
else
  MTR_CMD=(mtr -rnc "$COUNT" "$TARGET" --aslookup)
fi
RAW="$("${MTR_CMD[@]}")"

echo "$RAW"
echo

# Parsear hops del output de mtr
# Formato: "  N. ASxxxx  IP  Loss%  Snt  Last  Avg  Best  Wrst  StDev"
declare -a HOPS_ORDER
declare -A HOP_IP HOP_AVG HOP_ASN_MTR HOP_LOSS

while IFS= read -r line; do
  [[ "$line" =~ ^Start: || "$line" =~ ^HOST: || -z "$line" ]] && continue
  hop=$(echo "$line" | awk '{print $1}' | sed 's/[^0-9]//g')
  [[ -z "$hop" ]] && continue
  ip=$(echo "$line" | awk '{print $3}')
  avg=$(echo "$line" | awk '{if(NF>=7) print $7; else print ""}')
  asn_mtr=$(echo "$line" | awk '{print $2}')
  loss=$(echo "$line" | awk '{print $4}')
  HOPS_ORDER+=("$hop")
  HOP_IP[$hop]="${ip:-}"
  HOP_AVG[$hop]="${avg:-}"
  HOP_ASN_MTR[$hop]="${asn_mtr:-}"
  HOP_LOSS[$hop]="${loss:-}"
done <<< "$RAW"

# Recopilar IPs públicas únicas para lookup batch
declare -A GEO_CACHE
declare -a PUBLIC_IPS

for hop in "${HOPS_ORDER[@]:-}"; do
  ip="${HOP_IP[$hop]:-}"
  [[ -z "$ip" || "$ip" == "???" ]] && continue
  is_private_ip "$ip" && continue
  PUBLIC_IPS+=("$ip")
done

# Batch lookup a ip-api.com (1 request para todos los hops)
if [[ ${#PUBLIC_IPS[@]} -gt 0 ]]; then
  # Deduplicar
  mapfile -t UNIQUE_IPS < <(printf '%s\n' "${PUBLIC_IPS[@]}" | sort -u)

  # Construir JSON array para POST
  JSON_BATCH=$(printf '%s\n' "${UNIQUE_IPS[@]}" | jq -R . | jq -sc .)

  # POST a ip-api.com/batch
  BATCH_RESULT=$(curl -sf --max-time 15 \
    "http://ip-api.com/batch?fields=status,query,country,regionName,org,as" \
    -H "Content-Type: application/json" \
    -d "$JSON_BATCH" 2>/dev/null) || BATCH_RESULT="[]"

  # Poblar cache
  N=$(echo "$BATCH_RESULT" | jq 'length' 2>/dev/null || echo 0)
  for ((i=0; i<N; i++)); do
    entry=$(echo "$BATCH_RESULT" | jq ".[$i]" 2>/dev/null) || continue
    qip=$(echo  "$entry" | jq -r '.query // ""')
    status=$(echo "$entry" | jq -r '.status // ""')
    [[ "$status" != "success" || -z "$qip" ]] && continue
    country=$(echo "$entry" | jq -r '.country // ""')
    region=$(echo  "$entry" | jq -r '.regionName // ""')
    org=$(echo     "$entry" | jq -r '.org // ""')
    as=$(echo      "$entry" | jq -r '.as // ""')
    if [[ -n "$country" && -n "$region" ]]; then
      geo="$country, $region"
    else
      geo="$country"
    fi
    GEO_CACHE["$qip"]="${geo}|${as}|${org}"
  done
fi

RED=$(printf '\033[31m')
RESET=$(printf '\033[0m')

# Imprimir tabla resumen
echo "Resumen  hop → IP | Loss% | AS | Organización | Geo | RTTavg"
printf "%-3s  %-39s  %-7s  %-12s  %-28s  %-24s  %7s\n" \
  "Hop" "IP/Host" "Loss%" "AS" "Organización" "Geo" "Avg(ms)"
printf "%-3s  %-39s  %-7s  %-12s  %-28s  %-24s  %7s\n" \
  "---" "---------------------------------------" \
  "-------" "------------" "----------------------------" \
  "------------------------" "-------"

for hop in "${HOPS_ORDER[@]:-}"; do
  ip="${HOP_IP[$hop]:-}"
  avg="${HOP_AVG[$hop]:-}"
  asn_mtr="${HOP_ASN_MTR[$hop]:-}"
  loss="${HOP_LOSS[$hop]:-}"

  # Colorear Loss% si es distinto de 0.0%
  if [[ "$loss" != "0.0%" && -n "$loss" ]]; then
    loss_col="${RED}${loss}${RESET}"
  else
    loss_col="$loss"
  fi

  # Padding manual para que ANSI no descuadre columnas
  loss_padded=$(printf "%-7s" "$loss")
  if [[ -z "$ip" || "$ip" == "???" ]]; then
    loss_padded=$(printf "%-7s" "100.0%")
    printf "%-3s  %-39s  %s  %-12s  %-28s  %-24s  %7s\n" \
      "$hop" "*" "${RED}${loss_padded}${RESET}" "" "" "" ""
    continue
  fi

  if is_private_ip "$ip"; then
    printf "%-3s  %-39s  %s  %-12s  %-28s  %-24s  %7s\n" \
      "$hop" "$ip" "$loss_padded" "PRIVATE" "LAN/PRIVATE" "PRIVATE" "$avg"
    continue
  fi

  geo="UNKNOWN"
  asn="$asn_mtr"
  org="UNKNOWN"

  cached="${GEO_CACHE[$ip]:-}"
  if [[ -n "$cached" ]]; then
    IFS='|' read -r geo asn_api org <<< "$cached"
    if [[ "$asn_mtr" == "AS???" || -z "$asn_mtr" ]]; then
      asn="$asn_api"
    fi
    asn=$(echo "$asn" | grep -Eo '^AS[0-9]+' || echo "$asn_mtr")
  fi

  [[ -z "$asn" || "$asn" == "AS???" ]] && asn="?"
  org=$(normalize_org "$org")
  org=$(trim_len "$org" 28)
  geo=$(trim_len "$geo" 24)

  if [[ "$loss" != "0.0%" && -n "$loss" ]]; then
    loss_display="${RED}${loss_padded}${RESET}"
  else
    loss_display="$loss_padded"
  fi

  printf "%-3s  %-39s  %s  %-12s  %-28s  %-24s  %7s\n" \
    "$hop" "$ip" "$loss_display" "$asn" "$org" "$geo" "$avg"
done
