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

class StudioApiTests(unittest.TestCase):
    """CGI del Reference Studio con un sweetspot-priv FINTO: provano accesso,
    gettone, validazione e istradamento dei comandi, non Lyrion vero."""
    SID = "0123456789abcdef0123456789abcdef"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sweetspot-studio-api-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "run/web/sessioni").mkdir(parents=True)
        self.log = self.root / "priv.log"
        priv = self.root / "priv"
        priv.write_text('''#!/bin/sh
echo "$*" >> "%s"
case "$*" in
  *" albums "*) echo '{"result":{"count":1,"albums_loop":[{"id":7,"album":"A"}]}}' ;;
  *" bogus "*) exit 126 ;;
  *" boom "*) echo 'non json' ;;
  *) echo '{"result":{}}' ;;
esac
''' % self.log)
        priv.chmod(0o755)
        self.write_conf("MODALITA=completa\nPASSWORD_WEB=x\n")
        (self.root / "run/web/sessioni" / self.SID).write_text(str(2 ** 31))
        (self.root / "run/web.token").write_text("tok123\n")
        self.env = dict(os.environ, GATEWAY_INTERFACE="CGI/1.1", HTTP_HOST="127.0.0.1", REMOTE_ADDR="127.0.0.1",
                        SWEETSPOT_LIB=str(OVERLAY / "usr/lib/sweetspot"),
                        SWEETSPOT_RUN=str(self.root / "run"),
                        SWEETSPOT_DEFAULTS=str(OVERLAY / "etc/sweetspot/defaults.conf"),
                        SWEETSPOT_LOG=str(self.root / "log"), SWEETSPOT_PRIV=str(priv),
                        SWEETSPOT_ASSETS=str(OVERLAY / "usr/share/sweetspot"))

    def write_conf(self, text):
        for name in ("sweetspot.conf", "sweetspot.web"):
            (self.root / "run" / name).write_text(text)

    def cgi(self, name, method="GET", query="", body="", session=True, token=None):
        env = dict(self.env, REQUEST_METHOD=method, QUERY_STRING=query,
                   SCRIPT_NAME="/cgi-bin/" + name, REQUEST_URI="/cgi-bin/" + name,
                   CONTENT_LENGTH=str(len(body)),
                   CONTENT_TYPE="application/x-www-form-urlencoded")
        if session:
            env["HTTP_COOKIE"] = "sweetspot_sid=" + self.SID
        if token:
            env["HTTP_X_SWEETSPOT_TOKEN"] = token
        script = OVERLAY / "usr/share/sweetspot/www/cgi-bin" / name
        r = subprocess.run(["busybox", "sh", str(script)], input=body, capture_output=True,
                           text=True, env=env, timeout=20)
        head, _, payload = r.stdout.partition("\n\n")
        status = 200
        for line in head.split("\n"):
            if line.startswith("Status:"):
                status = int(line.split()[1])
        return status, head, payload

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_without_session_api_is_401_and_page_redirects(self):
        status, _, _ = self.cgi("studio-api.json", query="op=albums", session=False)
        self.assertEqual(status, 401)
        status, head, _ = self.cgi("studio", session=False)
        self.assertEqual(status, 303)
        self.assertIn("/cgi-bin/accesso", head)
        status, head, body = self.cgi("studio-copertina", query="id=ab&s=96", session=False)
        self.assertEqual(status, 200)
        self.assertIn("image/svg+xml", head)
        self.assertEqual(self.calls(), [])

    def test_read_albums_returns_result_and_uses_allowlisted_command(self):
        status, _, body = self.cgi("studio-api.json", query="op=albums&count=10&search=ab")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertTrue(data["ok"])
        self.assertEqual(data["result"]["albums_loop"][0]["album"], "A")
        self.assertIn("sweetspot-lms json  albums 0 10", self.calls()[0])
        self.assertIn("search:ab", self.calls()[0])

    def test_invalid_parameters_are_rejected_before_lyrion(self):
        for q in ("op=albums&count=0", "op=albums&count=999", "op=albums&start=x",
                  "op=albums&sort=evil", "op=albums&genre_id=1;2", "op=stato",
                  "op=stato&player=zz zz", "op=nope"):
            with self.subTest(q=q):
                status, _, body = self.cgi("studio-api.json", query=q)
                self.assertEqual(status, 400, body)
        self.assertEqual(self.calls(), [])

    def test_post_requires_token(self):
        body = "op=play&player=aa:bb:cc:dd:ee:ff"
        status, _, _ = self.cgi("studio-api.json", "POST", body=body)
        self.assertEqual(status, 403)
        status, _, _ = self.cgi("studio-api.json", "POST", body=body, token="sbagliato")
        self.assertEqual(status, 403)
        self.assertEqual(self.calls(), [])
        status, _, _ = self.cgi("studio-api.json", "POST", body=body, token="tok123")
        self.assertEqual(status, 200)
        self.assertIn("play", self.calls()[0])

    def test_post_validation_and_mapping(self):
        mac = "player=aa:bb:cc:dd:ee:ff"
        bad = ("op=volume&v=101&" + mac, "op=carica&kind=x&id=1&mode=load&" + mac,
               "op=carica&kind=album&id=1&mode=rm&" + mac, "op=seek&v=-1&" + mac,
               "op=volume&v=5&player=;rm")
        for body in bad:
            with self.subTest(body=body):
                status, _, _ = self.cgi("studio-api.json", "POST", body=body, token="tok123")
                self.assertEqual(status, 400)
        self.assertEqual(self.calls(), [])
        self.cgi("studio-api.json", "POST", body="op=volume&v=40&" + mac, token="tok123")
        self.cgi("studio-api.json", "POST", body="op=carica&kind=album&id=7&mode=add&" + mac, token="tok123")
        self.assertIn("mixer volume 40", self.calls()[0])
        self.assertIn("playlistcontrol cmd:add album_id:7", self.calls()[1])

    def test_priv_refusal_and_bad_json_are_distinct_errors(self):
        status, _, body = self.cgi("studio-api.json", query="op=albums")
        self.assertEqual(status, 200)
        self.write_conf("MODALITA=player\nPASSWORD_WEB=x\n")
        status, _, body = self.cgi("studio-api.json", query="op=albums")
        self.assertEqual(status, 409)

    def test_page_exposes_token_and_assets_and_is_accessible(self):
        status, _, page = self.cgi("studio")
        self.assertEqual(status, 200)
        parser = Elements()
        parser.feed(page)
        metas = {a.get("name"): a.get("content") for t, a in parser.elements if t == "meta"}
        self.assertEqual(metas.get("sweetspot-token"), "tok123")
        srcs = [a.get("src") for t, a in parser.elements if t == "script"]
        self.assertTrue(any(s.startswith("/studio.js") for s in srcs))
        self.assertTrue(any(t == "nav" and a.get("aria-label") for t, a in parser.elements))
        self.assertIn(("main", {"id": "st-main", "tabindex": "-1"}),
                      [(t, a) for t, a in parser.elements if t == "main"])
        self.assertIn("/material/", page)

    def test_listen_url_default_and_material_choice(self):
        script = '. "$SWEETSPOT_LIB/web.sh"; listen_url'
        run = lambda: subprocess.run(["busybox", "sh"], input=script, capture_output=True,
                                     text=True, env=dict(self.env, GATEWAY_INTERFACE=""),
                                     timeout=10).stdout.strip()
        self.assertEqual(run(), "/cgi-bin/studio")
        self.write_conf("MODALITA=completa\nINTERFACCIA_ASCOLTO=material\n")
        self.assertEqual(run(), "http://127.0.0.1:9000/material/")

if __name__ == "__main__":
    unittest.main()
