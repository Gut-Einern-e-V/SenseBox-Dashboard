import unittest
import types
import sys

tk_module = types.ModuleType("tkinter")
tk_module.Tk = object
tk_module.Frame = object
tk_module.Label = object
tk_module.TclError = Exception
font_module = types.ModuleType("tkinter.font")
font_module.Font = object
tk_module.font = font_module
sys.modules.setdefault("tkinter", tk_module)
sys.modules.setdefault("tkinter.font", font_module)

from dashboard import display_icon_text, display_value, filter_recent_sensors, sensor_copy


class FilterRecentSensorsTests(unittest.TestCase):
    def test_filters_missing_and_outdated_measurements(self):
        sensors = [
            {
                "_id": "fresh",
                "title": "Temperature",
                "unit": "°C",
                "lastMeasurement": {
                    "value": "21.2",
                    "createdAt": "2026-05-12T10:00:00.000Z",
                },
            },
            {
                "_id": "stale",
                "title": "Humidity",
                "unit": "%",
                "lastMeasurement": {
                    "value": "52",
                    "createdAt": "2026-05-10T09:59:59.000Z",
                },
            },
            {
                "_id": "missing",
                "title": "CO2",
                "unit": "ppm",
                "lastMeasurement": {},
            },
        ]

        visible = filter_recent_sensors(sensors)

        self.assertEqual([sensor["_id"] for sensor in visible], ["fresh"])

    def test_keeps_values_up_to_one_day_older_than_newest(self):
        sensors = [
            {
                "_id": "fresh",
                "title": "Temperature",
                "unit": "°C",
                "lastMeasurement": {
                    "value": "21.2",
                    "createdAt": "2026-05-12T10:00:00.000Z",
                },
            },
            {
                "_id": "edge",
                "title": "Humidity",
                "unit": "%",
                "lastMeasurement": {
                    "value": "52",
                    "createdAt": "2026-05-11T10:00:00.000Z",
                },
            },
        ]

        visible = filter_recent_sensors(sensors)

        self.assertEqual([sensor["_id"] for sensor in visible], ["fresh", "edge"])


class SensorCopyTests(unittest.TestCase):
    def test_uses_child_friendly_copy_for_sound_sensor(self):
        copy = sensor_copy("Sound Level", "dB")

        self.assertEqual(copy["title"], "Lautstärke")
        self.assertIn("leise oder laut", copy["description"])

    def test_replaces_generic_value_title_with_unit_based_label(self):
        copy = sensor_copy("Value", "°C")

        self.assertEqual(copy["title"], "Temperatur")
        self.assertEqual(copy["icon"], "T")


class DisplayIconTextTests(unittest.TestCase):
    def test_hides_duplicate_word_icons(self):
        self.assertEqual(display_icon_text("Wind", "Wind"), "")
        self.assertEqual(display_icon_text("CO₂", "Kohlendioxid (CO₂)"), "")

    def test_keeps_short_distinct_icons(self):
        self.assertEqual(display_icon_text("T", "Temperatur"), "T")
        self.assertEqual(display_icon_text("RH", "Luftfeuchtigkeit"), "RH")


class DisplayValueTests(unittest.TestCase):
    def test_sound_values_show_word_and_keep_decibel_value(self):
        label, unit = display_value("72.4", "dB")

        self.assertEqual(label, "Laut")
        self.assertEqual(unit, " (72.4 dB)")

    def test_missing_sound_value_does_not_show_broken_decibel_text(self):
        label, unit = display_value("–", "dB")

        self.assertEqual(label, "–")
        self.assertEqual(unit, "")

    def test_regular_values_keep_numeric_unit_display(self):
        label, unit = display_value("21.2", "°C")

        self.assertEqual(label, "21.2")
        self.assertEqual(unit, " °C")


if __name__ == "__main__":
    unittest.main()
