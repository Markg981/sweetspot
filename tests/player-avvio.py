#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verifica l'ambiente dei processi avviati per il DAC principale e le zone."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "board/sweetspot/rootfs-overlay"

LAUNCH = r'''
. "$PLAYER_SCRIPT"
HK=0
SQLOG=$TEST_ROOT/player.log
ZONE_LOGDIR=$TEST_ROOT
dac_id() { echo TestDAC; }
dac_playback_dev() { echo 0; }
dac_name() { echo TestDAC; }
dac_formats() { echo S32_LE; }
dac_native_dsd() { :; }
dac_unity_gain() { :; }
announced_max_rate() { echo 192000; }
player_mac() { echo 02:00:00:00:00:01; }
zone_mac() { echo 02:00:00:00:00:02; }
common_args() { :; }
cap_write() { :; }
volume_stato_scrivi() { :; }
session_start() { :; }
oom_adj() { :; }
taskset() { shift 2; "$@"; }
export CAPTURE=$TEST_ROOT/main
run_player 1
wait "$PID"
export CAPTURE=$TEST_ROOT/zone
zone_start 1 1
wait
'''


class PlayerLaunchTests(unittest.TestCase):
    def test_dsd_margin_reaches_main_and_zone_processes(self):
        for configured, expected in ((None, "-3"), ("-12", "-12"), ("0", "0")):
            with self.subTest(margin=configured), tempfile.TemporaryDirectory() as temp:
                work = Path(temp)
                for child in ("run", "proc", "sys", "bin"):
                    (work / child).mkdir()
                config = "VOLUME=fisso\nMODALITA=completa\nDSD=pcm\n"
                if configured is not None:
                    config += "DSD_PCM_MARGINE_DB=%s\n" % configured
                (work / "run/sweetspot.conf").write_text(config)
                commands = {
                    "sweetspot-dsp": '#!/bin/sh\n[ "$1" = problema ]\n',
                    "squeezelite": '#!/bin/sh\nprintf "%s\\n" "${SWEETSPOT_DSD_MARGINE_DB:-UNSET}" > "$CAPTURE"\n',
                }
                for name, content in commands.items():
                    path = work / "bin" / name
                    path.write_text(content)
                    path.chmod(0o755)
                env = dict(os.environ, SWEETSPOT_TEST="1",
                           SWEETSPOT_LIB=str(OVERLAY / "usr/lib/sweetspot"),
                           SWEETSPOT_RUN=str(work / "run"),
                           SWEETSPOT_PROCFS=str(work / "proc"),
                           SWEETSPOT_SYSFS=str(work / "sys"),
                           SWEETSPOT_DEFAULTS=str(OVERLAY / "etc/sweetspot/defaults.conf"),
                           SWEETSPOT_LOG=str(work / "log"),
                           SWEETSPOT_PATH=str(work / "bin"),
                           TEST_ROOT=str(work),
                           PLAYER_SCRIPT=str(OVERLAY / "usr/bin/sweetspot-player"))
                env.pop("SWEETSPOT_DSD_MARGINE_DB", None)
                result = subprocess.run(["busybox", "sh"], input=LAUNCH, text=True,
                                        capture_output=True, env=env, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in ("main", "zone"):
                    self.assertEqual((work / name).read_text().strip(), expected, name)


ORDINE = r'''
. "$PLAYER_SCRIPT"
HK=0
ZONE_LOGDIR=$TEST_ROOT
dac_id() { echo TestDAC; }
dac_playback_dev() { echo 0; }
dac_name() { echo TestDAC; }
dac_formats() { echo S32_LE; }
dac_native_dsd() { :; }
dac_unity_gain() { :; }
announced_max_rate() { echo 192000; }
player_mac() { echo 02:00:00:00:00:01; }
common_args() { :; }
cap_write() { :; }
volume_stato_scrivi() { :; }
session_start() { :; }
oom_adj() { :; }
taskset() { shift 2; "$@"; }
lms_json() { shift; echo "lms $*" >> "$TEST_ROOT/ordine"; }
run_player 1
wait "$PID"
'''


class PlayerVolumeSicuroTests(unittest.TestCase):
    def test_fisso_a_software_abbassa_prima_di_avviare_squeezelite(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            for child in ("run", "proc", "sys", "bin"):
                (work / child).mkdir()
            (work / "run/sweetspot.conf").write_text(
                "VOLUME=software\nMODALITA=completa\nDSD=pcm\nVOLUME_SICURO=20\n")
            (work / "run/volume.fisso").write_text("")
            commands = {
                "sweetspot-dsp": '#!/bin/sh\n[ "$1" = problema ]\n',
                "squeezelite": '#!/bin/sh\necho squeezelite >> "$TEST_ROOT/ordine"\n',
            }
            for name, content in commands.items():
                path = work / "bin" / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, SWEETSPOT_TEST="1",
                       SWEETSPOT_LIB=str(OVERLAY / "usr/lib/sweetspot"),
                       SWEETSPOT_RUN=str(work / "run"),
                       SWEETSPOT_PROCFS=str(work / "proc"),
                       SWEETSPOT_SYSFS=str(work / "sys"),
                       SWEETSPOT_DEFAULTS=str(OVERLAY / "etc/sweetspot/defaults.conf"),
                       SWEETSPOT_LOG=str(work / "log"),
                       SWEETSPOT_PATH=str(work / "bin"),
                       TEST_ROOT=str(work),
                       PLAYER_SCRIPT=str(OVERLAY / "usr/bin/sweetspot-player"))
            result = subprocess.run(["busybox", "sh"], input=ORDINE, text=True,
                                    capture_output=True, env=env, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Nessun istante a volume pieno: prima il volume sicuro, poi il player.
            self.assertEqual((work / "ordine").read_text().split("\n")[:-1], [
                "lms mixer volume 20",
                "lms playerpref digitalVolumeControl 1",
                "squeezelite",
            ])


if __name__ == "__main__":
    unittest.main()
