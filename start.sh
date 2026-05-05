#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  start.sh – SenseBox-Dashboard Startskript
#  Für Raspberry Pi (Raspberry Pi OS / Debian-basiert)
# ─────────────────────────────────────────────────────────────────────────────
#
#  Verwendung:
#    chmod +x start.sh
#    ./start.sh
#
#  Autostart via systemd (empfohlen):
#    sudo cp sensebox-dashboard.service /etc/systemd/system/
#    sudo systemctl enable sensebox-dashboard
#    sudo systemctl start sensebox-dashboard
#
#  HINWEIS: Beim ersten Start wird versucht, python3-tk per apt-get zu
#           installieren, falls es fehlt. Dafür werden sudo-Rechte benötigt.
#           Für einen nicht-interaktiven Start (z.B. per systemd) sicherstellen,
#           dass python3-tk bereits installiert ist:
#             sudo apt-get install -y python3-tk
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
PYTHON_SCRIPT="${SCRIPT_DIR}/dashboard.py"
LOGFILE="${SCRIPT_DIR}/dashboard.log"

cd "${SCRIPT_DIR}"

echo "=== SenseBox-Dashboard ===" | tee -a "${LOGFILE}"
echo "Start: $(date)" | tee -a "${LOGFILE}"

# ── Python prüfen ──
if ! command -v python3 &>/dev/null; then
    echo "FEHLER: python3 nicht gefunden." | tee -a "${LOGFILE}"
    exit 1
fi

# ── Virtuelle Umgebung einrichten ──
if [ ! -d "${VENV_DIR}" ]; then
    echo "Erstelle virtuelle Python-Umgebung …" | tee -a "${LOGFILE}"
    python3 -m venv "${VENV_DIR}"
fi

# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"

# ── Abhängigkeiten installieren ──
echo "Prüfe Python-Abhängigkeiten …" | tee -a "${LOGFILE}"
pip install --quiet --upgrade pip
pip install --quiet -r "${SCRIPT_DIR}/requirements.txt"

# ── tkinter prüfen (systemweit installiert, nicht via pip) ──
if ! python3 -c "import tkinter" 2>/dev/null; then
    echo "FEHLER: tkinter nicht gefunden." | tee -a "${LOGFILE}"
    echo "Bitte ausführen: sudo apt-get install python3-tk" | tee -a "${LOGFILE}"
    # Versuche automatische Installation
    if command -v apt-get &>/dev/null; then
        echo "Versuche automatische Installation von python3-tk …" | tee -a "${LOGFILE}"
        sudo apt-get install -y python3-tk 2>&1 | tee -a "${LOGFILE}" || true
    fi
fi

# ── Display-Variable setzen (für SSH/Remote-Start) ──
export DISPLAY="${DISPLAY:-:0}"

# ── Dashboard starten (Neustart-Loop für Robustheit) ──
echo "Starte SenseBox-Dashboard …" | tee -a "${LOGFILE}"

RESTART_DELAY=5  # Sekunden vor Neustart nach Fehler

while true; do
    python3 "${PYTHON_SCRIPT}" 2>&1 | tee -a "${LOGFILE}"
    EXIT_CODE=${PIPESTATUS[0]}

    if [ "${EXIT_CODE}" -eq 0 ]; then
        echo "Dashboard normal beendet." | tee -a "${LOGFILE}"
        break
    else
        echo "Dashboard mit Fehlercode ${EXIT_CODE} beendet. Neustart in ${RESTART_DELAY}s …" | tee -a "${LOGFILE}"
        sleep "${RESTART_DELAY}"
    fi
done

echo "start.sh beendet: $(date)" | tee -a "${LOGFILE}"
