#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Ripping con encoder FLAC reale: niente sovrascritture o file parziali."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "board/sweetspot/rootfs-overlay"

ENCODER = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import resource
import signal
import sys

if os.environ.get("ENCODER_FAULT") == "full":
    signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
    resource.setrlimit(resource.RLIMIT_FSIZE, (128, 128))
if os.environ.get("ENCODER_FAULT") == "race":
    Path(os.environ["DESTINATION"]).write_bytes(Path(os.environ["OLD_FLAC"]).read_bytes())
if os.environ.get("ENCODER_FAULT") == "oom":
    (Path(os.environ["TEST_ROOT"]) / "oom-score").write_text(Path("/proc/self/oom_score_adj").read_text())
os.execv(os.environ["REAL_FLAC"], [os.environ["REAL_FLAC"], *sys.argv[1:]])
'''


class CdSaveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.flac = shutil.which("flac")
        if not cls.flac:
            raise RuntimeError("Serve flac nel PATH")
        cls.build = tempfile.TemporaryDirectory(prefix="sweetspot-pubblica-")
        cls.addClassCleanup(cls.build.cleanup)
        cls.publisher = Path(cls.build.name) / "sweetspot-pubblica"
        subprocess.run([os.environ.get("CC", "cc"), "-O2", "-Wall", "-Wextra", "-Werror",
                        "-o", str(cls.publisher),
                        str(ROOT / "package/sweetspot-tools/src/sweetspot-pubblica.c")], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sweetspot-cd-save-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / "run"
        self.archive = self.root / "archive"
        self.destination = self.archive / "Artista/Album (2026)/01 - Brano.flac"
        for child in ("bin", "run/cd", "proc", "sys/block/sr0", "archive"):
            (self.root / child).mkdir(parents=True, exist_ok=True)
        source = self.root / "source.wav"
        with wave.open(str(source), "wb") as wav:
            wav.setnchannels(2)
            wav.setsampwidth(2)
            wav.setframerate(44100)
            wav.writeframes(os.urandom(32768))
        self.old_flac = self.root / "original.flac"
        subprocess.run([self.flac, "-s", "-T", "TITLE=Originale",
                        "-o", str(self.old_flac), str(source)], check=True)
        (self.run / "sweetspot.conf").write_text("MODALITA=completa\nLETTORE_OFFSET=0\n")
        (self.run / "cd/indice").write_text("1 0 75\n")
        (self.run / "cd/info.json").write_text(json.dumps({
            "album": "Album", "artist": "Artista", "year": "2026", "disc": 1, "discs": 1,
            "mbid": "", "discid": "test", "accuraterip": "1 00000000 00000000 00000000",
            "tracks": [{"n": 1, "title": "Brano", "artist": "Artista"}],
        }))
        commands = {
            "flac": ENCODER,
            "cd-paranoia": '#!/bin/sh\necho read >> "$TEST_ROOT/events"\nfor last; do :; done\ncp "$TEST_ROOT/source.wav" "$last"\n',
            "sweetspot-dischi": '#!/bin/sh\nprintf "%s\\n" "$TEST_ROOT/archive"\n',
            "sweetspot-lms": '#!/bin/sh\necho scan >> "$TEST_ROOT/events"\n',
            "sweetspot-arcrc": '#!/bin/sh\necho "0 0"\n',
            "curl": '#!/bin/sh\nexit 22\n',
            "eject": '#!/bin/sh\nexit 0\n',
            "mv": '#!/bin/sh\nexec busybox mv "$@"\n',
            "sync": '#!/bin/sh\nexit 0\n',
        }
        for name, content in commands.items():
            path = self.root / "bin" / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = dict(os.environ, SWEETSPOT_TEST="1",
                        SWEETSPOT_LIB=str(OVERLAY / "usr/lib/sweetspot"),
                        SWEETSPOT_RUN=str(self.run), SWEETSPOT_PROCFS=str(self.root / "proc"),
                        SWEETSPOT_SYSFS=str(self.root / "sys"),
                        SWEETSPOT_DEFAULTS=str(OVERLAY / "etc/sweetspot/defaults.conf"),
                        SWEETSPOT_LOG=str(self.root / "log"),
                        SWEETSPOT_PATH=str(self.root / "bin"),
                        TEST_ROOT=str(self.root), REAL_FLAC=self.flac,
                        SWEETSPOT_PUBBLICA=str(self.publisher),
                        DESTINATION=str(self.destination), OLD_FLAC=str(self.old_flac),
                        CD_SCRIPT=str(OVERLAY / "usr/bin/sweetspot-cd"))

    def rip(self, fault=""):
        result = subprocess.run(
            ["busybox", "sh", "-c", '. "$CD_SCRIPT"; oom_adj() { :; }; sync() { :; }; rip'],
            env=dict(self.env, ENCODER_FAULT=fault), capture_output=True, text=True, timeout=20)
        state = self.run / "cd/stato"
        self.assertTrue(state.exists(), result.stderr)
        return state.read_text()

    def test_existing_track_is_untouched_and_conflict_is_reported_before_reading(self):
        self.destination.parent.mkdir(parents=True)
        shutil.copyfile(self.old_flac, self.destination)
        cover = self.destination.parent / "cover.jpg"
        cover.write_bytes(b"copertina precedente")
        report = self.destination.parent / "sweetspot-copia.txt"
        report.write_text("rapporto precedente")
        state = self.rip()
        self.assertEqual(self.destination.read_bytes(), self.old_flac.read_bytes())
        self.assertTrue(state.startswith("errore|"), state)
        self.assertIn("esiste", state)
        self.assertFalse((self.root / "events").exists())
        self.assertEqual(cover.read_bytes(), b"copertina precedente")
        self.assertEqual(report.read_text(), "rapporto precedente")

    def test_encoder_failure_does_not_publish_a_partial_flac(self):
        state = self.rip("full")
        self.assertTrue(state.startswith("errore|"), state)
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.archive.rglob("*.part")))

    def test_track_created_during_encoding_is_not_replaced(self):
        state = self.rip("race")
        self.assertEqual(self.destination.read_bytes(), self.old_flac.read_bytes())
        self.assertTrue(state.startswith("errore|"), state)
        self.assertFalse(list(self.archive.rglob("*.part")))

    def test_completed_track_is_a_valid_flac_with_tags(self):
        state = self.rip()
        self.assertTrue(state.startswith("finita|"), state)
        subprocess.run([self.flac, "-s", "-t", str(self.destination)], check=True)
        tags = subprocess.run(["metaflac", "--export-tags-to=-", str(self.destination)],
                              check=True, capture_output=True, text=True).stdout
        self.assertIn("TITLE=Brano", tags)
        self.assertFalse(list(self.archive.rglob("*.part")))

    def test_encoder_inherits_background_job_oom_priority(self):
        result = subprocess.run(
            ["busybox", "sh", str(OVERLAY / "usr/bin/sweetspot-cd"), "_copia"],
            env=dict(self.env, SWEETSPOT_TEST="", SWEETSPOT_PROCFS="/proc", ENCODER_FAULT="oom"),
            text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "oom-score").read_text().strip(), "500")

    def test_concurrent_publications_have_exactly_one_winner(self):
        target = self.root / "published"
        sources = [self.root / ("candidate-%s" % i) for i in range(12)]
        for path in sources:
            path.write_text(path.name)
        processes = [subprocess.Popen([str(self.publisher), str(path), str(target)],
                                      stderr=subprocess.DEVNULL) for path in sources]
        results = [process.wait(10) for process in processes]
        self.assertEqual(results.count(0), 1)
        self.assertEqual(results.count(3), len(sources) - 1)
        winner = results.index(0)
        self.assertEqual(target.read_text(), sources[winner].name)
        for index, path in enumerate(sources):
            self.assertEqual(path.exists(), index != winner)

    def test_publisher_does_not_replace_a_dangling_symlink(self):
        target = self.root / "published"
        target.symlink_to(self.root / "missing")
        source = self.root / "candidate"
        source.write_text("nuovo")
        result = subprocess.run([str(self.publisher), str(source), str(target)],
                                capture_output=True)
        self.assertEqual(result.returncode, 3)
        self.assertTrue(target.is_symlink())
        self.assertEqual(source.read_text(), "nuovo")

    def test_publisher_rejects_a_fifo_without_waiting_for_a_writer(self):
        source = self.root / "fifo"
        target = self.root / "published"
        os.mkfifo(source)
        try:
            result = subprocess.run([str(self.publisher), str(source), str(target)],
                                    capture_output=True, timeout=2)
        except subprocess.TimeoutExpired:
            self.fail("la pubblicazione deve rifiutare una FIFO senza bloccarsi")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
