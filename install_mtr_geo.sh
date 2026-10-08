#!/usr/bin/env bash
# install_mtr_geo.sh — Setup genérico (Debian/Ubuntu)
# - NO expone credenciales: usa variables de entorno:
# - Instala: geoipupdate, mmdblookup, mtr, whois, jq
# - Copia mtr_geo.sh a /usr/local/bin/mtr-geo

set -euo pipefail

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Re-ejecutando con sudo…"
    exec sudo -E bash "$0" "$@"
  fi
}
need_root "$@"

# --- Paquetes base ---
if ! command -v apt-get >/dev/null 2>&1; then
  echo "❌ Instalador preparado para Debian/Ubuntu (apt)."; exit 1
fi

apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common

# PPA de MaxMind (si existe)
if command -v add-apt-repository >/dev/null 2>&1; then
  add-apt-repository -y ppa:maxmind/ppa || true
  apt-get update -y || true
fi

apt-get install -y geoipupdate mmdb-bin geoip-bin mtr-tiny whois jq

DB_DIR="/usr/share/GeoIP"
install -d -m 0755 "$DB_DIR"

# --- Config segura de GeoIP (sin claves hardcodeadas) ---
tee /etc/GeoIP.conf >/dev/null <<EOF
# Config generada por install_mtr_geo.sh (genérica)
AccountID ${ACCOUNT_ID}
LicenseKey ${LICENSE_KEY}
EditionIDs GeoLite2-City GeoLite2-ASN GeoLite2-Country
DatabaseDirectory ${DB_DIR}
EOF

echo "==> Descargando bases GeoLite2…"
geoipupdate -v || { echo "⚠️ Reintentando…"; sleep 2; geoipupdate -v; }

# Verificación
for f in GeoLite2-City.mmdb GeoLite2-ASN.mmdb GeoLite2-Country.mmdb; do
  test -f "${DB_DIR}/${f}" || { echo "❌ Falta ${f} en ${DB_DIR}"; exit 1; }
done

# --- Instalar binario mtr-geo ---
BIN="/usr/local/bin/mtr-geo"
cat > "$BIN" <<'EOS'
#!/usr/bin/env bash
# mtr-geo — MTR con resumen (ASN | ORG | GEO | RTTavg)
# Uso:
#   mtr-geo <host|ip>
#   mtr-geo -c 5 <host|ip>
#   mtr-geo -6 <host|ip>
set -euo pipefail

COUNT=3
IPV6=0
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -6|--ipv6) IPV6=1; shift;;
    -c|--count) COUNT="${2:-3}"; shift 2;;
    -h|--help) echo "Uso: $0 [-6] [-c N] <host|ip>"; exit 0;;
    *) TARGET="$1"; shift;;
  esac
done
[[ -z "${TARGET:-}" ]] && { echo "Uso: $0 [-6] [-c N] <host|ip>" >&2; exit 1; }

command -v mtr >/dev/null 2>&1 || { echo "❌ Falta 'mtr'"; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "❌ Falta 'awk'"; exit 1; }

MMDB_CITY="${MMDB_CITY:-/usr/share/GeoIP/GeoLite2-City.mmdb}"
MMDB_ASN="${MMDB_ASN:-/usr/share/GeoIP/GeoLite2-ASN.mmdb}"
LEG_COUNTRY="/usr/share/GeoIP/GeoIP.dat"
LEG_ASN="/usr/share/GeoIP/GeoIPASNum.dat"

have_mmdb_city=0; [[ -f "$MMDB_CITY" ]] && command -v mmdblookup >/dev/null 2>&1 && have_mmdb_city=1
have_mmdb_asn=0;  [[ -f "$MMDB_ASN"  ]] && command -v mmdblookup >/dev/null 2>&1 && have_mmdb_asn=1
have_leg_country=0; [[ -f "$LEG_COUNTRY" ]] && command -v geoiplookup >/dev/null 2>&1 && have_leg_country=1
have_leg_asn=0;     [[ -f "$LEG_ASN"     ]] && command -v geoiplookup >/dev/null 2>&1 && have_leg_asn=1
have_whois=0; command -v whois >/dev/null 2>&1 && have_whois=1

is_private_ip() {
  local ip="$1"
  [[ "$ip" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^169\.254\.|^0\.0\.0\.0$ ]] && return 0
  [[ "$ip" == fe80:* || "$ip" == fc* || "$ip" == fd* || "$ip" == ::1 ]] && return 0
  return 1
}

get_asn_org_mmdb() {
  local ip="$1"
  [[ $have_mmdb_asn -eq 1 ]] || { echo ""; return; }
  local num org
  num=$(mmdblookup --file "$MMDB_ASN" --ip "$ip" autonomous_system_number 2>/dev/null | grep -Eo '[0-9]+' | head -n1)
  org=$(mmdblookup --file "$MMDB_ASN" --ip "$ip" autonomous_system_organization 2>/dev/null | awk -F'"' '/"/{print $2; exit}')
  if [[ -n "${num:-}" && -n "${org:-}" ]]; then
    echo "AS${num}|$org"
  elif [[ -n "${num:-}" ]]; then
    echo "AS${num}|"
  else
    echo ""
  fi
}
get_asn_org_legacy() {
  local ip="$1" line
  [[ $have_leg_asn -eq 1 ]] || { echo ""; return; }
  line=$(geoiplookup -f "$LEG_ASN" "$ip" 2>/dev/null | sed -E 's/^GeoIP ASNum Edition:[[:space:]]*//')
  [[ -z "$line" ]] && { echo ""; return; }
  echo "${line%% *}|${line#* }"
}
get_asn_from_mtrcol() {
  local line="$1"; echo "$line" | awk '{print $2}' | grep -Eo '^AS[0-9]+' || true
}
get_org_from_asn_cymru() {
  local asn="$1"
  [[ $have_whois -eq 1 ]] || { echo ""; return; }
  whois -h whois.cymru.com " -v $asn" 2>/dev/null | awk -F'|' 'NR==2{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$5); print $5}'
}
get_asn_org() {
  local ip="$1" line="$2"
  if is_private_ip "$ip"; then echo "PRIVATE|PRIVATE"; return; fi
  local v
  v=$(get_asn_org_mmdb "$ip");   [[ -n "$v" ]] && { echo "$v"; return; }
  v=$(get_asn_org_legacy "$ip"); [[ -n "$v" ]] && { echo "$v"; return; }
  local as_from_mtr; as_from_mtr="$(get_asn_from_mtrcol "$line" || true)"
  if [[ -n "$as_from_mtr" ]]; then
    local org=""; org="$(get_org_from_asn_cymru "$as_from_mtr" || true)"
    [[ -n "$org" ]] && { echo "$as_from_mtr|$org"; return; }
    echo "$as_from_mtr|UNKNOWN"; return
  fi
  echo "UNKNOWN|UNKNOWN"
}

get_geo_mmdb() {
  local ip="$1" country region
  [[ $have_mmdb_city -eq 1 ]] || { echo ""; return; }
  country=$(mmdblookup --file "$MMDB_CITY" --ip "$ip" country names en 2>/dev/null | awk -F'"' '/"/{print $2; exit}')
  region=$(mmdblookup  --file "$MMDB_CITY" --ip "$ip" subdivisions 0 names en 2>/dev/null | awk -F'"' '/"/{print $2; exit}')
  [[ -z "$region" ]] && region=$(mmdblookup --file "$MMDB_CITY" --ip "$ip" city names en 2>/dev/null | awk -F'"' '/"/{print $2; exit}')
  [[ -n "$country" && -n "$region" ]] && { echo "$country, $region"; return; }
  echo "$country"
}
get_geo_legacy() {
  local ip="$1"
  [[ $have_leg_country -eq 1 ]] || { echo ""; return; }
  geoiplookup -f "$LEG_COUNTRY" "$ip" 2>/dev/null | sed -E 's/^GeoIP Country Edition: [A-Z]{2},[ ]*//' | sed 's/,$//' | head -n1
}
get_geo() {
  local ip="$1"
  if is_private_ip "$ip"; then echo "PRIVATE"; return; fi
  local v
  v=$(get_geo_mmdb "$ip");   [[ -n "$v" ]] && { echo "$v"; return; }
  v=$(get_geo_legacy "$ip"); [[ -n "$v" ]] && { echo "$v"; return; }
  echo "UNKNOWN"
}

trim_len(){ local s="${1:-}" max="${2:-32}"; local l=${#s}; (( l<=max )) && echo "$s" || echo "${s:0:max-1}…"; }
normalize_org(){
  local s="$1"
  s="${s//CLOUDFLARENET/Cloudflare}"
  s="${s//Cloudflare, Inc./Cloudflare}"
  s="${s//GOOGLE LLC/Google}"
  echo "$(echo "$s" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^[ ]+|[ ]+$//g')"
}

# --- Ejecuta MTR (salida original + resumen) ---
if [[ $IPV6 -eq 1 ]]; then MTR_CMD=(mtr -6 -rnc "$COUNT" "$TARGET" --aslookup)
else                       MTR_CMD=(mtr -rnc "$COUNT" "$TARGET" --aslookup)
fi
RAW="$("${MTR_CMD[@]}")"

echo "$RAW"
echo
echo "Resumen (hop → ip | AS | Organización | Geo | RTTavg)"
printf "%-3s %-39s %-10s %-28s %-24s %7s\n" "Hop" "IP/Host" "AS" "Organización" "Geo" "Avg(ms)"
printf "%-3s %-39s %-10s %-28s %-24s %7s\n" "---" "---------------------------------------" "----------" "----------------------------" "------------------------" "-------"

while IFS= read -r line; do
  [[ "$line" =~ ^Start: || "$line" =~ ^HOST: || -z "$line" ]] && continue
  hop="$(echo "$line" | awk '{print $1}' | sed 's/[^0-9]//g')"
  [[ -z "$hop" ]] && continue
  ip="$(echo "$line" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9A-Fa-f]{1,4}:){1,7}[0-9A-Fa-f]{0,4}' | head -n1)"
  [[ -z "$ip" ]] && { printf "%-3s %-39s %-10s %-28s %-24s %7s\n" "$hop" "*" "" "" "" ""; continue; }
  avg="$(echo "$line" | awk '{if(NF>=6){print $(NF-3)}else{print ""}}')"

  IFS='|' read -r asn org <<<"$(get_asn_org "$ip" "$line")"
  [[ "$asn" == "PRIVATE" ]] && org="PRIVATE"
  [[ -z "$asn" ]] && asn="UNKNOWN"
  [[ -z "$org" ]] && org="UNKNOWN"
  org="$(normalize_org "$org")"
  org="$(trim_len "$org" 28)"
  geo="$(trim_len "$(get_geo "$ip")" 24)"

  printf "%-3s %-39s %-10s %-28s %-24s %7s\n" "$hop" "$ip" "$asn" "$org" "$geo" "$avg"
done <<< "$RAW"
EOS
chmod +x "$BIN"

# Cron diario para actualizar DBs
CRON_FILE="/etc/cron.d/geoipupdate"
tee "$CRON_FILE" >/dev/null <<'EOF'
# Actualiza bases MaxMind GeoLite2 diariamente a las 03:27
27 3 * * * root /usr/bin/geoipupdate >/var/log/geoipupdate.log 2>&1
EOF
chmod 0644 "$CRON_FILE"

echo "✅ Listo. Prueba:"
echo "  mtr-geo example.org"
echo "  mtr-geo -c 5 8.8.8.8"
