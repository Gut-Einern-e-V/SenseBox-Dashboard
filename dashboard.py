#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SenseBox-Dashboard – Vollbild-Anzeigesystem für die openSenseMap Klimastation
Für Gut-Einern e.V. | Schule Klasse 5–13

Automatische Aktualisierung alle 60 Sekunden.
Graceful error handling für Netzwerkausfälle.
"""
from __future__ import annotations

import tkinter as tk
from tkinter import font as tkfont
import threading
import time
import sys
import logging
import os
from datetime import datetime, timezone

try:
    import requests
    REQUESTS_OK = True
except ImportError:
    REQUESTS_OK = False

try:
    from PIL import Image, ImageTk
    import io
    PIL_OK = True
except ImportError:
    PIL_OK = False

# ─────────────────────────────────────────────
#  Konfiguration
# ─────────────────────────────────────────────
BOX_ID = "69c2a0a3138cb800080087e5"
API_URL = f"https://api.opensensemap.org/boxes/{BOX_ID}"
REFRESH_INTERVAL_SEC = 60      # Aktualisierungsintervall in Sekunden
API_TIMEOUT_SEC = 15           # Timeout für API-Anfragen
RETRY_DELAY_SEC = 30           # Wartezeit bei Fehler bis nächstem Versuch

# Logos: URLs der Logos (werden beim Start heruntergeladen, falls Pillow verfügbar)
LOGO_URLS = {
    "sensebox": "https://sensebox.de/images/sensebox-logo.png",
    "opensensemap": "https://opensensemap.org/img/osm-logo.png",
}

# ─────────────────────────────────────────────
#  Farbschema (Dunkel-Theme, TV-optimiert)
# ─────────────────────────────────────────────
COLORS = {
    "bg":              "#0d1117",   # Hintergrund
    "header_bg":       "#161b22",   # Kopfzeile
    "card_bg":         "#1c2128",   # Sensorkarten
    "card_border":     "#30363d",   # Kartenrahmen
    "card_hover":      "#21262d",   # Karte (Hervorhebung)
    "text_primary":    "#e6edf3",   # Haupttext
    "text_secondary":  "#8b949e",   # Nebentext
    "text_value":      "#ffffff",   # Messwert (weiß)
    "footer_bg":       "#161b22",   # Fußzeile
    "ok":              "#3fb950",   # Status: gut (grün)
    "warning":         "#d29922",   # Status: Warnung (gelb)
    "danger":          "#f85149",   # Status: Alarm (rot)
    "info":            "#58a6ff",   # Information (blau)
    "accent":          "#1f6feb",   # Akzent
    "logo_bg":         "#0d1117",   # Logo-Hintergrund
}

# Ampel-Grenzwerte für Sensoren (Einheit → [OK-Grenze, Warn-Grenze])
THRESHOLDS = {
    "°C":       (30, 35),     # Temperatur
    "%":        (60, 80),     # Luftfeuchtigkeit
    "ppm":      (1000, 2000), # CO₂
    "µg/m³":    (25, 50),     # Feinstaub
    "hPa":      (None, None), # Luftdruck (keine Grenzwerte)
    "lx":       (None, None), # Beleuchtungsstärke
    "µW/cm²":   (None, None), # UV
    "km/h":     (20, 40),     # Wind
    "mm/h":     (None, None), # Regen
}

# Sensor-Icons (Unicode) nach bekannten Sensor-Titeln
SENSOR_ICONS = {
    "temperatur":          "🌡",
    "temperature":         "🌡",
    "luftfeuchtigkeit":    "💧",
    "humidity":            "💧",
    "luftdruck":           "🌬",
    "air pressure":        "🌬",
    "pressure":            "🌬",
    "uv":                  "☀",
    "uv-intensität":       "☀",
    "uv intensity":        "☀",
    "beleuchtungsstärke":  "💡",
    "illuminance":         "💡",
    "licht":               "💡",
    "light":               "💡",
    "pm2.5":               "🌫",
    "pm10":                "🌫",
    "feinstaub":           "🌫",
    "fine dust":           "🌫",
    "co2":                 "🍃",
    "kohlendioxid":        "🍃",
    "carbon dioxide":      "🍃",
    "windgeschwindigkeit": "💨",
    "wind speed":          "💨",
    "wind":                "💨",
    "regen":               "🌧",
    "rain":                "🌧",
    "niederschlag":        "🌧",
}

# Bekannte Übersetzungen von Englisch → Deutsch
TRANSLATIONS = {
    "Temperature":           "Temperatur",
    "Humidity":              "Luftfeuchtigkeit",
    "rel. Humidity":         "Luftfeuchtigkeit",
    "Relative Humidity":     "Luftfeuchtigkeit",
    "Air Pressure":          "Luftdruck",
    "Pressure":              "Luftdruck",
    "UV Intensity":          "UV-Intensität",
    "UV-Intensität":         "UV-Intensität",
    "Illuminance":           "Beleuchtungsstärke",
    "Lux":                   "Beleuchtungsstärke",
    "PM2.5":                 "Feinstaub PM2,5",
    "PM10":                  "Feinstaub PM10",
    "CO2":                   "Kohlendioxid (CO₂)",
    "Wind Speed":            "Windgeschwindigkeit",
    "Windgeschwindigkeit":   "Windgeschwindigkeit",
    "Rainfall":              "Niederschlag",
    "Rain":                  "Niederschlag",
    "Niederschlag":          "Niederschlag",
}

# ─────────────────────────────────────────────
#  Logging einrichten
# ─────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
    ]
)
log = logging.getLogger(__name__)


# ─────────────────────────────────────────────
#  Hilfsfunktionen
# ─────────────────────────────────────────────
def sensor_icon(title: str) -> str:
    """Gibt ein passendes Emoji für den Sensor-Titel zurück."""
    key = title.lower()
    for k, icon in SENSOR_ICONS.items():
        if k in key:
            return icon
    return "📊"


def translate_title(title: str) -> str:
    """Übersetzt bekannte Sensor-Titel ins Deutsche."""
    return TRANSLATIONS.get(title, title)


def format_value(value: str, unit: str) -> str:
    """Formatiert Messwert mit passender Dezimalstellenanzahl."""
    try:
        num = float(value)
        if unit in ("ppm", "lx"):
            return f"{num:.0f}"
        if unit in ("hPa",):
            return f"{num:.1f}"
        return f"{num:.1f}"
    except (ValueError, TypeError):
        return str(value)


def value_color(value: str, unit: str) -> str:
    """Gibt die Farbe für den Ampel-Status zurück."""
    thresholds = THRESHOLDS.get(unit)
    if not thresholds or thresholds[0] is None:
        return COLORS["text_value"]
    try:
        num = float(value)
        ok_limit, warn_limit = thresholds
        if num <= ok_limit:
            return COLORS["ok"]
        if num <= warn_limit:
            return COLORS["warning"]
        return COLORS["danger"]
    except (ValueError, TypeError):
        return COLORS["text_value"]


def time_ago(iso_str: str) -> str:
    """Gibt eine menschenlesbare Zeitangabe zurück (z.B. 'vor 3 min')."""
    if not iso_str:
        return "–"
    try:
        ts = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        diff = datetime.now(timezone.utc) - ts
        secs = int(diff.total_seconds())
        if secs < 60:
            return f"vor {secs} Sek."
        if secs < 3600:
            return f"vor {secs // 60} Min."
        if secs < 86400:
            return f"vor {secs // 3600} Std."
        return f"vor {secs // 86400} Tagen"
    except Exception:
        return iso_str[:16]


def fetch_box_data() -> dict | None:
    """
    Holt Boxdaten von der openSenseMap API.
    Gibt None zurück bei Fehler (Netzwerk, Timeout, ungültige Daten).
    """
    if not REQUESTS_OK:
        log.error("Paket 'requests' nicht installiert. Bitte 'pip install requests' ausführen.")
        return None
    try:
        log.info("Lade Daten von openSenseMap API …")
        resp = requests.get(API_URL, timeout=API_TIMEOUT_SEC)
        resp.raise_for_status()
        data = resp.json()
        log.info(f"Daten erfolgreich geladen: Box '{data.get('name', 'Unbekannt')}'")
        return data
    except requests.exceptions.Timeout:
        log.warning("API-Anfrage abgelaufen (Timeout).")
    except requests.exceptions.ConnectionError:
        log.warning("Keine Verbindung zur API. Netzwerk verfügbar?")
    except requests.exceptions.HTTPError as e:
        log.error(f"HTTP-Fehler: {e}")
    except Exception as e:
        log.error(f"Unerwarteter Fehler beim Laden der Daten: {e}")
    return None


# ─────────────────────────────────────────────
#  Hauptanwendung
# ─────────────────────────────────────────────
class SenseBoxDashboard:
    """Vollbild-Dashboard zur Anzeige von SenseBox-Klimadaten."""

    def __init__(self, root: tk.Tk):
        self.root = root
        self.box_data: dict | None = None
        self.last_update: str = "–"
        self.status: str = "Verbinde …"
        self.status_color: str = COLORS["info"]
        self._sensor_frames: list = []
        self._stop_event = threading.Event()
        self._logo_images: dict = {}  # Verhindert Garbage Collection von Tkinter-Bildern

        self._setup_window()
        self._build_ui()
        self._start_refresh_thread()

    # ──────── Fenstereinrichtung ────────
    def _setup_window(self):
        self.root.title("SenseBox Klimadaten | Gut-Einern e.V.")
        self.root.configure(bg=COLORS["bg"])
        self.root.attributes("-fullscreen", True)
        self.root.bind("<Escape>", self._on_escape)
        self.root.bind("<F11>",    self._toggle_fullscreen)
        self.root.bind("<q>",      self._on_escape)

        # Schriften (fallback-sicher)
        self.font_title   = tkfont.Font(family="DejaVu Sans", size=28, weight="bold")
        self.font_station = tkfont.Font(family="DejaVu Sans", size=16)
        # Emoji-Schrift mit Fallback (Noto Emoji ist auf Raspberry Pi OS vorinstalliert;
        # tkinter fällt automatisch auf eine Systemschrift zurück, falls die Schrift fehlt)
        self.font_icon    = tkfont.Font(family="Noto Emoji", size=36)
        self.font_sensor  = tkfont.Font(family="DejaVu Sans", size=13, weight="bold")
        self.font_value   = tkfont.Font(family="DejaVu Sans Mono", size=34, weight="bold")
        self.font_unit    = tkfont.Font(family="DejaVu Sans", size=16)
        self.font_age     = tkfont.Font(family="DejaVu Sans", size=11)
        self.font_footer  = tkfont.Font(family="DejaVu Sans", size=13)
        self.font_logo    = tkfont.Font(family="DejaVu Sans", size=14, weight="bold")

    # ──────── UI aufbauen ────────
    def _build_ui(self):
        # ── Hauptcontainer ──
        self.main_frame = tk.Frame(self.root, bg=COLORS["bg"])
        self.main_frame.pack(fill="both", expand=True)

        # ── Kopfzeile ──
        self._build_header()

        # ── Trennlinie ──
        tk.Frame(self.main_frame, bg=COLORS["accent"], height=2).pack(
            fill="x", padx=0, pady=0
        )

        # ── Sensorbereich ──
        self.content_frame = tk.Frame(self.main_frame, bg=COLORS["bg"])
        self.content_frame.pack(fill="both", expand=True, padx=20, pady=10)

        self._build_placeholder()

        # ── Trennlinie ──
        tk.Frame(self.main_frame, bg=COLORS["card_border"], height=1).pack(
            fill="x", padx=0, pady=0
        )

        # ── Fußzeile ──
        self._build_footer()

    def _build_header(self):
        header = tk.Frame(self.main_frame, bg=COLORS["header_bg"], pady=12)
        header.pack(fill="x")

        # Links: Logos (Text-Fallback oder Bild)
        logo_left = tk.Frame(header, bg=COLORS["header_bg"])
        logo_left.pack(side="left", padx=20)
        self._add_logo_left(logo_left)

        # Mitte: Titel
        center_frame = tk.Frame(header, bg=COLORS["header_bg"])
        center_frame.pack(side="left", expand=True)

        tk.Label(
            center_frame,
            text="🌍  SenseBox Klimastation",
            font=self.font_title,
            bg=COLORS["header_bg"],
            fg=COLORS["text_primary"],
        ).pack()

        self.box_name_label = tk.Label(
            center_frame,
            text="Verbinde mit openSenseMap …",
            font=self.font_station,
            bg=COLORS["header_bg"],
            fg=COLORS["text_secondary"],
        )
        self.box_name_label.pack()

        # Rechts: Gut-Einern Logo
        logo_right = tk.Frame(header, bg=COLORS["header_bg"])
        logo_right.pack(side="right", padx=20)
        self._add_logo_right(logo_right)

    def _add_logo_left(self, parent: tk.Frame):
        """senseBox + openSenseMap Logos (Text-Fallback)."""
        tk.Label(
            parent,
            text="sense",
            font=tkfont.Font(family="DejaVu Sans", size=18, weight="bold"),
            bg=COLORS["header_bg"],
            fg="#00b4d8",
        ).pack(side="left")
        tk.Label(
            parent,
            text="Box",
            font=tkfont.Font(family="DejaVu Sans", size=18, weight="bold"),
            bg=COLORS["header_bg"],
            fg=COLORS["ok"],
        ).pack(side="left")
        tk.Label(
            parent,
            text="  ×  openSenseMap",
            font=tkfont.Font(family="DejaVu Sans", size=13),
            bg=COLORS["header_bg"],
            fg=COLORS["text_secondary"],
        ).pack(side="left")

    def _add_logo_right(self, parent: tk.Frame):
        """Gut-Einern e.V. Logo (Text)."""
        tk.Label(
            parent,
            text="Gut-Einern",
            font=tkfont.Font(family="DejaVu Sans", size=15, weight="bold"),
            bg=COLORS["header_bg"],
            fg="#4ade80",
        ).pack()
        tk.Label(
            parent,
            text="e.V. – Bildung & Nachhaltigkeit",
            font=tkfont.Font(family="DejaVu Sans", size=11),
            bg=COLORS["header_bg"],
            fg=COLORS["text_secondary"],
        ).pack()

    def _build_placeholder(self):
        """Zeigt Ladeanzeige, bis Daten verfügbar sind."""
        self.placeholder_frame = tk.Frame(self.content_frame, bg=COLORS["bg"])
        self.placeholder_frame.pack(fill="both", expand=True)
        tk.Label(
            self.placeholder_frame,
            text="⏳  Lade Sensordaten …",
            font=tkfont.Font(family="DejaVu Sans", size=22),
            bg=COLORS["bg"],
            fg=COLORS["text_secondary"],
        ).pack(expand=True)

    def _build_footer(self):
        footer = tk.Frame(self.main_frame, bg=COLORS["footer_bg"], pady=8)
        footer.pack(fill="x", side="bottom")

        # Links: Status
        self.status_label = tk.Label(
            footer,
            text="● Verbinde …",
            font=self.font_footer,
            bg=COLORS["footer_bg"],
            fg=COLORS["info"],
        )
        self.status_label.pack(side="left", padx=20)

        # Rechts: Uhrzeit + Letztes Update
        self.clock_label = tk.Label(
            footer,
            text="",
            font=self.font_footer,
            bg=COLORS["footer_bg"],
            fg=COLORS["text_secondary"],
        )
        self.clock_label.pack(side="right", padx=20)

        self.update_label = tk.Label(
            footer,
            text="Letztes API-Update: –",
            font=self.font_footer,
            bg=COLORS["footer_bg"],
            fg=COLORS["text_secondary"],
        )
        self.update_label.pack(side="right", padx=20)

        self._tick_clock()

    # ──────── Sensorkarten ────────
    def _rebuild_sensor_grid(self, sensors: list[dict]):
        """Baut das Sensorenraster neu auf."""
        # Alte Karten entfernen
        for frame in self._sensor_frames:
            frame.destroy()
        self._sensor_frames.clear()
        if self.placeholder_frame.winfo_exists():
            self.placeholder_frame.destroy()

        # Bestimme Grid-Spaltenanzahl dynamisch
        count = len(sensors)
        if count <= 3:
            cols = count
        elif count <= 6:
            cols = 3
        elif count <= 8:
            cols = 4
        else:
            cols = 4

        grid_frame = tk.Frame(self.content_frame, bg=COLORS["bg"])
        grid_frame.pack(fill="both", expand=True)
        self._sensor_frames.append(grid_frame)

        # Grid-Gewichte setzen
        rows = (count + cols - 1) // cols
        for c in range(cols):
            grid_frame.columnconfigure(c, weight=1, uniform="col")
        for r in range(rows):
            grid_frame.rowconfigure(r, weight=1, uniform="row")

        for idx, sensor in enumerate(sensors):
            row = idx // cols
            col = idx % cols
            self._create_sensor_card(grid_frame, sensor, row, col)

    def _create_sensor_card(
        self, parent: tk.Frame, sensor: dict, row: int, col: int
    ):
        """Erstellt eine einzelne Sensorkarte."""
        title_raw   = sensor.get("title", "Sensor")
        unit        = sensor.get("unit", "")
        last_meas   = sensor.get("lastMeasurement") or {}
        raw_value   = last_meas.get("value", "–")
        created_at  = last_meas.get("createdAt", "")

        title_de  = translate_title(title_raw)
        icon      = sensor_icon(title_raw)
        display_v = format_value(raw_value, unit) if raw_value != "–" else "–"
        color     = value_color(raw_value, unit)
        age_str   = time_ago(created_at) if created_at else "Kein Messwert"

        # Äußerer Rahmen
        outer = tk.Frame(parent, bg=COLORS["card_border"], padx=1, pady=1)
        outer.grid(row=row, column=col, padx=8, pady=8, sticky="nsew")

        card = tk.Frame(outer, bg=COLORS["card_bg"], padx=16, pady=12)
        card.pack(fill="both", expand=True)

        # Icon + Sensor-Titel
        header_f = tk.Frame(card, bg=COLORS["card_bg"])
        header_f.pack(fill="x")

        tk.Label(
            header_f,
            text=icon,
            font=self.font_icon,
            bg=COLORS["card_bg"],
            fg=COLORS["text_primary"],
        ).pack(side="left", padx=(0, 8))

        tk.Label(
            header_f,
            text=title_de,
            font=self.font_sensor,
            bg=COLORS["card_bg"],
            fg=COLORS["text_secondary"],
            wraplength=200,
            justify="left",
        ).pack(side="left", anchor="s", pady=(0, 2))

        # Trennlinie
        tk.Frame(card, bg=COLORS["card_border"], height=1).pack(fill="x", pady=6)

        # Messwert + Einheit
        value_f = tk.Frame(card, bg=COLORS["card_bg"])
        value_f.pack(fill="x", pady=4)

        tk.Label(
            value_f,
            text=display_v,
            font=self.font_value,
            bg=COLORS["card_bg"],
            fg=color,
        ).pack(side="left")

        tk.Label(
            value_f,
            text=f" {unit}",
            font=self.font_unit,
            bg=COLORS["card_bg"],
            fg=COLORS["text_secondary"],
            anchor="s",
        ).pack(side="left", padx=(4, 0), pady=(0, 2))

        # Zeitstempel
        tk.Label(
            card,
            text=f"Messung: {age_str}",
            font=self.font_age,
            bg=COLORS["card_bg"],
            fg=COLORS["text_secondary"],
        ).pack(anchor="w", pady=(4, 0))

    # ──────── UI aktualisieren ────────
    def _update_ui(self):
        """Aktualisiert die UI mit neuen Daten (muss im Tkinter-Haupt-Thread laufen)."""
        if self.box_data is None:
            self._set_status("⚠  Keine Verbindung – Versuche erneut …", COLORS["warning"])
            self.box_name_label.config(text="openSenseMap nicht erreichbar")
            return

        name = self.box_data.get("name", "Unbekannte Station")
        location_data = self.box_data.get("currentLocation", {})
        coords = location_data.get("coordinates", [])
        if len(coords) >= 2:
            loc_str = f"  📍 {coords[1]:.4f}°N, {coords[0]:.4f}°E"
        else:
            loc_str = ""

        self.box_name_label.config(text=f"📡  {name}{loc_str}")
        self._set_status("● Verbunden mit openSenseMap", COLORS["ok"])
        self.update_label.config(
            text=f"Letztes API-Update: {self.last_update}"
        )

        sensors = self.box_data.get("sensors", [])
        if sensors:
            self._rebuild_sensor_grid(sensors)
        else:
            self._set_status("⚠  Keine Sensoren gefunden", COLORS["warning"])

    def _set_status(self, msg: str, color: str):
        self.status_label.config(text=msg, fg=color)

    def _tick_clock(self):
        """Aktualisiert die Uhr jede Sekunde."""
        now = datetime.now().strftime("%H:%M:%S Uhr")
        self.clock_label.config(text=f"🕐  {now}")
        self.root.after(1000, self._tick_clock)

    # ──────── Hintergrund-Thread ────────
    def _start_refresh_thread(self):
        """Startet den Hintergrund-Thread für regelmäßige API-Abfragen."""
        self._thread = threading.Thread(
            target=self._refresh_loop,
            daemon=True,
            name="SenseBox-Refresh",
        )
        self._thread.start()
        log.info("Hintergrund-Thread gestartet.")

    def _refresh_loop(self):
        """Loop: Holt Daten von der API, plant nächste Abfrage."""
        while not self._stop_event.is_set():
            data = fetch_box_data()
            self.last_update = datetime.now().strftime("%H:%M:%S Uhr")
            if data is not None:
                self.box_data = data
                log.info("Sensordaten aktualisiert.")
            else:
                log.warning("Datenabruf fehlgeschlagen – behalte letzte Daten.")

            # UI-Update im Tkinter-Haupt-Thread einplanen
            try:
                self.root.after(0, self._update_ui)
            except tk.TclError:
                # Fenster wurde möglicherweise geschlossen
                break

            # Warte bis zum nächsten Intervall (in kleinen Schritten prüfbar)
            wait_seconds = (
                REFRESH_INTERVAL_SEC if data is not None else RETRY_DELAY_SEC
            )
            log.info(f"Nächste Aktualisierung in {wait_seconds} Sekunden.")
            for _ in range(wait_seconds * 2):
                if self._stop_event.is_set():
                    break
                time.sleep(0.5)

        log.info("Hintergrund-Thread beendet.")

    # ──────── Fenster-Events ────────
    def _on_escape(self, event=None):
        """Beendet die Anwendung sauber."""
        log.info("Anwendung wird beendet.")
        self._stop_event.set()
        self.root.destroy()

    def _toggle_fullscreen(self, event=None):
        state = self.root.attributes("-fullscreen")
        self.root.attributes("-fullscreen", not state)


# ─────────────────────────────────────────────
#  Startpunkt
# ─────────────────────────────────────────────
def main():
    if not REQUESTS_OK:
        print("FEHLER: Python-Paket 'requests' fehlt.")
        print("Bitte ausführen: pip install requests")
        sys.exit(1)

    log.info("SenseBox-Dashboard wird gestartet …")
    log.info(f"Box-ID: {BOX_ID}")
    log.info(f"Aktualisierungsintervall: {REFRESH_INTERVAL_SEC} Sekunden")

    root = tk.Tk()

    # Versuche, Cursor im Vollbild zu verstecken (TV-Modus)
    try:
        root.config(cursor="none")
    except tk.TclError:
        pass

    app = SenseBoxDashboard(root)

    try:
        root.mainloop()
    except KeyboardInterrupt:
        log.info("Beendet durch Benutzer (Strg+C).")
    except Exception as e:
        log.error(f"Unerwarteter Fehler: {e}", exc_info=True)
    finally:
        app._stop_event.set()
        log.info("SenseBox-Dashboard beendet.")


if __name__ == "__main__":
    main()
