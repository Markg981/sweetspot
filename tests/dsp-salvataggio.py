#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Salvataggio dei filtri: errori espliciti, generazione precedente conservata."""
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "board/sweetspot/rootfs-overlay"
LEFT = "Filter 1: ON PK Fc 100 Hz Gain -3 dB Q 1\n"
RIGHT = "Filter 1: ON PK Fc 200 Hz Gain -2 dB Q 1\n"


class DspSaveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sweetspot-dsp-save-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / "run"
        self.ram = self.run / "correzione"
        self.disk = self.root / "stick/correzione-ambientale"
        self.ram.mkdir(parents=True)
        self.disk.mkdir(parents=True)
        for folder in (self.ram, self.disk):
            (folder / "sinistro.txt").write_text("precedente sinistro\n")
            (folder / "destro.txt").write_text("precedente destro\n")
            (folder / "fir-sinistro.wav").write_bytes(b"FIR precedente")
        (self.root / "left").write_bytes(LEFT.replace("\n", "\r\n").encode())
        (self.root / "right").write_text(RIGHT)
        self.env = dict(os.environ, SWEETSPOT_TEST="1",
                        SWEETSPOT_LIB=str(OVERLAY / "usr/lib/sweetspot"),
                        SWEETSPOT_RUN=str(self.run),
                        SWEETSPOT_STICK_DIR=str(self.root / "stick"),
                        SWEETSPOT_DEFAULTS=str(OVERLAY / "etc/sweetspot/defaults.conf"),
                        SWEETSPOT_LOG=str(self.root / "log"),
                        DSP_SCRIPT=str(OVERLAY / "usr/bin/sweetspot-dsp"),
                        TEST_ROOT=str(self.root))

    def save(self, fault="", right=True, mask="022"):
        script = r'''
. "$DSP_SCRIPT"
umask "$SAVE_UMASK"
stick_mount() { [ "$FAULT" != absent ]; }
stick_umount() { :; }
sync() { [ "$FAULT" != sync ]; }
cp() {
    for last; do :; done
    case "$FAULT:$last" in
        "disk:$STICK_MNT/"*|"ram:$RUN/"*) return 1 ;;
    esac
    command cp "$@"
}
mv() {
    for last; do :; done
    if [ "$FAULT" = publish ] && [ "$last" = "$STICK_MNT/correzione-ambientale" ]; then
        case "$1" in *.vecchio) ;; *) return 1 ;; esac
    fi
    command mv "$@"
}
do_save "$TEST_ROOT/left" "$RIGHT"
'''
        return subprocess.run(
            ["busybox", "sh"], input=script, text=True, capture_output=True, timeout=10,
            env=dict(self.env, FAULT=fault, SAVE_UMASK=mask,
                     RIGHT=str(self.root / "right") if right else ""))

    def assert_previous(self, folder):
        self.assertEqual((folder / "sinistro.txt").read_text(), "precedente sinistro\n")
        self.assertEqual((folder / "destro.txt").read_text(), "precedente destro\n")
        self.assertEqual((folder / "fir-sinistro.wav").read_bytes(), b"FIR precedente")

    def test_persistent_copy_failure_keeps_previous_filters_and_reports_ram_only(self):
        result = self.save("disk")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assert_previous(self.disk)
        self.assertEqual((self.ram / "sinistro.txt").read_text(), LEFT)
        self.assertNotIn("filtri salvati sulla chiavetta", (self.root / "log").read_text())

    def test_ram_copy_failure_changes_neither_generation(self):
        result = self.save("ram")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_previous(self.ram)
        self.assert_previous(self.disk)

    def test_failed_persistent_publish_restores_previous_generation(self):
        result = self.save("publish")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assert_previous(self.disk)

    def test_failed_sync_does_not_publish_unverified_generation(self):
        result = self.save("sync")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assert_previous(self.disk)

    def test_absent_usb_preserves_existing_ram_only_contract(self):
        result = self.save("absent")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual((self.ram / "sinistro.txt").read_text(), LEFT)
        self.assert_previous(self.disk)

    def test_success_preserves_fir_and_can_remove_the_right_filter(self):
        result = self.save(right=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        for folder in (self.ram, self.disk):
            self.assertEqual((folder / "sinistro.txt").read_text(), LEFT)
            self.assertFalse((folder / "destro.txt").exists())
            self.assertEqual((folder / "fir-sinistro.wav").read_bytes(), b"FIR precedente")

    def test_concurrent_save_is_rejected_without_changing_filters(self):
        with (self.run / "correzione.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.save()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_previous(self.ram)
        self.assert_previous(self.disk)

    def test_missing_input_does_not_erase_existing_filters(self):
        (self.root / "left").unlink()
        result = self.save()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_previous(self.ram)
        self.assert_previous(self.disk)

    def test_restore_recovers_previous_generation_after_interrupted_publish(self):
        self.disk.rename(self.disk.with_name(self.disk.name + ".vecchio"))
        for path in self.ram.iterdir():
            path.unlink()
        result = subprocess.run(
            ["busybox", "sh", "-c",
             '. "$DSP_SCRIPT"; do_restore "$STICK_MNT/correzione-ambientale"'],
            env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_previous(self.ram)

    def assert_readable_by_web(self):
        self.assertEqual(self.ram.stat().st_mode & 0o777, 0o755)
        for path in self.ram.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o644, path.name)
        if os.geteuid() == 0:
            self.root.chmod(0o755)
            self.run.chmod(0o755)

            def web_user():
                os.setgroups([])
                os.setgid(65534)
                os.setuid(65534)

            result = subprocess.run(
                ["/bin/sh", "-c", 'test -s "$1/sinistro.txt" && test ! -w "$1/sinistro.txt" && cat "$1/sinistro.txt"',
                 "sh", str(self.ram)],
                preexec_fn=web_user, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_restore_leaves_filters_readable_but_not_writable_by_web(self):
        for path in self.disk.iterdir():
            path.chmod(0o600)
        result = subprocess.run(
            ["busybox", "sh", "-c",
             'umask 077; . "$DSP_SCRIPT"; do_restore "$STICK_MNT/correzione-ambientale"'],
            env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_readable_by_web()

    def test_save_repairs_permissions_of_a_previously_private_generation(self):
        self.ram.chmod(0o700)
        for path in self.ram.iterdir():
            path.chmod(0o600)
        result = self.save(mask="077")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_readable_by_web()

    def create_rate_filters(self, folder):
        files = {
            "fir-sinistro.wav": (48000, 1),
            "fir-44100.wav": (44100, 2),
            "fir-sinistro-96000.wav": (96000, 1),
            "fir-destro-96000.wav": (96000, 1),
        }
        for name, (rate, channels) in files.items():
            path = folder / name
            with wave.open(str(path), "wb") as wav:
                wav.setnchannels(channels)
                wav.setsampwidth(2)
                wav.setframerate(rate)
                wav.writeframes(b"\x01\x00" * channels * 16)
            path.chmod(0o600)
        return {name: (folder / name).read_bytes() for name in files}

    def test_restore_preserves_all_rate_filters_and_recovers_previous_generation(self):
        expected = self.create_rate_filters(self.disk)
        for previous in (False, True):
            with self.subTest(previous=previous):
                if previous:
                    self.disk.rename(self.disk.with_name(self.disk.name + ".vecchio"))
                for path in self.ram.iterdir():
                    path.unlink()
                result = subprocess.run(
                    ["busybox", "sh", str(OVERLAY / "usr/bin/sweetspot-dsp"), "ripristina", str(self.disk)],
                    env=dict(self.env, SWEETSPOT_TEST=""), text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name, data in expected.items():
                    path = self.ram / name
                    self.assertTrue(path.is_file(), name)
                    self.assertEqual(path.read_bytes(), data, name)
                self.assert_readable_by_web()
                rates = subprocess.run(
                    ["busybox", "sh", str(OVERLAY / "usr/bin/sweetspot-dsp"), "fir-frequenze"],
                    env=dict(self.env, SWEETSPOT_TEST=""), text=True, capture_output=True, timeout=10)
                self.assertEqual(rates.returncode, 0, rates.stderr)
                self.assertEqual(rates.stdout.splitlines(), ["44100", "48000", "96000"])

    def test_save_preserves_rate_filters_and_makes_them_readable_by_web(self):
        expected = self.create_rate_filters(self.ram)
        self.create_rate_filters(self.disk)
        result = self.save(mask="077")
        self.assertEqual(result.returncode, 0, result.stderr)
        for folder in (self.ram, self.disk):
            for name, data in expected.items():
                self.assertEqual((folder / name).read_bytes(), data, name)
        self.assert_readable_by_web()

    def sh(self, body, **extra):
        return subprocess.run(
            ["busybox", "sh"], input='. "$DSP_SCRIPT"\n' + body, text=True,
            capture_output=True, timeout=10, env=dict(self.env, **extra))

    def test_oversized_rew_text_is_rejected_not_truncated(self):
        big = self.root / "big"
        big.write_text(LEFT * 600)
        result = self.sh('parse_rew "$F"; echo "rc=$?"', F=str(big))
        self.assertIn("errore|0|file troppo grande", result.stdout)
        self.assertIn("rc=1", result.stdout)

    def test_save_of_oversized_rew_keeps_previous_filters(self):
        (self.root / "left").write_text(LEFT * 600)
        result = self.save()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_previous(self.ram)
        self.assert_previous(self.disk)

    def test_fir_margin_accepts_only_plain_numbers_in_range(self):
        for value, expected in (("6", "6"), ("2.5", "2.5"), (".", "3"),
                                ("1.2.3", "3"), ("1.", "3"), ("-2", "3"),
                                ("99", "3"), ("", "3")):
            with self.subTest(value=value):
                result = self.sh('conf() { echo "$M"; }; fir_margin', M=value)
                self.assertEqual(result.stdout.strip(), expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
