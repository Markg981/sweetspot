#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded, complete stereo integer PCM comparison (software evidence only).

WAV references use RIFF PCM (format tag 1), 16/24/32 significant bits.
ALSA S24_LE stores its significant signed bits in the low three bytes;
the fourth container byte is padding. No resampling or gain is applied.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import wave


FORMATS = {"s16_le": (16, 2), "s24_3le": (24, 3),
           "s24_le": (24, 4), "s32_le": (32, 4)}
CHUNK_FRAMES = 4096


def _integer(value, label, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}")
    return value


def _file_size(path):
    try:
        if not path.is_file():
            raise ValueError(f"Not a regular file: {path}")
        return path.stat().st_size
    except OSError as error:
        raise ValueError(f"Cannot inspect {path}: {error}") from error


def _sha256(path):
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for data in iter(lambda: stream.read(65536), b""):
                digest.update(data)
    except OSError as error:
        raise ValueError(f"Cannot read {path}: {error}") from error
    return digest.hexdigest()


def _wav_info(path):
    path = Path(path)
    size = _file_size(path)
    try:
        with path.open("rb") as stream:
            header = stream.read(12)
            if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
                raise ValueError(f"Not a RIFF WAVE file: {path}")
            if struct.unpack_from("<I", header, 4)[0] + 8 != size:
                raise ValueError(f"RIFF length differs from file length: {path}")
            pcm_format = None
            payload = None
            while stream.tell() < size:
                chunk = stream.read(8)
                if len(chunk) != 8:
                    raise ValueError(f"Truncated WAV chunk header: {path}")
                name, length = struct.unpack("<4sI", chunk)
                position = stream.tell()
                end = position + length + (length & 1)
                if end > size:
                    raise ValueError(f"Truncated WAV chunk: {path}")
                if name == b"fmt ":
                    if pcm_format is not None or length not in (16, 18):
                        raise ValueError(f"Invalid or duplicate PCM format chunk: {path}")
                    data = stream.read(length)
                    tag, channels, rate, byte_rate, alignment, bits = struct.unpack_from("<HHIIHH", data)
                    if tag != 1 or channels != 2 or bits not in (16, 24, 32) or rate == 0:
                        raise ValueError(f"Expected stereo integer PCM16/24/32 WAV: {path}")
                    if length == 18 and data[16:] != b"\0\0":
                        raise ValueError(f"Unexpected PCM format extension: {path}")
                    if alignment != channels * (bits // 8) or byte_rate != rate * alignment:
                        raise ValueError(f"Inconsistent WAV frame alignment or byte rate: {path}")
                    pcm_format = (rate, bits, alignment)
                elif name == b"data":
                    if payload is not None or pcm_format is None:
                        raise ValueError(f"Duplicate WAV data or data before format: {path}")
                    payload = (position, length)
                stream.seek(end)
            if pcm_format is None or payload is None:
                raise ValueError(f"Missing WAV format or data chunk: {path}")
            rate, bits, alignment = pcm_format
            offset, length = payload
            if length == 0 or length % alignment:
                raise ValueError(f"Empty or partial WAV PCM frame: {path}")
    except OSError as error:
        raise ValueError(f"Cannot read WAV {path}: {error}") from error
    return {"path": str(path), "format": f"wav_pcm_s{bits}_le", "rate": rate,
            "bits": bits, "channels": 2, "frames": length // alignment,
            "sha256": _sha256(path), "_offset": offset, "_width": bits // 8}


def _raw_info(path, capture_format, rate):
    if capture_format not in FORMATS:
        raise ValueError(f"Unsupported raw PCM format: {capture_format}")
    bits, width = FORMATS[capture_format]
    path = Path(path)
    size = _file_size(path)
    if size % (2 * width):
        raise ValueError(f"Raw capture has a partial stereo frame: {path}")
    return {"path": str(path), "format": capture_format, "rate": rate,
            "bits": bits, "channels": 2, "frames": size // (2 * width),
            "sha256": _sha256(path), "_offset": 0, "_width": width}


def _frames(info):
    """Read fixed size blocks; normalize significant PCM bits to signed32."""
    width, bits = info["_width"], info["bits"]
    remaining = info["frames"]
    try:
        with Path(info["path"]).open("rb") as stream:
            stream.seek(info["_offset"])
            while remaining:
                count = min(remaining, CHUNK_FRAMES)
                data = stream.read(count * width * 2)
                if len(data) != count * width * 2:
                    raise ValueError(f"PCM input became truncated: {info['path']}")
                if bits == 16:
                    for left, right in struct.iter_unpack("<hh", data):
                        yield left << 16, right << 16
                elif bits == 32:
                    yield from struct.iter_unpack("<ii", data)
                else:
                    for index in range(0, len(data), 2 * width):
                        left = int.from_bytes(data[index:index + 3], "little", signed=True)
                        right = int.from_bytes(data[index + width:index + width + 3], "little", signed=True)
                        yield left << 8, right << 8
                remaining -= count
    except OSError as error:
        raise ValueError(f"Cannot read PCM {info['path']}: {error}") from error


def _reference_frames(references):
    for reference in references:
        yield from _frames(reference)


def _leading_silence(frames):
    count = 0
    for frame in frames:
        if frame != (0, 0):
            return count, False
        count += 1
    return count, True


def _public_info(info):
    return {key: value for key, value in info.items() if not key.startswith("_")}


def generate_fixtures(directory: Path, rate: int, bits: int,
                      frames: int | None = None) -> list[Path]:
    """Emit two deterministic, distinct one-second noise/marker tracks."""
    _integer(rate, "rate", 1)
    _integer(bits, "bits", 1)
    if bits not in (16, 24, 32):
        raise ValueError("bits must be 16, 24 or 32")
    frames = rate if frames is None else _integer(frames, "frames", 1)
    width = bits // 8
    if rate * width * 2 > 0xFFFFFFFF or frames * width * 2 > 0xFFFFFFFF - 36:
        raise ValueError("Fixture exceeds RIFF PCM limits")
    directory = Path(directory)
    amplitude = (1 << (bits - 1)) // 32
    paths = []
    try:
        directory.mkdir(parents=True, exist_ok=True)
        for track in (1, 2):
            path = directory / f"pcm-{rate}-{bits}-track-{track}.wav"
            state = 0x13F92871 ^ (track * 0x42311F)
            with wave.open(str(path), "wb") as stream:
                stream.setnchannels(2)
                stream.setsampwidth(width)
                stream.setframerate(rate)
                for start in range(0, frames, CHUNK_FRAMES):
                    block = bytearray()
                    for index in range(start, min(start + CHUNK_FRAMES, frames)):
                        pair = []
                        for channel in (0, 1):
                            state ^= (state << 13) & 0xFFFFFFFF
                            state ^= state >> 17
                            state ^= (state << 5) & 0xFFFFFFFF
                            value = state % (2 * amplitude) - amplitude
                            pair.append(value if value else 1)
                        if index % 257 == 0:
                            pair = [amplitude - track, -amplitude + track * 3]
                        if pair[0] == pair[1]:
                            pair[1] = -pair[0]
                        for value in pair:
                            block.extend(value.to_bytes(width, "little", signed=True))
                    stream.writeframesraw(block)
            paths.append(path)
    except (OSError, wave.Error, struct.error) as error:
        raise ValueError(f"Cannot generate PCM fixtures: {error}") from error
    return paths


def compare_capture(references: list[Path], capture: Path, *, capture_format: str,
                    capture_rate: int, offset_frames: int | None = None,
                    max_lead_frames: int = 0) -> dict:
    """Compare the entire concatenated sequence, allowing only edge silence.

    Automatic alignment subtracts the reference's own leading silence from
    the capture's leading silence. It never searches for an interior marker.
    Explicit offsets also require every skipped frame to be zero.
    """
    if not references:
        raise ValueError("At least one WAV reference is required")
    _integer(capture_rate, "capture_rate", 1)
    _integer(max_lead_frames, "max_lead_frames")
    if offset_frames is not None:
        _integer(offset_frames, "offset_frames")
    source = [_wav_info(path) for path in references]
    if any(info["rate"] != capture_rate for info in source):
        raise ValueError("Reference and capture sample rates must match")
    captured = _raw_info(capture, capture_format, capture_rate)
    expected_frames = sum(info["frames"] for info in source)
    alignment = "explicit" if offset_frames is not None else "automatic"
    first_mismatch = None
    if offset_frames is None:
        source_lead, silent = _leading_silence(_reference_frames(source))
        if silent:
            raise ValueError("All-silent references require an explicit offset_frames")
        capture_lead, _ = _leading_silence(_frames(captured))
        offset_frames = max(0, capture_lead - source_lead)
        if offset_frames > max_lead_frames:
            first_mismatch = {"reason": "leading_silence_limit", "expected_frame": 0,
                              "capture_frame": offset_frames, "allowed_frames": max_lead_frames}
    elif offset_frames > captured["frames"]:
        raise ValueError("offset_frames exceeds the capture length")
    boundaries = []
    boundary_checks = {}
    position = 0
    for info in source[:-1]:
        position += info["frames"]
        boundary = {"after_reference": info["path"], "expected_frame": position,
                    "capture_frame": position + offset_frames, "match": True}
        boundaries.append(boundary)
        for adjacent in (position - 1, position):
            boundary_checks.setdefault(adjacent, []).append(boundary)
    capture_frames = _frames(captured)
    try:
        for index in range(offset_frames):
            frame = next(capture_frames)
            if frame != (0, 0) and first_mismatch is None:
                first_mismatch = {"reason": "nonzero_leading_frame", "expected_frame": None,
                                  "capture_frame": index, "actual": list(frame)}
        sample_match = True
        compared_frames = 0
        for index, expected in enumerate(_reference_frames(source)):
            actual = next(capture_frames, None)
            if actual is not None:
                compared_frames += 1
            if actual != expected:
                sample_match = False
                for boundary in boundary_checks.get(index, ()):
                    boundary["match"] = False
                if first_mismatch is None:
                    channel = next((channel for channel in (0, 1)
                                    if actual is None or expected[channel] != actual[channel]), 0)
                    first_mismatch = {"reason": "missing_frame" if actual is None else "sample_mismatch",
                                      "expected_frame": index, "capture_frame": index + offset_frames,
                                      "channel": channel, "expected": expected[channel],
                                      "actual": None if actual is None else actual[channel]}
        trailing_frames = 0
        for actual in capture_frames:
            if actual != (0, 0) and first_mismatch is None:
                first_mismatch = {"reason": "nonzero_trailing_frame", "expected_frame": None,
                                  "capture_frame": expected_frames + offset_frames + trailing_frames,
                                  "actual": list(actual)}
            trailing_frames += 1
    finally:
        capture_frames.close()
    sequence_match = sample_match and first_mismatch is None
    return {"status": "pass" if sequence_match else "fail", "sample_match": sample_match,
            "sequence_match": sequence_match, "expected_frames": expected_frames,
            "compared_frames": compared_frames, "leading_frames": offset_frames,
            "trailing_frames": trailing_frames, "alignment": alignment,
            "max_lead_frames": max_lead_frames, "boundaries": boundaries,
            "first_mismatch": first_mismatch,
            "references": [_public_info(info) for info in source],
            "capture": _public_info(captured)}


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def _report_output_path(report_path, input_paths):
    """Reject lexical, symlink and hardlink aliases before writing evidence."""
    try:
        output = report_path.resolve()
        for path in input_paths:
            if output == path.resolve() or (
                    output.exists() and path.exists() and output.samefile(path)):
                raise ValueError(f"Report path aliases input evidence: {path}")
    except (OSError, RuntimeError) as error:
        raise ValueError(f"Cannot validate report destination: {error}") from error
    return output


def main(argv=None):
    parser = _Parser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    generate = commands.add_parser("generate")
    generate.add_argument("--output", type=Path, required=True)
    generate.add_argument("--rate", type=int, required=True)
    generate.add_argument("--bits", type=int, required=True)
    compare = commands.add_parser("compare")
    compare.add_argument("--reference", type=Path, action="append", required=True)
    compare.add_argument("--capture", type=Path, required=True)
    compare.add_argument("--capture-format", required=True)
    compare.add_argument("--capture-rate", type=int, required=True)
    compare.add_argument("--offset-frames", type=int)
    compare.add_argument("--max-lead-frames", type=int, default=0)
    compare.add_argument("--report", type=Path)
    report_path = None
    input_paths = []
    try:
        args = parser.parse_args(argv)
        if args.command == "generate":
            paths = generate_fixtures(args.output, args.rate, args.bits)
            report = {"status": "pass", "references": [_public_info(_wav_info(path)) for path in paths]}
        else:
            input_paths = [args.capture, *args.reference]
            if args.report is not None:
                # Assign only after validation: even an error report must never
                # be written onto the capture or any reference.
                report_path = _report_output_path(args.report, input_paths)
            report = compare_capture(args.reference, args.capture, capture_format=args.capture_format,
                                     capture_rate=args.capture_rate, offset_frames=args.offset_frames,
                                     max_lead_frames=args.max_lead_frames)
        exit_code = 0 if report["status"] == "pass" else 1
    except (ValueError, OSError) as error:
        report = {"status": "error", "error": str(error)}
        exit_code = 2
    serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if report_path is not None:
        try:
            report_path = _report_output_path(report_path, input_paths)
            report_path.write_text(serialized, encoding="utf-8")
        except (ValueError, OSError) as error:
            serialized = json.dumps({"status": "error", "error": f"Cannot write report: {error}"}) + "\n"
            exit_code = 2
    sys.stdout.write(serialized)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
