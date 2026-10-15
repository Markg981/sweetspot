#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Integrazione Reference Studio: preferenze Material e shell CGI reale."""
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "board/sweetspot/rootfs-overlay"


class Elements(HTMLParser):
    def __init__(self):
        super().__init__()
        self.elements = []

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))


class ReferenceStudioTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sweetspot-studio-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "run/web").mkdir(parents=True)
        self.prefs = self.root / "lms/prefs"
        (self.prefs / "plugin").mkdir(parents=True)
        self.settings = self.prefs / "plugin/material-skin.prefs"
        (self.root / "run/sweetspot.conf").write_text("MODALITA=completa\n")
        self.assets = OVERLAY / "usr/share/sweetspot"
        self.env = dict(os.environ, SWEETSPOT_TEST="1",
                        SWEETSPOT_LIB=str(OVERLAY / "usr/lib/sweetspot"),
                        SWEETSPOT_RUN=str(self.root / "run"),
                        SWEETSPOT_LMS_DATA=str(self.root / "lms"),
                        SWEETSPOT_ASSETS=str(self.assets),
                        SWEETSPOT_DEFAULTS=str(OVERLAY / "etc/sweetspot/defaults.conf"),
                        SWEETSPOT_LOG=str(self.root / "log"),
                        LMS_SCRIPT=str(OVERLAY / "usr/bin/sweetspot-lms"))

    def shell(self, script, **env):
        return subprocess.run(["busybox", "sh"], input=script, capture_output=True,
                              text=True, env=dict(self.env, **env), timeout=10)

    def install(self, **env):
        result = self.shell('. "$LMS_SCRIPT"; material_theme', **env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def defaults(self):
        line = next(line for line in self.settings.read_text().splitlines()
                    if line.startswith("defaults:"))
        return json.loads(line.partition(":")[2].strip()[1:-1])

    def test_material_gets_official_theme_color_and_defaults(self):
        self.install()
        theme = self.prefs / "material-skin/themes/dark/Reference-Studio.css"
        color = self.prefs / "material-skin/colors/Reference-Studio.css"
        palette = (self.assets / "www/reference-studio.css").read_text()
        self.assertEqual(theme.read_text(), palette +
                         (self.assets / "material/reference-studio.css").read_text())
        self.assertEqual(color.read_text(), palette +
                         (self.assets / "material/reference-studio-colors.css").read_text())
        defaults = self.defaults()
        self.assertEqual(defaults["theme"], "user:dark/Reference-Studio")
        self.assertEqual(defaults["color"], "user:Reference-Studio")
        self.assertEqual(defaults["colorUsage"], 0)

    def test_existing_material_choices_are_not_overwritten(self):
        original = '---\ndefaults: \'{"theme":"light","color":"red","fontSize":"l"}\'\nother: 42\n'
        self.settings.write_text(original)
        self.install()
        self.assertEqual(self.settings.read_text(), original)

    def test_empty_defaults_are_initialized_without_losing_other_preferences(self):
        for empty in ("''", '""', "'{}'", "~"):
            with self.subTest(value=empty):
                self.settings.write_text("---\ndefaults: %s\nother: 42\n" % empty)
                self.install()
                self.assertEqual(self.defaults()["theme"], "user:dark/Reference-Studio")
                self.assertIn("other: 42\n", self.settings.read_text())

    def test_installation_is_idempotent(self):
        self.install()
        original = self.settings.read_bytes()
        self.install()
        self.assertEqual(self.settings.read_bytes(), original)
        self.assertFalse(list(self.prefs.rglob("*.tmp")))

    def test_missing_assets_are_reported_without_changing_preferences(self):
        original = "---\ndefaults: ''\nother: 42\n"
        self.settings.write_text(original)
        result = self.shell('. "$LMS_SCRIPT"; material_theme',
                            SWEETSPOT_ASSETS=str(self.root / "missing"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.settings.read_text(), original)
        self.assertTrue((self.root / "log").is_file(), "errore del tema non registrato")
        self.assertIn("Reference Studio", (self.root / "log").read_text())

    def test_settings_shell_has_semantic_navigation_and_local_assets(self):
        result = self.shell('''
export HTTP_HOST=127.0.0.1 SCRIPT_NAME=/cgi-bin/audio
. "$SWEETSPOT_LIB/web.sh"
page_start "Audio" audio
page_end
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        parser = Elements()
        parser.feed(result.stdout)
        self.assertIn(("main", {"id": "contenuto", "tabindex": "-1"}), parser.elements)
        self.assertTrue(any(tag == "nav" and attrs.get("aria-label") == "Impostazioni SweetSpot"
                            for tag, attrs in parser.elements))
        links = [attrs for tag, attrs in parser.elements if tag == "a"]
        self.assertTrue(any(a.get("href") == "#contenuto" for a in links))
        audio = next(a for a in links if a.get("href") == "/cgi-bin/audio")
        self.assertEqual(audio.get("aria-current"), "page")
        styles = [attrs["href"] for tag, attrs in parser.elements
                  if tag == "link" and attrs.get("rel") == "stylesheet"]
        self.assertTrue(any(href.startswith("/reference-studio.css") for href in styles))
        self.assertTrue(all(href.startswith("/") for href in styles))


if __name__ == "__main__":
    unittest.main()
