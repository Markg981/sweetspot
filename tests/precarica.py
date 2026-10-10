#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile sweetspot-precarica and check holding, state and residency.

Files stay small: an unprivileged mlock is limited by RLIMIT_MEMLOCK.
Needs a C compiler (cc, or CC=gcc).
"""
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "package/sweetspot-tools/src/sweetspot-precarica.c"


class PreloadToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-precarica-")
        cls.tool = Path(cls.temp.name) / "sweetspot-precarica"
        subprocess.run([os.environ.get("CC", "cc"), "-O2", "-Wall", "-Wextra", "-Werror",
                        "-o", str(cls.tool), str(SOURCE)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def wait_state(self, state, phase, process):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if state.exists() and state.read_text().startswith("stato\t%s\n" % phase):
                return state.read_text()
            self.assertIsNone(process.poll(), "holder exited early")
            time.sleep(.05)
        self.fail("state %s not reached" % phase)

    def test_holds_listed_files_reports_each_result_and_stops_on_term(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first = root / "Album è" / "a.flac"
            first.parent.mkdir()
            first.write_bytes(os.urandom(300000))
            second = root / "Album è" / "b c.flac"
            second.write_bytes(os.urandom(5000))
            empty = root / "vuoto.flac"
            empty.write_bytes(b"")
            listing = root / "elenco"
            listing.write_text("\n".join(map(str, (first, second, root / "manca.flac", root, empty))) + "\n")
            state = root / "stato"
            process = subprocess.Popen([str(self.tool), "tieni", str(listing), str(state)])
            try:
                text = self.wait_state(state, "pronto", process)
                rows = [line.split("\t") for line in text.splitlines()[1:]]
                self.assertEqual([row[0] for row in rows], ["file"] * 5)
                self.assertEqual([row[3] for row in rows], [str(first), str(second), str(root / "manca.flac"),
                                                              str(root), str(empty)])
                self.assertEqual(rows[0][1:3], ["300000", "ok"])
                self.assertEqual(rows[1][1:3], ["5000", "ok"])
                self.assertTrue(rows[2][2].startswith("errore: "))
                self.assertEqual(rows[3][2], "errore: non e' un file")
                self.assertEqual(rows[4][1:3], ["0", "ok"])
                residency = subprocess.run([str(self.tool), "residenza", str(first), str(second)],
                                           capture_output=True, text=True, check=True).stdout
                self.assertEqual(residency, "300000\t300000\t%s\n5000\t5000\t%s\n" % (first, second))
            finally:
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(5), 0)

    def test_usage_errors_are_rejected(self):
        for args in ([], ["tieni"], ["tieni", "solo-elenco"], ["residenza"], ["altro", "x"]):
            with self.subTest(args=args):
                self.assertEqual(subprocess.run([str(self.tool)] + args, capture_output=True).returncode, 2)
        missing = subprocess.run([str(self.tool), "tieni", "/non/esiste", "/tmp/stato-inutile"],
                                 capture_output=True)
        self.assertEqual(missing.returncode, 2)
        unreadable = subprocess.run([str(self.tool), "residenza", "/non/esiste"], capture_output=True)
        self.assertEqual(unreadable.returncode, 1)


if __name__ == "__main__":
    unittest.main()
