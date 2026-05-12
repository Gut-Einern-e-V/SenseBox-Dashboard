# SenseBox-Dashboard

Ein automatisch aktualisierendes Vollbild-Dashboard für eine SenseBox-Klimastation.  
Die Sensordaten werden live von der öffentlichen SenseBox-API geladen und auf einem TV/Monitor dargestellt.

---

## 📸 Features

- **Vollbild-Anzeige** – startet direkt im Vollbild und ist für Raspberry Pi mit HDMI-Fernseher optimiert
- **Automatische Aktualisierung** – Daten werden alle 60 Sekunden neu geladen
- **Alle Sensoren** – Temperatur, Luftfeuchtigkeit, CO₂, Feinstaub, UV, Luftdruck u.v.m.
- **Ampel-Farbsystem** – grün / gelb / rot je nach Messwert
- **Weniger Flackern** – vorhandene Sensorkarten werden beim Update nur noch inhaltlich aktualisiert
- **Logo-Slots** – drei optionale Logos können per URL eingebunden werden
- **Robustheit** – kein Absturz bei Netzwerkausfall; zeigt zuletzt bekannte Werte
- **Deutsch** – vollständig auf Deutsch

---

## 🖥️ Voraussetzungen

| Komponente | Anforderung |
|---|---|
| Betriebssystem | Raspberry Pi OS (Debian) / Ubuntu / Linux |
| Python | 3.7 oder neuer (3.9+ empfohlen) |
| Pakete | `python3-tk` (System), `requests`, `Pillow` (pip) |
| Netzwerk | Internetzugang für openSenseMap API |

---

## 🚀 Installation

### 1. Repository klonen

```bash
git clone https://github.com/Gut-Einern-e-V/SenseBox-Dashboard.git
cd SenseBox-Dashboard
```

### 2. Systemabhängigkeiten installieren (einmalig)

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-tk python3-pip python3-venv
```

### 3. Dashboard starten

```bash
chmod +x start.sh
./start.sh
```

Das Skript erstellt automatisch eine virtuelle Python-Umgebung und installiert alle benötigten Pakete.

### 4. Optional: Logos per URL konfigurieren

Es gibt drei Logo-Slots in der Kopfzeile. Sie werden über Umgebungsvariablen gesetzt:

```bash
export SENSEBOX_LOGO_URL_1="https://example.org/logo-1.png"
export SENSEBOX_LOGO_URL_2="https://example.org/logo-2.png"
export SENSEBOX_LOGO_URL_3="https://example.org/logo-3.png"
./start.sh
```

---

## ⌨️ Tastenkombinationen

| Taste | Funktion |
|---|---|
| `Esc` oder `q` | Programm beenden |
| `F11` | Vollbild umschalten |

---

## 🔄 Autostart beim Raspberry Pi (im Vollbild)

Die Anwendung startet selbstständig im Vollbild. Für Raspberry Pi empfiehlt sich daher ein Autostart nach der grafischen Anmeldung.

### Option A: systemd-Service (empfohlen)

```bash
# Service-Datei kopieren
sudo cp sensebox-dashboard.service /etc/systemd/system/

# Pfade und optionale Logo-URLs anpassen, falls nötig
sudo nano /etc/systemd/system/sensebox-dashboard.service

# Service aktivieren und starten
sudo systemctl daemon-reload
sudo systemctl enable sensebox-dashboard
sudo systemctl start sensebox-dashboard

# Status prüfen
sudo systemctl status sensebox-dashboard
```

### Option B: Autostart-Datei (für Desktop-Modus)

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/sensebox-dashboard.desktop << EOF
[Desktop Entry]
Type=Application
Name=SenseBox Dashboard
Exec=/home/pi/SenseBox-Dashboard/start.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
```

---

## ⬆️ Update einspielen

```bash
cd /home/pi/SenseBox-Dashboard
git pull
./start.sh
```

Wenn das Dashboard per systemd läuft:

```bash
sudo systemctl restart sensebox-dashboard
```

---

## 📁 Projektstruktur

```
SenseBox-Dashboard/
├── dashboard.py                   # Hauptprogramm (Python/tkinter)
├── requirements.txt               # Python-Abhängigkeiten
├── start.sh                       # Startskript mit venv-Setup
├── sensebox-dashboard.service     # systemd-Service-Definition
└── README.md                      # Diese Datei
```

---

## 🌐 Datenquelle

Die Daten kommen von der öffentlichen [openSenseMap API](https://api.opensensemap.org/):

```
GET https://api.opensensemap.org/boxes/69c2a0a3138cb800080087e5
```

Alle Sensordaten sind öffentlich unter [opensensemap.org/explore/69c2a0a3138cb800080087e5](https://opensensemap.org/explore/69c2a0a3138cb800080087e5) einsehbar.

---

## 🛠️ Anpassung

Die wichtigsten Einstellungen befinden sich am Anfang von `dashboard.py`:

```python
BOX_ID = "69c2a0a3138cb800080087e5"      # openSenseMap Box-ID
REFRESH_INTERVAL_SEC = 60                 # Aktualisierungsintervall (Sekunden)
API_TIMEOUT_SEC = 15                      # Netzwerk-Timeout
RETRY_DELAY_SEC = 30                      # Wartezeit bei Fehler
```

Optionale Logos werden über diese Umgebungsvariablen gesetzt:

```bash
SENSEBOX_LOGO_URL_1
SENSEBOX_LOGO_URL_2
SENSEBOX_LOGO_URL_3
```

Sensoren ohne Messwert sowie Werte, die mehr als 24 Stunden älter als der neueste Messwert der Box sind, werden automatisch ausgeblendet.

---

## 📊 Ampel-System

| Farbe | Bedeutung |
|---|---|
| 🟢 Grün | Wert im normalen Bereich |
| 🟡 Gelb | Wert leicht erhöht – aufmerksam sein |
| 🔴 Rot | Wert stark erhöht – Maßnahmen erwägen |

---

## 🐛 Fehlersuche

```bash
# Logs anzeigen
tail -f dashboard.log

# Manueller Start mit Log-Ausgabe
python3 dashboard.py

# Service-Status (bei systemd)
sudo systemctl status sensebox-dashboard
journalctl -u sensebox-dashboard -f
```

---
