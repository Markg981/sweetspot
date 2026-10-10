#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline, independent PCM/DoP fixtures for the audio verification contract."""

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
from unittest.mock import patch
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

    def test_mixed_pcm16_pcm24_preserves_signed_values_and_pcm24_lsb(self):
        pcm16 = [(1, -2), (-32768, 32767), (-7, 11)]
        pcm24 = [(1, -1), (-8388608, 8388607), (65537, -65537)]
        for order in ((16, 24), (24, 16)):
            with self.subTest(order=order):
                by_bits = {16: pcm16, 24: pcm24}
                references = [write_wav(self.directory / f"mixed-{index}.wav", by_bits[bits], bits)
                              for index, bits in enumerate(order)]
                normalized = [tuple(value << (32 - bits) for value in pair)
                              for bits in order for pair in by_bits[bits]]
                self.assert_pass(self.compare(self.capture(normalized, bits=32), references,
                                              capture_format="s32_le"))
                index = 0 if order[0] == 24 else len(pcm16)
                damaged = normalized.copy()
                left, right = damaged[index]
                damaged[index] = (left ^ 256, right)
                report = self.compare(self.capture(damaged, bits=32), references,
                                      capture_format="s32_le")
                self.assertEqual(report["status"], "fail")
                self.assertEqual(report["first_mismatch"]["expected_frame"], index)

    def test_mixed_pcm_boundaries_reject_gap_drop_and_duplicate_in_both_directions(self):
        by_bits = {16: [(1, -2), (-32768, 32767)],
                   24: [(-8388608, 8388607), (17, -31)]}
        for order in ((16, 24), (24, 16)):
            references = [write_wav(self.directory / f"mixed-boundary-{index}.wav", by_bits[bits], bits)
                          for index, bits in enumerate(order)]
            first, second = [[tuple(value << (32 - bits) for value in pair) for pair in by_bits[bits]]
                             for bits in order]
            for defect, captured in (("gap", first + [(0, 0)] + second),
                                     ("drop", first[:-1] + second),
                                     ("duplicate", first + [first[-1]] + second)):
                with self.subTest(order=order, defect=defect):
                    report = self.compare(self.capture(captured, bits=32), references,
                                          capture_format="s32_le")
                    self.assertEqual(report["status"], "fail")
                    self.assertFalse(report["boundaries"][0]["match"])

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


def dop_bytes(payloads, capture_format="s24_3le", phase=0x05):
    """Independent DoP encoder: complete low/high payload bytes, then marker."""
    data = bytearray()
    for index, pair in enumerate(payloads):
        marker = phase if index % 2 == 0 else phase ^ 0xFF
        for payload in pair:
            packed = payload.to_bytes(2, "little") + bytes([marker])
            if capture_format == "s32_le":
                packed = b"\0" + packed
            elif capture_format == "s24_le":
                packed += b"\0"
            data.extend(packed)
    return bytes(data)


def write_dop_wav(path, payloads, rate=176400, phase=0x05):
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(2)
        stream.setsampwidth(3)
        stream.setframerate(rate)
        stream.writeframes(dop_bytes(payloads, phase=phase))
    return path


class DoPVerificationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(callable(getattr(verifier, "compare_dop_capture", None)),
                        "DoP comparator has not been implemented")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.first = [(0x0001, 0xFF02), (0x8033, 0x7F44), (0x1234, 0xABCD)]
        self.second = [(0x5678, 0x9012), (0xFEDC, 0xBA98)]
        self.references = [write_dop_wav(self.directory / "first.wav", self.first),
                           write_dop_wav(self.directory / "second.wav", self.second, phase=0xFA)]

    def capture(self, payloads=None, capture_format="s32_le", phase=0xFA, data=None):
        path = self.directory / "capture.raw"
        path.write_bytes(dop_bytes(self.first + self.second if payloads is None else payloads,
                                   capture_format, phase) if data is None else data)
        return path

    def compare(self, capture=None, references=None, **kwargs):
        options = {"capture_format": "s32_le", "capture_rate": 176400}
        options.update(kwargs)
        return verifier.compare_dop_capture(self.references if references is None else references,
                                           capture or self.capture(), **options)

    def assert_pass(self, report):
        self.assertEqual(report["status"], "pass", report)
        for field in ("payload_match", "markers_match", "sequence_match"):
            self.assertTrue(report[field], field)
        self.assertIsNone(report["first_mismatch"])

    def test_full_payload_and_legal_independent_marker_phase_pass_for_all_packings(self):
        for capture_format in ("s24_3le", "s24_le", "s32_le"):
            for phase in (0x05, 0xFA):
                with self.subTest(capture_format=capture_format, phase=phase):
                    capture = self.capture(capture_format=capture_format, phase=phase)
                    report = self.compare(capture, capture_format=capture_format)
                    self.assert_pass(report)
                    self.assertEqual(report["expected_frames"], 5)
                    self.assertEqual(report["compared_frames"], 5)
                    self.assertEqual(report["leading_frames"], 0)
                    self.assertEqual(report["trailing_frames"], 0)
                    self.assertEqual(report["boundaries"][0]["expected_frame"], 3)
                    self.assertTrue(report["boundaries"][0]["match"])
                    self.assertEqual(report["capture"]["sha256"], hashlib.sha256(capture.read_bytes()).hexdigest())
                    self.assertEqual(report["references"][0]["sha256"],
                                     hashlib.sha256(self.references[0].read_bytes()).hexdigest())
                    self.assertEqual(report["marker_phase"]["capture_first"], phase)
                    self.assertEqual(report["marker_phase"]["reference_first"], [0x05, 0xFA])
                    self.assertEqual(report["scope"], "software_stdout")

    def test_either_payload_byte_and_channel_swap_fail(self):
        for bit in (0, 8, 15):
            for channel in (0, 1):
                with self.subTest(bit=bit, channel=channel):
                    damaged = self.first + self.second
                    pair = list(damaged[3])
                    pair[channel] ^= 1 << bit
                    damaged[3] = tuple(pair)
                    report = self.compare(self.capture(damaged))
                    self.assertEqual(report["status"], "fail")
                    self.assertFalse(report["payload_match"])
                    self.assertTrue(report["markers_match"])
                    self.assertEqual(report["first_mismatch"]["expected_frame"], 3)
                    self.assertEqual(report["first_mismatch"]["channel"], channel)
        report = self.compare(self.capture([(right, left) for left, right in self.first + self.second]))
        self.assertEqual(report["status"], "fail")
        self.assertFalse(report["payload_match"])

    def test_pcm_zero_cannot_replace_dop_zero_payload_in_compared_sequence(self):
        payloads = [(0, 0), (0x1234, 0x5678)]
        reference = write_dop_wav(self.directory / "zero-payload.wav", payloads)
        for capture_format in ("s24_3le", "s24_le", "s32_le"):
            frame_size = 6 if capture_format == "s24_3le" else 8
            encoded = dop_bytes(payloads, capture_format, phase=0x05)
            for prefix_frames in (0, 2):
                with self.subTest(capture_format=capture_format, prefix_frames=prefix_frames):
                    prefix = b"\0" * (frame_size * prefix_frames)
                    valid = self.capture(data=prefix + encoded)
                    self.assert_pass(self.compare(valid, references=[reference],
                                                  capture_format=capture_format,
                                                  offset_frames=prefix_frames))
                    damaged = self.capture(data=prefix + b"\0" * frame_size + encoded[frame_size:])
                    report = self.compare(damaged, references=[reference],
                                          capture_format=capture_format,
                                          offset_frames=prefix_frames)
                    self.assertEqual(report["status"], "fail", report)
                    self.assertTrue(report["payload_match"])
                    self.assertFalse(report["markers_match"])
                    self.assertEqual(report["first_mismatch"]["capture_frame"], prefix_frames)

    def test_internal_gap_drop_duplicate_and_track_swap_fail_at_boundary(self):
        for name, payloads in (("gap", self.first + [(0x6969, 0x6969)] + self.second),
                               ("drop", self.first[:-1] + self.second),
                               ("duplicate", self.first + [self.first[-1]] + self.second),
                               ("track_swap", self.second + self.first)):
            with self.subTest(name=name):
                report = self.compare(self.capture(payloads), max_lead_frames=100)
                self.assertEqual(report["status"], "fail")
                self.assertFalse(report["payload_match"])
                self.assertFalse(report["boundaries"][0]["match"])

    def test_capture_marker_illegal_repeated_or_different_channels_fails(self):
        for name, changes in (("illegal", ((19, 0x04), (23, 0x04))),
                              ("repeated", ((19, 0x05), (23, 0x05))),
                              ("channels", ((23, 0x05),))):
            with self.subTest(name=name):
                data = bytearray(dop_bytes(self.first + self.second, "s32_le", 0xFA))
                for index, value in changes:
                    data[index] = value
                report = self.compare(self.capture(data=data))
                self.assertEqual(report["status"], "fail")
                self.assertTrue(report["payload_match"])
                self.assertFalse(report["markers_match"])
                self.assertEqual(report["first_mismatch"]["capture_frame"], 2)

    def test_marker_phase_must_continue_across_track_boundary(self):
        data = dop_bytes(self.first, "s32_le", 0xFA) + dop_bytes(self.second, "s32_le", 0xFA)
        report = self.compare(self.capture(data=data))
        self.assertEqual(report["status"], "fail")
        self.assertTrue(report["payload_match"])
        self.assertFalse(report["markers_match"])
        self.assertFalse(report["boundaries"][0]["match"])
        self.assertEqual(report["first_mismatch"]["capture_frame"], 3)

    def test_s32_low_padding_corruption_fails_without_dropping_payload_bits(self):
        for channel in (0, 1):
            with self.subTest(channel=channel):
                data = bytearray(dop_bytes(self.first + self.second, "s32_le", 0xFA))
                data[8 + channel * 4] = 1
                report = self.compare(self.capture(data=data))
                self.assertEqual(report["status"], "fail")
                self.assertEqual(report["first_mismatch"]["reason"], "nonzero_s32_padding")
                self.assertEqual(report["first_mismatch"]["capture_frame"], 1)
                self.assertTrue(report["payload_match"])

    def test_startup_pcm_zeros_and_dop_idle_at_edges_pass_with_declared_limit(self):
        payloads = [(0x6969, 0x6969)] * 3 + self.first + self.second + [(0x6969, 0x6969)] * 4
        data = b"\0" * 16 + dop_bytes(payloads, "s32_le", 0xFA)
        report = self.compare(self.capture(data=data), max_lead_frames=5)
        self.assert_pass(report)
        self.assertEqual(report["leading_frames"], 5)
        self.assertEqual(report["trailing_frames"], 4)
        self.assertEqual(report["boundaries"][0]["capture_frame"], 8)
        self.assertEqual(report["marker_phase"]["capture_first_dop_frame"], 2)
        self.assertEqual(self.compare(self.capture(data=data), max_lead_frames=4)["status"], "fail")

    def test_reference_leading_dop_idle_is_preserved_during_alignment(self):
        payloads = [(0x6969, 0x6969)] * 2 + self.first
        reference = write_dop_wav(self.references[0], payloads)
        capture = self.capture([(0x6969, 0x6969)] * 4 + self.first)
        report = self.compare(capture, [reference], max_lead_frames=2)
        self.assert_pass(report)
        self.assertEqual(report["leading_frames"], 2)
        self.assertEqual(report["compared_frames"], 5)
        self.assertEqual(self.compare(self.capture(payloads[1:]), [reference], max_lead_frames=10)["status"], "fail")

    def test_pcm_zero_after_first_dop_frame_fails_in_prefix_sequence_and_tail(self):
        source = dop_bytes(self.first + self.second, "s32_le", 0xFA)
        cases = (dop_bytes([(0x6969, 0x6969)], "s32_le", 0x05) + b"\0" * 8 + source,
                 source[:24] + b"\0" * 8 + source[24:], source + b"\0" * 8)
        for index, data in enumerate(cases):
            with self.subTest(index=index):
                report = self.compare(self.capture(data=data), max_lead_frames=10)
                self.assertEqual(report["status"], "fail")
                self.assertFalse(report["markers_match"])

    def test_edge_payload_must_be_stereo_dop_idle_and_cannot_be_discarded_explicitly(self):
        for extra in ((0x6969, 0x6968), (1, 2)):
            with self.subTest(extra=extra):
                report = self.compare(self.capture([extra] + self.first + self.second), offset_frames=1)
                self.assertEqual(report["status"], "fail")
                self.assertEqual(report["first_mismatch"]["reason"], "nonidle_leading_frame")
                report = self.compare(self.capture(self.first + self.second + [extra]))
                self.assertEqual(report["status"], "fail")
                self.assertTrue(report["payload_match"])
                self.assertEqual(report["first_mismatch"]["reason"], "nonidle_trailing_frame")

    def test_all_idle_reference_requires_explicit_offset(self):
        reference = write_dop_wav(self.references[0], [(0x6969, 0x6969)] * 3)
        capture = self.capture([(0x6969, 0x6969)] * 6)
        with self.assertRaises(ValueError):
            self.compare(capture, [reference], max_lead_frames=10)
        report = self.compare(capture, [reference], offset_frames=2)
        self.assert_pass(report)
        self.assertEqual(report["leading_frames"], 2)
        self.assertEqual(report["trailing_frames"], 1)

    def test_short_capture_reports_missing_payload_frame(self):
        report = self.compare(self.capture(self.first + self.second[:-1]))
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["compared_frames"], 4)
        self.assertEqual(report["first_mismatch"]["reason"], "missing_frame")
        self.assertEqual(report["first_mismatch"]["expected_frame"], 4)

    def test_all_markers_in_lead_and_long_tail_are_checked(self):
        payloads = [(0x6969, 0x6969)] * 2 + self.first + self.second + [(0x6969, 0x6969)] * 5000
        original = dop_bytes(payloads, "s32_le", 0x05)
        for frame in (0, 5006):
            with self.subTest(frame=frame):
                data = bytearray(original)
                data[frame * 8 + 3] = 0x44
                report = self.compare(self.capture(data=data), max_lead_frames=2)
                self.assertEqual(report["status"], "fail")
                self.assertFalse(report["markers_match"])
                self.assertEqual(report["first_mismatch"]["capture_frame"], frame)

    def test_every_dop_frame_is_compared_with_bounded_memory(self):
        payloads = [(0x1234, 0xABCD)] * 120000
        reference = write_dop_wav(self.references[0], payloads)
        capture = self.capture(payloads)
        tracemalloc.start()
        try:
            report = self.compare(capture, [reference])
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assert_pass(report)
        self.assertEqual(report["compared_frames"], 120000)
        self.assertLess(peak, 2 * 1024 * 1024)

    def test_invalid_source_markers_are_input_errors(self):
        original = self.references[0].read_bytes()
        for indexes, values in (((46, 49), (4, 4)), ((52, 55), (5, 5)), ((49,), (250,))):
            with self.subTest(indexes=indexes):
                data = bytearray(original)
                for index, value in zip(indexes, values):
                    data[index] = value
                self.references[0].write_bytes(data)
                with self.assertRaises(ValueError):
                    self.compare()
        self.references[0].write_bytes(original[:-1])
        with self.assertRaises(ValueError):
            self.compare()

    def test_wrong_metadata_partial_frames_and_invalid_options_are_input_errors(self):
        for options in ({"capture_rate": 352800}, {"capture_format": "s16_le"},
                        {"capture_format": "float32"}, {"capture_rate": True},
                        {"offset_frames": -1}, {"offset_frames": 6},
                        {"max_lead_frames": -1}, {"max_lead_frames": 1.5}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.compare(**options)
        with self.assertRaises(ValueError):
            self.compare(references=[])
        for capture_format, width in (("s24_3le", 6), ("s24_le", 8), ("s32_le", 8)):
            with self.subTest(capture_format=capture_format), self.assertRaises(ValueError):
                self.compare(self.capture(data=b"\0" * (width - 1)), capture_format=capture_format)
        pcm16 = write_wav(self.directory / "pcm16.wav", [(1, -2)], rate=176400)
        with self.assertRaises(ValueError):
            self.compare(references=[pcm16])

    def test_generated_dop_tracks_are_deterministic_distinct_stereo_wav24(self):
        self.assertTrue(callable(getattr(verifier, "generate_dop_fixtures", None)))
        for rate in (176400, 352800):
            with self.subTest(rate=rate):
                directory = self.directory / str(rate)
                paths = verifier.generate_dop_fixtures(directory, rate, frames=257)
                self.assertEqual(len(paths), 2)
                original = [path.read_bytes() for path in paths]
                self.assertNotEqual(original[0], original[1])
                for path in paths:
                    with wave.open(str(path), "rb") as stream:
                        self.assertEqual((stream.getnchannels(), stream.getsampwidth(),
                                          stream.getframerate(), stream.getnframes()), (2, 3, rate, 257))
                        data = stream.readframes(257)
                    channels = [[], []]
                    for index in range(257):
                        frame = data[index * 6:index * 6 + 6]
                        self.assertEqual(frame[2], 5 if index % 2 == 0 else 250)
                        self.assertEqual(frame[5], frame[2])
                        channels[0].append(frame[:2])
                        channels[1].append(frame[3:5])
                    self.assertNotEqual(channels[0], channels[1])
                    self.assertGreater(len(set(channels[0])), 200)
                    self.assertNotEqual(channels[0][0], b"\x69\x69")
                verifier.generate_dop_fixtures(directory, rate, frames=257)
                self.assertEqual(original, [path.read_bytes() for path in paths])

    def test_fixture_default_duration_and_invalid_arguments(self):
        paths = verifier.generate_dop_fixtures(self.directory / "default", 176400)
        for path in paths:
            with wave.open(str(path), "rb") as stream:
                self.assertEqual(stream.getnframes(), 176400)
        for rate, frames in ((48000, 5), (0, 5), (True, 5), (176400.0, 5),
                             (176400, 0), (176400, True), (176400, -1), (176400, 1.5),
                             (176400, 0xFFFFFFFF)):
            with self.subTest(rate=rate, frames=frames), self.assertRaises(ValueError):
                verifier.generate_dop_fixtures(self.directory, rate, frames)

    def test_cli_generate_dop_and_compare_dop_preserve_exit_codes_and_report(self):
        output = self.directory / "cli"
        result = subprocess.run([sys.executable, str(TOOL), "generate-dop", "--output", str(output),
                                 "--rate", "352800"], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(list(output.glob("*.wav"))), 2)
        report_path = self.directory / "report.json"
        capture = self.capture()
        command = [sys.executable, str(TOOL), "compare-dop"]
        for reference in self.references:
            command += ["--reference", str(reference)]
        command += ["--capture", str(capture), "--capture-format", "s32_le",
                    "--capture-rate", "176400", "--report", str(report_path)]
        original = dop_bytes(self.first + self.second, "s32_le", 0xFA)
        damaged = bytearray(original)
        damaged[1] ^= 1
        for data, exit_code, status in ((original, 0, "pass"), (damaged, 1, "fail"), (b"\0", 2, "error")):
            with self.subTest(status=status):
                capture.write_bytes(data)
                result = subprocess.run(command, text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, exit_code, result.stdout)
                report = json.loads(result.stdout)
                self.assertEqual(report["status"], status)
                self.assertEqual(json.loads(report_path.read_text()), report)

    def test_cli_report_cannot_alias_either_input_even_on_error(self):
        capture = self.capture()
        originals = {path: path.read_bytes() for path in [capture, *self.references]}
        for target in (capture, *self.references):
            for alias_kind in ("direct", "resolved", "hardlink", "symlink"):
                with self.subTest(target=target.name, alias_kind=alias_kind):
                    alias = target
                    if alias_kind == "resolved":
                        (self.directory / "child").mkdir(exist_ok=True)
                        alias = self.directory / "child" / ".." / target.name
                    elif alias_kind in ("hardlink", "symlink"):
                        alias = self.directory / f"{alias_kind}-{target.name}.json"
                        try:
                            if alias_kind == "hardlink":
                                alias.hardlink_to(target)
                            else:
                                alias.symlink_to(target)
                        except (OSError, NotImplementedError):
                            continue
                    result = subprocess.run([sys.executable, str(TOOL), "compare-dop",
                                             "--reference", str(self.references[0]),
                                             "--reference", str(self.references[1]),
                                             "--capture", str(capture), "--capture-format", "s32_le",
                                             "--capture-rate", "176400", "--report", str(alias)],
                                            text=True, capture_output=True, check=False)
                    self.assertEqual(result.returncode, 2, result.stdout)
                    self.assertEqual(json.loads(result.stdout)["status"], "error")
                    for path, original in originals.items():
                        self.assertEqual(path.read_bytes(), original)
        capture.write_bytes(b"\0")
        result = subprocess.run([sys.executable, str(TOOL), "compare-dop", "--reference", str(self.references[0]),
                                 "--capture", str(capture), "--capture-format", "s32_le", "--capture-rate", "176400",
                                 "--report", str(capture)], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertEqual(capture.read_bytes(), b"\0")


class DSDFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def generate(self, container, rate=176400, frames=2051, directory=None):
        self.assertTrue(callable(getattr(verifier, "generate_dsd_fixtures", None)),
                        "DSF/DFF source generation has not been implemented")
        return verifier.generate_dsd_fixtures(directory or self.directory, rate,
                                              container=container, frames=frames)

    def wav_channels(self, path):
        with wave.open(str(path), "rb") as stream:
            self.assertEqual((stream.getnchannels(), stream.getsampwidth()), (2, 3))
            data = stream.readframes(stream.getnframes())
        # In a little-endian DoP word the older DSD byte is the middle byte.
        return [bytes(byte for index in range(channel * 3, len(data), 6)
                      for byte in (data[index + 1], data[index])) for channel in (0, 1)]

    def dff_chunks(self, data):
        result = {}
        position = 0
        while position < len(data):
            self.assertGreaterEqual(len(data) - position, 12)
            name, size = struct.unpack_from(">4sQ", data, position)
            self.assertNotIn(name, result)
            end = position + 12 + size
            self.assertLessEqual(end + (size & 1), len(data))
            result[name] = data[position + 12:end]
            if size & 1:
                self.assertEqual(data[end], 0)
            position = end + (size & 1)
        self.assertEqual(position, len(data))
        return result

    def test_dsf_headers_describe_stereo_lsb_dsd_and_exact_sample_count(self):
        for rate in (176400, 352800):
            with self.subTest(rate=rate):
                sources, references = self.generate("dsf", rate)
                self.assertEqual((len(sources), len(references)), (2, 2))
                for source in sources:
                    data = source.read_bytes()
                    self.assertEqual(struct.unpack_from("<4sQQQ", data),
                                     (b"DSD ", 28, len(data), 0))
                    self.assertEqual(struct.unpack_from("<4sQIIIIIIQII", data, 28),
                                     (b"fmt ", 52, 1, 0, 2, 2, rate * 16, 1, 2051 * 16, 4096, 0))
                    self.assertEqual(struct.unpack_from("<4sQ", data, 80),
                                     (b"data", 12 + 16384))
                    self.assertEqual(len(data), 92 + 16384)

    def test_dsf_channel_blocks_reverse_bits_and_pad_only_after_last_samples(self):
        sources, references = self.generate("dsf")
        for source, reference in zip(sources, references):
            data = source.read_bytes()[92:]
            channels = self.wav_channels(reference)
            for channel in (0, 1):
                expected = bytes(int(f"{value:08b}"[::-1], 2) for value in channels[channel])
                self.assertEqual(data[channel * 4096:(channel + 1) * 4096], expected[:4096])
                final_start = 8192 + channel * 4096
                self.assertEqual(data[final_start:final_start + 6], expected[4096:])
                self.assertEqual(data[final_start + 6:final_start + 4096], b"\0" * 4090)
            with wave.open(str(reference), "rb") as stream:
                self.assertEqual(stream.getnframes(), 2051)

    def test_dff_headers_chunks_and_interleaving_describe_uncompressed_msb_dsd(self):
        for rate in (176400, 352800):
            with self.subTest(rate=rate):
                sources, references = self.generate("dff", rate, frames=7)
                for source, reference in zip(sources, references):
                    data = source.read_bytes()
                    self.assertEqual(struct.unpack_from(">4sQ4s", data),
                                     (b"FRM8", len(data) - 12, b"DSD "))
                    chunks = self.dff_chunks(data[16:])
                    self.assertEqual(list(chunks), [b"FVER", b"PROP", b"DSD "])
                    self.assertEqual(chunks[b"FVER"], b"\x01\x05\0\0")
                    self.assertEqual(chunks[b"PROP"][:4], b"SND ")
                    properties = self.dff_chunks(chunks[b"PROP"][4:])
                    self.assertEqual(list(properties), [b"FS  ", b"CHNL", b"CMPR"])
                    self.assertEqual(properties[b"FS  "], struct.pack(">I", rate * 16))
                    self.assertEqual(properties[b"CHNL"], b"\0\x02SLFTSRGT")
                    self.assertEqual(properties[b"CMPR"], b"DSD \x0enot compressed")
                    left, right = self.wav_channels(reference)
                    self.assertEqual(chunks[b"DSD "], bytes(byte for pair in zip(left, right) for byte in pair))
                    self.assertEqual(len(chunks[b"DSD "]), 28)

    def test_known_non_palindromic_bytes_keep_temporal_and_bit_order(self):
        references = [write_dop_wav(self.directory / f"known-{track}.wav",
                                    [(0x0196, 0x8069), (0x8069, 0x0196)]) for track in (1, 2)]
        with patch.object(verifier, "generate_dop_fixtures", return_value=references):
            for container in ("dsf", "dff"):
                with self.subTest(container=container):
                    sources, generated_references = self.generate(container, frames=2)
                    self.assertEqual(generated_references, references)
                    data = sources[0].read_bytes()
                    if container == "dsf":
                        self.assertEqual(data[92:96], b"\x80\x69\x01\x96")
                        self.assertEqual(data[92 + 4096:96 + 4096], b"\x01\x96\x80\x69")
                    else:
                        chunks = self.dff_chunks(data[16:])
                        self.assertEqual(chunks[b"DSD "], b"\x01\x80\x96\x69\x80\x01\x69\x96")

    def test_sources_and_oracles_are_deterministic_and_tracks_and_channels_distinct(self):
        for container in ("dsf", "dff"):
            with self.subTest(container=container):
                sources, references = self.generate(container, frames=257)
                originals = [path.read_bytes() for path in sources + references]
                self.assertNotEqual(originals[0], originals[1])
                self.assertNotEqual(originals[2], originals[3])
                for reference in references:
                    left, right = self.wav_channels(reference)
                    self.assertNotEqual(left, right)
                    self.assertGreater(len(set(left)), 200)
                self.generate(container, frames=257)
                self.assertEqual(originals, [path.read_bytes() for path in sources + references])

    def test_default_dsf_second_contains_real_partial_block_but_oracle_has_no_padding(self):
        sources, references = self.generate("dsf", frames=None)
        for source, reference in zip(sources, references):
            data = source.read_bytes()
            self.assertEqual(struct.unpack_from("<Q", data, 64)[0], 2822400)
            self.assertEqual(len(data), 92 + 87 * 8192)
            for channel in (0, 1):
                final_start = 92 + 86 * 8192 + channel * 4096
                self.assertNotEqual(data[final_start:final_start + 544], b"\0" * 544)
                self.assertEqual(data[final_start + 544:final_start + 4096], b"\0" * 3552)
            with wave.open(str(reference), "rb") as stream:
                self.assertEqual((stream.getframerate(), stream.getnframes()), (176400, 176400))

    def test_invalid_container_rate_or_frames_fail_before_creating_files(self):
        for container, rate, frames in (("wav", 176400, 1), ("DSF", 176400, 1),
                                        (None, 176400, 1), ("dsf", 48000, 1),
                                        ("dff", 0, 1), ("dsf", True, 1),
                                        ("dff", 176400.0, 1), ("dsf", 176400, 0),
                                        ("dff", 176400, -1), ("dsf", 176400, True),
                                        ("dff", 176400, 1.5), ("dsf", 176400, 0xFFFFFFFF)):
            with self.subTest(container=container, rate=rate, frames=frames):
                with self.assertRaises(ValueError):
                    self.generate(container, rate, frames)
                self.assertEqual(list(self.directory.iterdir()), [])

    def test_cli_generate_dsf_reports_source_and_oracle_hashes_and_sample_metadata(self):
        output = self.directory / "cli-dsf"
        result = subprocess.run([sys.executable, str(TOOL), "generate-dsd", "--container", "dsf",
                                 "--output", str(output), "--rate", "176400"],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["data_kind"], "dsd_diagnostic_payload_not_listening_audio")
        self.assertEqual((len(report["sources"]), len(report["references"])), (2, 2))
        for info in report["sources"]:
            path = Path(info["path"])
            self.assertEqual(path.suffix, ".dsf")
            self.assertEqual((info["format"], info["rate"], info["channels"], info["sample_count"]),
                             ("dsf", 2822400, 2, 2822400))
            self.assertEqual(info["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        for info in report["references"]:
            self.assertEqual((info["format"], info["rate"], info["frames"]),
                             ("wav_pcm_s24_le", 176400, 176400))
            self.assertEqual(info["sha256"], hashlib.sha256(Path(info["path"]).read_bytes()).hexdigest())

    def test_cli_generate_dff_accepts_dsd128(self):
        output = self.directory / "cli-dff"
        result = subprocess.run([sys.executable, str(TOOL), "generate-dsd", "--container", "dff",
                                 "--output", str(output), "--rate", "352800"],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        for info in report["sources"]:
            self.assertEqual((info["format"], info["rate"], info["sample_count"]),
                             ("dff", 5644800, 5644800))
            self.assertEqual(Path(info["path"]).suffix, ".dff")

    def test_cli_invalid_dsd_options_are_json_errors_without_output_files(self):
        output = self.directory / "invalid"
        for options in (["--container", "wav", "--rate", "176400"],
                        ["--container", "dsf", "--rate", "48000"],
                        ["--container", "dff", "--rate", "invalid"], ["--rate", "176400"]):
            with self.subTest(options=options):
                result = subprocess.run([sys.executable, str(TOOL), "generate-dsd", "--output",
                                         str(output), *options], text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertEqual(json.loads(result.stdout)["status"], "error")
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
