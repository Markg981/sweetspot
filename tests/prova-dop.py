#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile sweetspot-prova-dop and compare it with tools/genera-test-dop.py.

The on-device generator must produce the same DoP test file as the
desktop tool, byte for byte. Needs a C compiler (cc, or CC=gcc).
"""
import importlib.util
import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "package/sweetspot-tools/src/sweetspot-prova-dop.c"


def desktop_tool():
    spec = importlib.util.spec_from_file_location("genera_test_dop", ROOT / "tools/genera-test-dop.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DopTestFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-prova-dop-")
        cls.tool = Path(cls.temp.name) / "sweetspot-prova-dop"
        subprocess.run([os.environ.get("CC", "cc"), "-O2", "-Wall", "-Wextra", "-Werror",
                        "-o", str(cls.tool), str(SOURCE), "-lm"], check=True)
        cls.device = Path(cls.temp.name) / "device.wav"
        subprocess.run([str(cls.tool), str(cls.device), "1"], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_same_bytes_as_desktop_tool(self):
        tool = desktop_tool()
        tool.SECONDS = 1
        desktop = Path(self.temp.name) / "desktop.wav"
        tool.main(str(desktop))
        self.assertEqual(self.device.read_bytes(), desktop.read_bytes())

    def test_header_and_continuous_markers(self):
        data = self.device.read_bytes()
        self.assertEqual(data[:4] + data[8:16], b"RIFFWAVEfmt ")
        fmt = struct.unpack("<IHHIIHH", data[16:36])
        self.assertEqual(fmt, (16, 1, 2, 176400, 176400 * 6, 6, 24))
        self.assertEqual(data[36:40], b"data")
        size = struct.unpack("<I", data[40:44])[0]
        self.assertEqual(size, 176400 * 6)
        payload = data[44:]
        self.assertEqual(len(payload), size)
        markers = payload[2::3]
        self.assertTrue(all(m == (0x05, 0xFA)[i // 2 % 2] for i, m in enumerate(markers)))
        frames = [payload[i:i + 6] for i in range(0, len(payload), 6)]
        self.assertTrue(all(frame[:3] == frame[3:] for frame in frames))

    def test_rejects_bad_arguments(self):
        for args in ([], ["a.wav", "0"], ["a.wav", "31"], ["a.wav", "x"], ["a", "1", "2"]):
            with self.subTest(args=args):
                self.assertEqual(subprocess.run([str(self.tool)] + args, capture_output=True,
                                                cwd=self.temp.name).returncode, 2)


if __name__ == "__main__":
    unittest.main()
