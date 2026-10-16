#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile sweetspot-precarica and check holding, state and residency.

Files stay small: an unprivileged mlock is limited by RLIMIT_MEMLOCK.
Needs a C compiler (cc, or CC=gcc).
"""
import os
import json
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "package/sweetspot-tools/src/sweetspot-precarica.c"
OVERLAY = Path(__file__).resolve().parents[1] / "board/sweetspot/rootfs-overlay"


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

    def test_sigusr1_releases_files_removed_from_the_list(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            near = root / "vicino.flac"
            far = root / "lontano.flac"
            near.write_bytes(os.urandom(4000))
            far.write_bytes(os.urandom(4000))
            listing = root / "elenco"
            listing.write_text("%s\n%s\n" % (near, far))
            state = root / "stato"
            process = subprocess.Popen([str(self.tool), "tieni", str(listing), str(state)])
            try:
                self.wait_state(state, "pronto", process)
                listing.write_text("%s\n" % near)
                process.send_signal(signal.SIGUSR1)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and str(far) in state.read_text():
                    time.sleep(.05)
                text = state.read_text()
                self.assertIn(str(near), text)
                self.assertNotIn(str(far), text)
                self.assertIsNone(process.poll(), "holder must keep running")
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

    def test_manifest_above_4096_is_complete_and_reload_keeps_its_tail(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = [root / ("%04d.flac" % i) for i in range(4097)]
            for path in paths:
                path.touch()
            listing = root / "elenco"
            listing.write_text("".join("%s\n" % p for p in paths))
            state = root / "stato"
            process = subprocess.Popen([str(self.tool), "tieni", str(listing), str(state)])
            try:
                text = self.wait_state(state, "pronto", process)
                self.assertEqual(len(text.splitlines()) - 1, len(paths))
                self.assertIn("file\t0\tok\t%s\n" % paths[-1], text)
                listing.write_text("".join("%s\n" % p for p in reversed(paths[1:])))
                process.send_signal(signal.SIGUSR1)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and str(paths[0]) in state.read_text():
                    time.sleep(.05)
                text = state.read_text()
                self.assertNotIn(str(paths[0]), text)
                self.assertIn("file\t0\tok\t%s\n" % paths[-1], text)
                self.assertEqual(len(text.splitlines()) - 1, len(paths) - 1)
            finally:
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(5), 0)


class PreloadControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sweetspot-precarico-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / "run"
        self.run.mkdir()
        proc = self.root / "proc"
        proc.mkdir()
        (proc / "meminfo").write_text("MemTotal: 8388608 kB\nMemAvailable: 4194304 kB\n")
        (self.run / "sweetspot.conf").write_text("MODALITA=completa\n")
        (self.run / "precarico.tieni.pid").write_text(str(os.getpid()))
        self.env = dict(os.environ, SWEETSPOT_TEST="1",
                        SWEETSPOT_LIB=str(OVERLAY / "usr/lib/sweetspot"),
                        SWEETSPOT_RUN=str(self.run), SWEETSPOT_PROCFS=str(proc),
                        SWEETSPOT_DEFAULTS=str(OVERLAY / "etc/sweetspot/defaults.conf"),
                        SWEETSPOT_LOG=str(self.root / "log"),
                        PRELOAD_SCRIPT=str(OVERLAY / "usr/bin/sweetspot-precarico"))

    def shell(self, command):
        result = subprocess.run(["busybox", "sh", "-c", '. "$PRELOAD_SCRIPT"; ' + command],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_held_memory_counts_only_successful_results(self):
        (self.run / "precarico.piano").write_text("SI 1048576 /missing.flac\nSI 8 /good.flac\n")
        for phase in ("caricamento", "pronto"):
            with self.subTest(phase=phase):
                (self.run / "precarico.stato").write_text(
                    "stato\t%s\nfile\t1073741824\terrore: Cannot allocate memory\t/missing.flac\n"
                    "file\t4096\tok\t/good.flac\nfile\t4096\tin attesa\t/wait.flac\n" % phase)
                self.assertEqual(self.shell("precarico_tenuto_kb"), "4")
        (self.run / "precarico.stato").unlink()
        self.assertEqual(self.shell("precarico_tenuto_kb"), "0")

    def test_summary_uses_loaded_bytes_not_planned_bytes(self):
        (self.run / "precarico.piano").write_text("SI 2048 /good.flac\nSI 3072 /bad.flac\n")
        (self.run / "precarico.stato").write_text(
            "stato\tpronto\nfile\t2097152\tok\t/good.flac\n"
            "file\t3145728\terrore: Cannot allocate memory\t/bad.flac\n")
        summary = json.loads(self.shell('write_summary parziale; cat "$SUMMARY"'))
        self.assertEqual(summary["caricati"], 1)
        self.assertEqual(summary["errori"], 1)
        self.assertEqual(summary["mb"], 2)

    def test_incomplete_holder_state_does_not_allow_disk_standby(self):
        (self.run / "precarico.piano").write_text("SI 1 /a.flac\nSI 1 /b.flac\n")
        (self.run / "precarico.coda").write_text("file:///a.flac\nfile:///b.flac\n")
        (self.run / "precarico.stato").write_text("stato\tpronto\nfile\t1024\tok\t/a.flac\n")
        self.shell('''
queue_urls() { cat "$URLS"; }
standby_disks() { touch "$RUN/standby-attempt"; }
step
''')
        self.assertFalse((self.run / "standby-attempt").exists())
        summary = json.loads((self.run / "precarico.json").read_text())
        self.assertEqual(summary["stato"], "parziale")
        self.assertEqual(summary["caricati"], 1)


if __name__ == "__main__":
    unittest.main()
