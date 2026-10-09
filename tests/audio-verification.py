#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline, independent PCM fixtures for the audio verification contract."""

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import tracemalloc
import unittest
import wave


TOOL = Path(__file__).resolve().parents[1] / "tools" / "audio_verification.py"
if TOOL.exists():
    spec = importlib.util.spec_from_file_location("audio_verification", TOOL)
    verifier = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = verifier
    spec.loader.exec_module(verifier)
else:
    verifier = None


def raw_samples(frames, bits, padded=False, padding=0):
    result = bytearray()
    for pair in frames:
        for value in pair:
            result.extend(value.to_bytes(bits // 8, "little", signed=True))
            if padded:
                result.append(padding)
    return bytes(result)


def write_wav(path, frames, bits=16, rate=48000, channels=2):
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(channels)
        stream.setsampwidth(bits // 8)
        stream.setframerate(rate)
        stream.writeframes(raw_samples(frames, bits))
    return path


class PCMVerificationTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(verifier, "PCM verifier has not been implemented")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.frames = [(1, -2), (-32768, 32767), (19, -31), (-7, 11)]
        self.reference = write_wav(self.directory / "reference.wav", self.frames)

    def capture(self, frames=None, bits=16, padded=False, padding=0, data=None):
        path = self.directory / "capture.raw"
        path.write_bytes(data if data is not None else raw_samples(
            self.frames if frames is None else frames, bits, padded, padding))
        return path

    def compare(self, capture=None, references=None, **kwargs):
        options = {"capture_format": "s16_le", "capture_rate": 48000}
        options.update(kwargs)
        return verifier.compare_capture(
            references or [self.reference], capture or self.capture(), **options)

    def assert_pass(self, report):
        self.assertEqual(report["status"], "pass")
        self.assertTrue(report["sample_match"])
        self.assertTrue(report["sequence_match"])
        self.assertIsNone(report["first_mismatch"])

    def test_exact_sequence_records_hashes_frames_and_boundary(self):
        second_frames = [(-13, 23), (32767, -32768), (3, -5)]
        second = write_wav(self.directory / "second.wav", second_frames)
        capture = self.capture(self.frames + second_frames)
        report = self.compare(capture, [self.reference, second])
        self.assert_pass(report)
        self.assertEqual(report["expected_frames"], 7)
        self.assertEqual(report["compared_frames"], 7)
        self.assertEqual(report["leading_frames"], 0)
        self.assertEqual(report["trailing_frames"], 0)
        self.assertEqual(report["boundaries"][0]["expected_frame"], 4)
        self.assertEqual(report["boundaries"][0]["capture_frame"], 4)
        self.assertEqual(report["capture"]["sha256"], hashlib.sha256(capture.read_bytes()).hexdigest())
        self.assertEqual(report["references"][0]["sha256"], hashlib.sha256(self.reference.read_bytes()).hexdigest())
        self.assertEqual(report["capture"]["format"], "s16_le")
        self.assertEqual(report["references"][0]["rate"], 48000)

    def test_corruption_after_chunk_is_detected_with_exact_position(self):
        frames = [(17, -29)] * 12000
        self.reference = write_wav(self.reference, frames)
        damaged = frames.copy()
        damaged[10001] = (18, -29)
        report = self.compare(self.capture(damaged))
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["first_mismatch"]["expected_frame"], 10001)
        self.assertEqual(report["first_mismatch"]["channel"], 0)
        self.assertEqual(report["compared_frames"], 12000)

    def test_every_frame_is_compared_with_bounded_memory(self):
        frames = [(17, -29)] * 120000
        self.reference = write_wav(self.reference, frames)
        capture = self.capture(frames)
        tracemalloc.start()
        try:
            report = self.compare(capture)
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assert_pass(report)
        self.assertEqual(report["compared_frames"], 120000)
        self.assertLess(peak, 2 * 1024 * 1024)

    def test_gap_drop_and_duplicate_at_track_boundary_fail(self):
        other_frames = [(-13, 23), (29, -37)]
        other = write_wav(self.directory / "other.wav", other_frames)
        alterations = {
            "gap": self.frames + [(0, 0)] + other_frames,
            "drop": self.frames[:-1] + other_frames,
            "duplicate": self.frames + [self.frames[-1]] + other_frames,
        }
        for name, frames in alterations.items():
            with self.subTest(name=name):
                report = self.compare(self.capture(frames), [self.reference, other])
                self.assertEqual(report["status"], "fail")
                self.assertFalse(report["sequence_match"])
                self.assertFalse(report["boundaries"][0]["match"])

    def test_channel_swap_fails(self):
        report = self.compare(self.capture([(r, l) for l, r in self.frames]))
        self.assertFalse(report["sample_match"])
        self.assertEqual(report["first_mismatch"]["expected_frame"], 0)

    def test_wrong_endianness_fails(self):
        data = b"".join(value.to_bytes(2, "big", signed=True)
                        for frame in self.frames for value in frame)
        self.assertEqual(self.compare(self.capture(data=data))["status"], "fail")

    def test_pcm16_normalizes_to_signed32(self):
        normalized = [(65536, -131072), (-2147483648, 2147418112),
                      (1245184, -2031616), (-458752, 720896)]
        self.assert_pass(self.compare(self.capture(normalized, bits=32), capture_format="s32_le"))

    def test_pcm24_packed_and_alsa_padding_preserve_sign(self):
        frames = [(1, -1), (-8388608, 8388607), (65536, -65536)]
        self.reference = write_wav(self.reference, frames, bits=24)
        self.assert_pass(self.compare(self.capture(frames, bits=24), capture_format="s24_3le"))
        for padding in (0, 255, 90):
            with self.subTest(padding=padding):
                self.assert_pass(self.compare(self.capture(frames, bits=24, padded=True, padding=padding),
                                              capture_format="s24_le"))
        normalized = [(256, -256), (-2147483648, 2147483392), (16777216, -16777216)]
        self.assert_pass(self.compare(self.capture(normalized, bits=32), capture_format="s32_le"))

    def test_pcm32_preserves_full_signed_precision(self):
        frames = [(1, -1), (-2147483648, 2147483647), (8388609, -8388609)]
        self.reference = write_wav(self.reference, frames, bits=32)
        self.assert_pass(self.compare(self.capture(frames, bits=32), capture_format="s32_le"))
        damaged = frames.copy()
        damaged[-1] = (8388608, -8388609)
        self.assertEqual(self.compare(self.capture(damaged, bits=32), capture_format="s32_le")["status"], "fail")

    def test_leading_and_trailing_silence_are_reported(self):
        capture = self.capture([(0, 0)] * 3 + self.frames + [(0, 0)] * 2)
        report = self.compare(capture, max_lead_frames=3)
        self.assert_pass(report)
        self.assertEqual(report["leading_frames"], 3)
        self.assertEqual(report["trailing_frames"], 2)

    def test_leading_silence_limit_is_enforced(self):
        capture = self.capture([(0, 0)] * 2 + self.frames)
        self.assertEqual(self.compare(capture)["status"], "fail")
        self.assertEqual(self.compare(capture, max_lead_frames=1)["status"], "fail")
        self.assert_pass(self.compare(capture, max_lead_frames=2))

    def test_reference_leading_silence_is_not_trimmed(self):
        frames = [(0, 0), (0, 0)] + self.frames
        self.reference = write_wav(self.reference, frames)
        self.assert_pass(self.compare(self.capture(frames)))
        report = self.compare(self.capture([(0, 0)] + frames), max_lead_frames=1)
        self.assert_pass(report)
        self.assertEqual(report["leading_frames"], 1)
        self.assertEqual(self.compare(self.capture(frames[1:]), max_lead_frames=10)["status"], "fail")

    def test_internal_silence_cannot_be_trimmed(self):
        frames = self.frames[:2] + [(0, 0)] + self.frames[2:]
        self.assertEqual(self.compare(self.capture(frames), max_lead_frames=20)["status"], "fail")

    def test_nonzero_trailing_frame_fails_even_if_samples_match(self):
        report = self.compare(self.capture(self.frames + [(1, 0)]))
        self.assertTrue(report["sample_match"])
        self.assertFalse(report["sequence_match"])
        self.assertEqual(report["status"], "fail")

    def test_explicit_offset_cannot_discard_nonzero_frames(self):
        capture = self.capture([(13, -17)] + self.frames)
        self.assertEqual(self.compare(capture, offset_frames=1)["status"], "fail")

    def test_all_silent_reference_requires_explicit_offset(self):
        self.reference = write_wav(self.reference, [(0, 0)] * 4)
        capture = self.capture([(0, 0)] * 6)
        with self.assertRaises(ValueError):
            self.compare(capture, max_lead_frames=20)
        report = self.compare(capture, offset_frames=2)
        self.assert_pass(report)
        self.assertEqual(report["leading_frames"], 2)
        self.assertEqual(report["alignment"], "explicit")

    def test_short_capture_reports_missing_frames(self):
        report = self.compare(self.capture(self.frames[:-1]))
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["compared_frames"], 3)
        self.assertEqual(report["first_mismatch"]["expected_frame"], 3)

    def test_partial_raw_frame_is_invalid_for_every_format(self):
        for name, width in (("s16_le", 4), ("s24_3le", 6), ("s24_le", 8), ("s32_le", 8)):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    self.compare(self.capture(data=b"\0" * (width - 1)), capture_format=name)

    def test_mismatched_rates_and_reference_metadata_are_invalid(self):
        with self.assertRaises(ValueError):
            self.compare(capture_rate=44100)
        other = write_wav(self.directory / "rate.wav", self.frames, rate=44100)
        with self.assertRaises(ValueError):
            self.compare(references=[self.reference, other])
        mono = write_wav(self.directory / "mono.wav", self.frames, channels=1)
        with self.assertRaises(ValueError):
            self.compare(references=[mono])

    def test_malformed_wav_headers_and_truncation_are_invalid(self):
        original = self.reference.read_bytes()
        cases = [original[:-1], b"not a WAV", original + b"trailer"]
        for field, value in ((20, 3), (22, 1), (32, 3), (34, 8)):
            damaged = bytearray(original)
            struct.pack_into("<H", damaged, field, value)
            cases.append(bytes(damaged))
        damaged = bytearray(original)
        struct.pack_into("<I", damaged, 28, 123)
        cases.append(bytes(damaged))
        damaged = bytearray(original)
        struct.pack_into("<I", damaged, 40, 15)
        cases.append(bytes(damaged))
        for number, data in enumerate(cases):
            with self.subTest(number=number):
                self.reference.write_bytes(data)
                with self.assertRaises(ValueError):
                    self.compare()

    def test_duplicate_data_or_format_chunks_are_invalid(self):
        original = self.reference.read_bytes()
        for duplicate in (original[12:36], original[36:]):
            with self.subTest(chunk=duplicate[:4]):
                damaged = bytearray(original + duplicate)
                struct.pack_into("<I", damaged, 4, len(damaged) - 8)
                self.reference.write_bytes(damaged)
                with self.assertRaises(ValueError):
                    self.compare()

    def test_empty_or_invalid_options_are_rejected(self):
        with self.assertRaises(ValueError):
            verifier.compare_capture([], self.capture(), capture_format="s16_le", capture_rate=48000)
        for options in ({"capture_format": "float32"}, {"capture_rate": 0},
                        {"offset_frames": -1}, {"max_lead_frames": -1},
                        {"offset_frames": 999}, {"max_lead_frames": 1.5}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.compare(**options)
        self.reference = write_wav(self.reference, [])
        with self.assertRaises(ValueError):
            self.compare()

    def test_generated_tracks_are_deterministic_distinct_and_low_level(self):
        for rate in (44100, 48000, 96000):
            for bits in (16, 24, 32):
                with self.subTest(rate=rate, bits=bits):
                    directory = self.directory / f"{rate}-{bits}"
                    paths = verifier.generate_fixtures(directory, rate, bits, frames=257)
                    self.assertEqual(len(paths), 2)
                    before = [path.read_bytes() for path in paths]
                    self.assertNotEqual(before[0], before[1])
                    for path in paths:
                        self.assertIn(str(rate), path.name)
                        self.assertIn(str(bits), path.name)
                        with wave.open(str(path), "rb") as stream:
                            self.assertEqual((stream.getnchannels(), stream.getframerate(), stream.getnframes()),
                                             (2, rate, 257))
                            raw = stream.readframes(257)
                        width = bits // 8
                        values = [int.from_bytes(raw[i:i + width], "little", signed=True)
                                  for i in range(0, len(raw), width)]
                        self.assertTrue(all(values[:2]))
                        self.assertNotEqual(values[0], values[1])
                        self.assertLessEqual(max(map(abs, values)), (1 << (bits - 1)) // 8)
                        self.assertGreater(len(set(values)), 20)
                    verifier.generate_fixtures(directory, rate, bits, frames=257)
                    self.assertEqual(before, [path.read_bytes() for path in paths])

    def test_fixture_arguments_reject_bad_rate_bits_or_frames(self):
        for rate, bits, frames in ((0, 16, 5), (48000, 8, 5), (48000, 16, 0),
                                   (48000, 16, -1), (1.5, 16, 5), (48000, 16, 2.5),
                                   (48000, 16.0, 5), (48000, True, 5),
                                   (True, 16, 5), (48000, 16, True)):
            with self.subTest(rate=rate, bits=bits, frames=frames), self.assertRaises(ValueError):
                verifier.generate_fixtures(self.directory, rate, bits, frames)

    def test_cli_invalid_arguments_are_json_errors(self):
        for arguments in (["compare"], ["generate", "--output", str(self.directory),
                                      "--rate", "bad", "--bits", "16"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run([sys.executable, str(TOOL)] + arguments,
                                        text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(json.loads(result.stdout)["status"], "error")

    def test_cli_reports_match_mismatch_and_invalid_input_exit_codes(self):
        report_path = self.directory / "report.json"
        command = [sys.executable, str(TOOL), "compare", "--reference", str(self.reference),
                   "--capture", str(self.capture()), "--capture-format", "s16_le",
                   "--capture-rate", "48000", "--report", str(report_path)]
        for data, exit_code, status in ((raw_samples(self.frames, 16), 0, "pass"),
                                        (raw_samples([(2, -2)] + self.frames[1:], 16), 1, "fail"),
                                        (b"\0", 2, "error")):
            with self.subTest(status=status):
                (self.directory / "capture.raw").write_bytes(data)
                result = subprocess.run(command, text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, exit_code, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["status"], status)
                self.assertEqual(json.loads(report_path.read_text()), report)

    def assert_report_alias_protected(self, capture, report_path):
        originals = {path: path.read_bytes() for path in (capture, self.reference)}
        result = subprocess.run([
            sys.executable, str(TOOL), "compare", "--reference", str(self.reference),
            "--capture", str(capture), "--capture-format", "s16_le", "--capture-rate", "48000",
            "--report", str(report_path)], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertEqual(json.loads(result.stdout)["status"], "error")
        for path, original in originals.items():
            self.assertEqual(path.read_bytes(), original, f"Input evidence overwritten: {path}")

    def test_cli_report_cannot_overwrite_capture(self):
        capture = self.capture()
        self.assert_report_alias_protected(capture, capture)

    def test_cli_report_cannot_overwrite_reference_via_resolved_path(self):
        capture = self.capture()
        child = self.directory / "child"
        child.mkdir()
        self.assert_report_alias_protected(capture, child / ".." / self.reference.name)

    def test_cli_input_error_cannot_write_json_over_capture(self):
        capture = self.capture(data=b"\0")
        self.assert_report_alias_protected(capture, capture)

    def test_cli_report_symlink_to_input_is_rejected(self):
        capture = self.capture()
        for index, target in enumerate((capture, self.reference)):
            with self.subTest(target=target.name):
                alias = self.directory / f"symlink-{index}.json"
                try:
                    alias.symlink_to(target)
                except (OSError, NotImplementedError) as error:
                    self.skipTest(f"Symlinks unavailable: {error}")
                self.assert_report_alias_protected(capture, alias)

    def test_cli_report_hardlink_to_input_is_rejected(self):
        capture = self.capture()
        for index, target in enumerate((capture, self.reference)):
            with self.subTest(target=target.name):
                alias = self.directory / f"hardlink-{index}.json"
                try:
                    alias.hardlink_to(target)
                except (OSError, NotImplementedError) as error:
                    self.skipTest(f"Hardlinks unavailable: {error}")
                self.assert_report_alias_protected(capture, alias)

    def test_cli_generate_creates_two_wavs(self):
        result = subprocess.run([sys.executable, str(TOOL), "generate", "--output", str(self.directory / "cli"),
                                 "--rate", "44100", "--bits", "24"],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((self.directory / "cli").glob("*.wav"))), 2)
        self.assertEqual(json.loads(result.stdout)["status"], "pass")


if __name__ == "__main__":
    unittest.main()
