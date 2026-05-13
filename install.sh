#!/usr/bin/env bash
# =============================================================================
#  install.sh – SenseBox-Dashboard Einrichtungsskript
#  Für Raspberry Pi (Raspberry Pi OS / Debian-basiert)
# =============================================================================
#
#  Ausführung:
#    chmod +x install.sh
#    ./install.sh
#
#  Was dieses Skript tut:
#    1. Zeigt Netzwerkinfo (IP + MAC) für 10 Sekunden
#    2. Installiert Systemabhängigkeiten
#    3. Sucht nahe SenseBoxen via IP-Geolokalisierung
#    4. Lässt den Nutzer eine SenseBox auswählen
#    5. Konfiguriert bis zu 3 Logos (CLI-Suche, URL oder überspringen)
#    6. Schreibt die Konfiguration in dashboard.py und die Service-Datei
#    7. Richtet Autostart ein (systemd oder XDG-Desktop-Eintrag)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="${SCRIPT_DIR}/sensebox-dashboard.service"
DASHBOARD_PY="${SCRIPT_DIR}/dashboard.py"
LOGFILE="${SCRIPT_DIR}/install.log"

# ─── Farben & Hilfsfunktionen ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${GREEN}[✔]${RESET} $*" | tee -a "${LOGFILE}"; }
info()  { echo -e "${CYAN}[i]${RESET} $*" | tee -a "${LOGFILE}"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*" | tee -a "${LOGFILE}"; }
error() { echo -e "${RED}[✘]${RESET} $*" | tee -a "${LOGFILE}"; }
title() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n"; }

confirm() {
    # confirm "Frage" → 0=ja, 1=nein
    local prompt="${1} [j/N] "
    local answer
    read -r -p "$(echo -e "${YELLOW}${prompt}${RESET}")" answer
    [[ "${answer,,}" == "j" || "${answer,,}" == "ja" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

require_cmd() {
    command -v "$1" &>/dev/null
}

# ─── Banner ───────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
 ____                      ____            
/ ___|  ___ _ __  ___  ___| __ )  _____  __
\___ \ / _ \ '_ \/ __|/ _ \  _ \ / _ \ \/ /
 ___) |  __/ | | \__ \  __/ |_) | (_) >  < 
|____/ \___|_| |_|___/\___|____/ \___/_/\_\
     Dashboard – Einrichtungsskript
EOF
echo -e "${RESET}"
echo "Installationsprotokoll: ${LOGFILE}"
echo ""
echo "Startzeit: $(date)" | tee -a "${LOGFILE}"

# =============================================================================
# 1. Geräteinformationen anzeigen (10 Sekunden)
# =============================================================================
title "Geräteinformationen"

show_device_info() {
    local ip_line mac_line

    # Bevorzuge die erste nicht-loopback Netzwerkschnittstelle
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}' || true)
    if [[ -z "${iface}" ]]; then
        iface=$(ip link show | awk -F': ' '/^[0-9]+: [^l]/{print $2; exit}')
    fi

    local ipv4 mac
    ipv4=$(ip -4 addr show "${iface}" 2>/dev/null | awk '/inet /{print $2}' | cut -d'/' -f1 | head -1 || true)
    mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || true)

    echo -e "  Netzwerkschnittstelle : ${BOLD}${iface:-unbekannt}${RESET}"
    echo -e "  IPv4-Adresse          : ${BOLD}${ipv4:-nicht verfügbar}${RESET}"
    echo -e "  MAC-Adresse           : ${BOLD}${mac:-nicht verfügbar}${RESET}"
    echo ""

    # Versuche öffentliche IP zu ermitteln
    local pub_ip
    pub_ip=$(curl -sf --max-time 5 https://api4.ipify.org 2>/dev/null || true)
    if [[ -n "${pub_ip}" ]]; then
        echo -e "  Öffentliche IP        : ${BOLD}${pub_ip}${RESET}"
    fi
    echo ""
}

show_device_info

echo -e "${YELLOW}Diese Informationen werden in 10 Sekunden ausgeblendet …${RESET}"
for i in {10..1}; do
    printf "\r  Weiter in %2d Sekunden … " "${i}"
    sleep 1
done
printf "\r%-40s\r" ""
echo ""

# =============================================================================
# 2. Systemabhängigkeiten installieren
# =============================================================================
title "Systemabhängigkeiten prüfen & installieren"

REQUIRED_APT=(python3 python3-tk python3-pip python3-venv curl git jq)
MISSING_APT=()

for pkg in "${REQUIRED_APT[@]}"; do
    if ! dpkg -s "${pkg}" &>/dev/null; then
        MISSING_APT+=("${pkg}")
    else
        log "${pkg} ist bereits installiert"
    fi
done

if [[ ${#MISSING_APT[@]} -gt 0 ]]; then
    info "Folgende Pakete werden installiert: ${MISSING_APT[*]}"
    sudo apt-get update -qq 2>&1 | tee -a "${LOGFILE}"
    sudo apt-get install -y "${MISSING_APT[@]}" 2>&1 | tee -a "${LOGFILE}"
    log "Alle Pakete installiert"
fi

# ─── Virtuelle Umgebung & Python-Pakete ───────────────────────────────────────
VENV_DIR="${SCRIPT_DIR}/.venv"
if [[ ! -d "${VENV_DIR}" ]]; then
    info "Erstelle Python-venv …"
    python3 -m venv "${VENV_DIR}" 2>&1 | tee -a "${LOGFILE}"
fi
# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"
pip install --quiet --upgrade pip 2>&1 | tee -a "${LOGFILE}"
pip install --quiet -r "${SCRIPT_DIR}/requirements.txt" 2>&1 | tee -a "${LOGFILE}"
log "Python-Abhängigkeiten installiert"

# =============================================================================
# 3. SenseBox auswählen
# =============================================================================
title "SenseBox auswählen"

SELECTED_BOX_ID=""
SELECTED_BOX_NAME=""

# ── Aktuelle Box-ID aus dashboard.py lesen ────────────────────────────────────
CURRENT_BOX_ID=$(grep -oP '(?<=BOX_ID = ")[^"]+' "${DASHBOARD_PY}" || true)
info "Aktuell konfigurierte Box-ID: ${CURRENT_BOX_ID:-keine}"

# ── Geolokalisierung via IP ───────────────────────────────────────────────────
info "Bestimme Standort via IP-Geolokalisierung …"
GEO_JSON=$(curl -sf --max-time 8 "https://ipinfo.io/json" 2>/dev/null || true)

LATITUDE=""
LONGITUDE=""
LOCATION_LABEL=""

if [[ -n "${GEO_JSON}" ]]; then
    # Format: "loc": "lat,lon"
    LOC_STR=$(echo "${GEO_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('loc',''))" 2>/dev/null || true)
    CITY=$(echo "${GEO_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('city',''))" 2>/dev/null || true)
    COUNTRY=$(echo "${GEO_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('country',''))" 2>/dev/null || true)
    LATITUDE=$(echo "${LOC_STR}" | cut -d',' -f1)
    LONGITUDE=$(echo "${LOC_STR}" | cut -d',' -f2)
    LOCATION_LABEL="${CITY}, ${COUNTRY}"
    info "Geschätzter Standort: ${LOCATION_LABEL} (${LATITUDE}, ${LONGITUDE})"
else
    warn "Geolokalisierung nicht verfügbar."
fi

# ── Suchradius festlegen ──────────────────────────────────────────────────────
search_nearby_boxes() {
    local lat="$1" lon="$2" radius_km="${3:-25}"
    local radius_m=$(( radius_km * 1000 ))
    local url="https://api.opensensemap.org/boxes?near=${lon},${lat}&maxDistance=${radius_m}&full=true"

    info "Suche SenseBoxen im Umkreis von ${radius_km} km …"
    curl -sf --max-time 15 "${url}" 2>/dev/null || true
}

display_and_select_box() {
    local boxes_json="$1"
    local tmp_boxes
    tmp_boxes=$(mktemp /tmp/sensebox_boxes.XXXXXX.json)
    echo "${boxes_json}" > "${tmp_boxes}"

    local _filter_script
    _filter_script=$(cat << 'PYEOF'
import sys, json
from datetime import datetime, timezone, timedelta

with open(sys.argv[1]) as f:
    raw = f.read().strip()
try:
    boxes = json.loads(raw)
except json.JSONDecodeError:
    boxes = []

now = datetime.now(timezone.utc)
cutoff = now - timedelta(hours=24)

result = []
for b in boxes:
    last = b.get("lastMeasurementAt") or b.get("updatedAt") or ""
    name = b.get("name", "?")
    bid  = b.get("_id", "")
    desc = b.get("description", "")
    sensors = b.get("sensors", [])
    sensor_count = len(sensors)

    active = False
    if last:
        try:
            ts = datetime.fromisoformat(last.replace("Z", "+00:00"))
            active = ts >= cutoff
        except ValueError:
            pass

    if active and bid:
        result.append({
            "id": bid,
            "name": name,
            "last": last[:16].replace("T"," "),
            "sensors": sensor_count,
            "desc": desc[:60] if desc else "",
        })

if len(sys.argv) > 2 and sys.argv[2] == "count":
    print(len(result))
elif len(sys.argv) > 2:
    idx = int(sys.argv[2]) - 1
    if 0 <= idx < len(result):
        print(result[idx]["id"])
        print(result[idx]["name"])
else:
    for i, r in enumerate(result, 1):
        print(f"{i:3}. [{r['id']}]  {r['name']}")
        print(f"       Zuletzt aktiv: {r['last']}  |  Sensoren: {r['sensors']}")
        if r["desc"]:
            print(f"       {r['desc']}")
PYEOF
)

    local _py_script
    _py_script=$(mktemp /tmp/sensebox_filter.XXXXXX.py)
    echo "${_filter_script}" > "${_py_script}"

    # Filtere aktive Boxen und zeige sie an
    local active_boxes
    active_boxes=$(python3 "${_py_script}" "${tmp_boxes}" 2>/dev/null || true)

    if [[ -z "${active_boxes}" ]]; then
        rm -f "${tmp_boxes}" "${_py_script}"
        return 1
    fi

    echo "${active_boxes}"
    echo ""

    # Anzahl aktiver Boxen ermitteln
    local count
    count=$(python3 "${_py_script}" "${tmp_boxes}" count 2>/dev/null || echo 0)

    local choice
    while true; do
        read -r -p "$(echo -e "${YELLOW}Nummer eingeben (1–${count}) oder [m] für manuelle ID-Eingabe: ${RESET}")" choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            local selected
            selected=$(python3 "${_py_script}" "${tmp_boxes}" "${choice}" 2>/dev/null || true)
            SELECTED_BOX_ID=$(echo "${selected}" | head -1)
            SELECTED_BOX_NAME=$(echo "${selected}" | tail -1)
            rm -f "${tmp_boxes}" "${_py_script}"
            return 0
        elif [[ "${choice,,}" == "m" ]]; then
            rm -f "${tmp_boxes}" "${_py_script}"
            return 2
        else
            warn "Ungültige Auswahl. Bitte eine Zahl zwischen 1 und ${count} eingeben."
        fi
    done
}

# ── SenseBox-Auswahl-Logik ────────────────────────────────────────────────────
select_sensebox() {
    local boxes_json search_result=1

    if [[ -n "${LATITUDE}" && -n "${LONGITUDE}" ]]; then
        # Suche mit 25 km, bei keinem Ergebnis auf 100 km erweitern
        for radius in 25 100 250; do
            boxes_json=$(search_nearby_boxes "${LATITUDE}" "${LONGITUDE}" "${radius}")
            if [[ -n "${boxes_json}" && "${boxes_json}" != "[]" ]]; then
                local count
                count=$(echo "${boxes_json}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
                if (( count > 0 )); then
                    info "Gefunden: ${count} SenseBox(en) im Umkreis von ${radius} km"
                    break
                fi
            fi
            info "Keine aktiven Boxen im ${radius}-km-Radius – erweitere Suche …"
        done

        if [[ -n "${boxes_json}" && "${boxes_json}" != "[]" ]]; then
            title "Nahe SenseBoxen (aktiv in den letzten 24 h)"
            display_and_select_box "${boxes_json}"
            search_result=$?
        fi
    fi

    # Manuelle Eingabe (Fallback oder Nutzerwunsch)
    if [[ ${search_result} -ne 0 || "${SELECTED_BOX_ID}" == "" ]]; then
        echo ""
        info "Manuelle Box-ID-Eingabe (openSenseMap-Box-ID)"
        info "Beispiel: https://opensensemap.org/explore/69c2a0a3138cb800080087e5"
        read -r -p "$(echo -e "${YELLOW}Box-ID eingeben [aktuell: ${CURRENT_BOX_ID}]: ${RESET}")" manual_id
        manual_id="${manual_id:-${CURRENT_BOX_ID}}"
        if [[ -n "${manual_id}" ]]; then
            # Validieren
            info "Überprüfe Box-ID …"
            local check
            check=$(curl -sf --max-time 10 "https://api.opensensemap.org/boxes/${manual_id}" 2>/dev/null || true)
            if [[ -n "${check}" ]]; then
                SELECTED_BOX_ID="${manual_id}"
                SELECTED_BOX_NAME=$(echo "${check}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','?'))" 2>/dev/null || echo "?")
                log "Box gefunden: ${SELECTED_BOX_NAME}"
            else
                warn "Box-ID konnte nicht verifiziert werden – wird trotzdem verwendet."
                SELECTED_BOX_ID="${manual_id}"
                SELECTED_BOX_NAME="(unbekannt)"
            fi
        else
            warn "Keine Box-ID eingegeben – aktuelle ID wird beibehalten."
            SELECTED_BOX_ID="${CURRENT_BOX_ID}"
            SELECTED_BOX_NAME="(beibehalten)"
        fi
    fi
}

select_sensebox

log "Gewählte Box: ${SELECTED_BOX_NAME} [${SELECTED_BOX_ID}]"

# =============================================================================
# 4. Logos konfigurieren
# =============================================================================
title "Logo-Konfiguration (bis zu 3 Logos)"

LOGO_URLS=("" "" "")

# ── CLI-Bildsuche via DuckDuckGo ──────────────────────────────────────────────
cli_image_search() {
    local query="$1"
    info "Suche Bilder für: \"${query}\" …"

    # DDG Instant-Answer API gibt keine Bilder, aber wir können die Bilder aus
    # der HTML-Lite-Seite extrahieren (fragil, aber ohne API-Key nutzbar)
    local search_url="https://duckduckgo.com/html/?q=${query// /+}+logo&ia=images"
    local html
    html=$(curl -sA "Mozilla/5.0" --max-time 10 "${search_url}" 2>/dev/null || true)

    if [[ -z "${html}" ]]; then
        warn "Bildsuche nicht verfügbar. Bitte URL direkt eingeben."
        return 1
    fi

    # Extrahiere Bild-URLs aus href-Attributen (DDG leitet über result-URL weiter)
    local urls
    urls=$(echo "${html}" | python3 - <<'PYEOF'
import sys, re, urllib.parse

html = sys.stdin.read()
# DDG-HTML: Links zur Bildsuche enthalten "uddg=" Parameter (URL-encoded Bild-URL)
pattern = re.compile(r'uddg=([^&"]+)', re.IGNORECASE)
seen = set()
count = 0
for m in pattern.finditer(html):
    url = urllib.parse.unquote(m.group(1))
    if url not in seen and url.startswith("http") and any(
        url.lower().endswith(ext) for ext in (".png",".jpg",".jpeg",".svg",".webp",".gif")
    ):
        seen.add(url)
        count += 1
        print(f"{count:3}. {url}")
        if count >= 10:
            break
PYEOF
    )

    if [[ -z "${urls}" ]]; then
        warn "Keine Bildtreffer gefunden. Bitte URL direkt eingeben."
        return 1
    fi

    echo "${urls}"
    return 0
}

configure_logo() {
    local slot="$1"
    local logo_url=""

    echo ""
    echo -e "${BOLD}Logo ${slot} von 3${RESET}"
    echo "  [1] Per Suchbegriff suchen"
    echo "  [2] URL direkt eingeben"
    echo "  [3] Diesen Logo-Slot überspringen"
    echo ""

    local mode
    while true; do
        read -r -p "$(echo -e "${YELLOW}Auswahl (1/2/3): ${RESET}")" mode
        case "${mode}" in
            1)
                read -r -p "$(echo -e "${YELLOW}Suchbegriff (z.B. Schulname Logo): ${RESET}")" query
                if [[ -z "${query}" ]]; then
                    warn "Kein Suchbegriff – überspringe."
                    return
                fi
                local results
                local tmp_img_results
                tmp_img_results=$(mktemp /tmp/sensebox_img.XXXXXX.txt)
                if cli_image_search "${query}" > "${tmp_img_results}" 2>&1; then
                    cat "${tmp_img_results}"
                    echo ""
                    local img_count
                    img_count=$(grep -c "^\s*[0-9]" "${tmp_img_results}" || true)
                    local num
                    while true; do
                        read -r -p "$(echo -e "${YELLOW}Nummer wählen (1–${img_count}) oder [u] für eigene URL oder [s] überspringen: ${RESET}")" num
                        if [[ "${num}" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= img_count )); then
                            logo_url=$(awk "NR==${num}" "${tmp_img_results}" | sed 's/^[[:space:]]*[0-9]*\. //')
                            break
                        elif [[ "${num,,}" == "u" ]]; then
                            read -r -p "$(echo -e "${YELLOW}URL eingeben: ${RESET}")" logo_url
                            break
                        elif [[ "${num,,}" == "s" ]]; then
                            logo_url=""
                            break
                        else
                            warn "Ungültige Eingabe."
                        fi
                    done
                else
                    warn "Suche fehlgeschlagen."
                    read -r -p "$(echo -e "${YELLOW}URL manuell eingeben (leer lassen = überspringen): ${RESET}")" logo_url
                fi
                rm -f "${tmp_img_results}"
                ;;
            2)
                read -r -p "$(echo -e "${YELLOW}Logo-URL (leer lassen = überspringen): ${RESET}")" logo_url
                ;;
            3)
                info "Logo ${slot} übersprungen."
                return
                ;;
            *)
                warn "Bitte 1, 2 oder 3 eingeben."
                continue
                ;;
        esac
        break
    done

    if [[ -n "${logo_url}" ]]; then
        # Nur http/https-URLs erlauben
        if [[ ! "${logo_url}" =~ ^https?:// ]]; then
            warn "Ungültiges URL-Schema – nur http:// und https:// sind erlaubt. Logo übersprungen."
            return
        fi
        # Kurz-Validierung: URL erreichbar?
        if curl -sf --max-time 8 -I "${logo_url}" &>/dev/null; then
            log "Logo ${slot} gesetzt: ${logo_url}"
        else
            warn "URL nicht erreichbar – wird trotzdem gespeichert."
        fi
        LOGO_URLS[$((slot - 1))]="${logo_url}"
    else
        info "Logo ${slot} leer gelassen – wird nicht angezeigt."
    fi
}

for i in 1 2 3; do
    configure_logo "${i}"
done

# =============================================================================
# 5. Konfiguration schreiben
# =============================================================================
title "Konfiguration schreiben"

# ── BOX_ID in dashboard.py aktualisieren ─────────────────────────────────────
if [[ -n "${SELECTED_BOX_ID}" && "${SELECTED_BOX_ID}" != "${CURRENT_BOX_ID}" ]]; then
    sed -i "s|^BOX_ID = \".*\"|BOX_ID = \"${SELECTED_BOX_ID}\"|" "${DASHBOARD_PY}"
    log "BOX_ID in dashboard.py aktualisiert → ${SELECTED_BOX_ID}"
else
    info "BOX_ID unverändert (${CURRENT_BOX_ID})"
fi

# ── Logo-URLs in der Service-Datei aktualisieren ──────────────────────────────
update_service_logo() {
    local idx="$1" url="$2"
    if grep -q "SENSEBOX_LOGO_URL_${idx}=" "${SERVICE_FILE}"; then
        sed -i "s|Environment=SENSEBOX_LOGO_URL_${idx}=.*|Environment=SENSEBOX_LOGO_URL_${idx}=${url}|" "${SERVICE_FILE}"
    else
        # Füge fehlende Zeile im [Service]-Abschnitt ein
        sed -i "/^\[Service\]/a Environment=SENSEBOX_LOGO_URL_${idx}=${url}" "${SERVICE_FILE}"
    fi
}

for i in 1 2 3; do
    update_service_logo "${i}" "${LOGO_URLS[$((i-1))]}"
done
log "Logo-URLs in sensebox-dashboard.service geschrieben"

# ── Aktuellen Benutzernamen in der Service-Datei eintragen ────────────────────
CURRENT_USER="${USER:-$(whoami)}"
HOME_DIR="${HOME:-/home/${CURRENT_USER}}"

sed -i "s|^User=.*|User=${CURRENT_USER}|" "${SERVICE_FILE}"
sed -i "s|XAUTHORITY=.*|XAUTHORITY=${HOME_DIR}/.Xauthority|" "${SERVICE_FILE}"
sed -i "s|WorkingDirectory=.*|WorkingDirectory=${SCRIPT_DIR}|" "${SERVICE_FILE}"
sed -i "s|ExecStart=.*|ExecStart=${SCRIPT_DIR}/start.sh|" "${SERVICE_FILE}"
sed -i "s|StandardOutput=append:.*|StandardOutput=append:${SCRIPT_DIR}/dashboard.log|" "${SERVICE_FILE}"
sed -i "s|StandardError=append:.*|StandardError=append:${SCRIPT_DIR}/dashboard.log|" "${SERVICE_FILE}"
log "Service-Datei mit Nutzerpfaden aktualisiert (User=${CURRENT_USER})"

# =============================================================================
# 6. Autostart einrichten
# =============================================================================
title "Autostart einrichten"

echo "  [1] systemd-Service (empfohlen für Raspberry Pi)"
echo "  [2] XDG-Autostart-Eintrag (für Desktop-Anmeldung)"
echo "  [3] Kein Autostart"
echo ""

AUTOSTART_MODE=""
while true; do
    read -r -p "$(echo -e "${YELLOW}Autostart-Methode wählen (1/2/3): ${RESET}")" AUTOSTART_MODE
    case "${AUTOSTART_MODE}" in
        1|2|3) break ;;
        *) warn "Bitte 1, 2 oder 3 eingeben." ;;
    esac
done

case "${AUTOSTART_MODE}" in
    1)
        info "Installiere systemd-Service …"
        sudo cp "${SERVICE_FILE}" /etc/systemd/system/sensebox-dashboard.service
        sudo systemctl daemon-reload
        sudo systemctl enable sensebox-dashboard
        log "systemd-Service aktiviert"

        if confirm "Service jetzt sofort starten?"; then
            sudo systemctl restart sensebox-dashboard
            sleep 2
            sudo systemctl status sensebox-dashboard --no-pager || true
        fi
        ;;
    2)
        info "Erstelle XDG-Autostart-Eintrag …"
        mkdir -p "${HOME_DIR}/.config/autostart"
        cat > "${HOME_DIR}/.config/autostart/sensebox-dashboard.desktop" << EOF
[Desktop Entry]
Type=Application
Name=SenseBox Dashboard
Exec=${SCRIPT_DIR}/start.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
        log "Autostart-Eintrag erstellt: ${HOME_DIR}/.config/autostart/sensebox-dashboard.desktop"
        ;;
    3)
        info "Kein Autostart konfiguriert."
        ;;
esac

# =============================================================================
# 7. Abschlusszusammenfassung
# =============================================================================
title "Einrichtung abgeschlossen"

echo -e "${BOLD}Konfigurationsübersicht:${RESET}"
echo ""
echo -e "  SenseBox        : ${BOLD}${SELECTED_BOX_NAME}${RESET}"
echo -e "  Box-ID          : ${BOLD}${SELECTED_BOX_ID}${RESET}"
echo -e "  Logo 1          : ${LOGO_URLS[0]:-${CYAN}(kein Logo)${RESET}}"
echo -e "  Logo 2          : ${LOGO_URLS[1]:-${CYAN}(kein Logo)${RESET}}"
echo -e "  Logo 3          : ${LOGO_URLS[2]:-${CYAN}(kein Logo)${RESET}}"
case "${AUTOSTART_MODE}" in
    1) echo -e "  Autostart       : ${GREEN}systemd-Service${RESET}" ;;
    2) echo -e "  Autostart       : ${GREEN}XDG-Desktop-Eintrag${RESET}" ;;
    3) echo -e "  Autostart       : ${YELLOW}nicht konfiguriert${RESET}" ;;
esac
echo ""
echo -e "  Installationslog: ${LOGFILE}"
echo ""

echo -e "${BOLD}Dashboard manuell starten:${RESET}"
echo "  ${SCRIPT_DIR}/start.sh"
echo ""

if [[ "${AUTOSTART_MODE}" == "1" ]]; then
    echo -e "${BOLD}Service verwalten:${RESET}"
    echo "  sudo systemctl status sensebox-dashboard"
    echo "  sudo systemctl restart sensebox-dashboard"
    echo "  sudo systemctl stop sensebox-dashboard"
    echo "  journalctl -u sensebox-dashboard -f"
    echo ""
fi

echo -e "${GREEN}${BOLD}Einrichtung erfolgreich abgeschlossen!${RESET}"
echo ""
