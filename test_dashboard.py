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

from dashboard import filter_recent_sensors


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


if __name__ == "__main__":
    unittest.main()
