#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded, complete stereo PCM and DoP comparison (software evidence only).

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
DOP_RATES = (176400, 352800)
DOP_IDLE = (0x6969, 0x6969)


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


def generate_dop_fixtures(directory: Path, rate: int,
                          frames: int | None = None) -> list[Path]:
    """Emit two deterministic WAV24 DoP diagnostic tracks, not listening audio."""
    _integer(rate, "rate", 1)
    if rate not in DOP_RATES:
        raise ValueError("DoP rate must be 176400 or 352800")
    frames = rate if frames is None else _integer(frames, "frames", 1)
    if frames * 6 > 0xFFFFFFFF - 36:
        raise ValueError("Fixture exceeds RIFF PCM limits")
    directory = Path(directory)
    paths = []
    try:
        directory.mkdir(parents=True, exist_ok=True)
        for track in (1, 2):
            path = directory / f"dop-{rate}-24-track-{track}.wav"
            state = 0xD509AB31 ^ (track * 0x42311F)
            with wave.open(str(path), "wb") as stream:
                stream.setnchannels(2)
                stream.setsampwidth(3)
                stream.setframerate(rate)
                for start in range(0, frames, CHUNK_FRAMES):
                    block = bytearray()
                    for index in range(start, min(start + CHUNK_FRAMES, frames)):
                        pair = []
                        for channel in (0, 1):
                            state ^= (state << 13) & 0xFFFFFFFF
                            state ^= state >> 17
                            state ^= (state << 5) & 0xFFFFFFFF
                            payload = state & 0xFFFF
                            pair.append(payload if payload != 0x6969 else 0x6968)
                        if pair[0] == pair[1]:
                            pair[1] ^= 0xFFFF
                        marker = 0x05 if index % 2 == 0 else 0xFA
                        for payload in pair:
                            block.extend(payload.to_bytes(2, "little"))
                            block.append(marker)
                    stream.writeframesraw(block)
            paths.append(path)
    except (OSError, wave.Error, struct.error) as error:
        raise ValueError(f"Cannot generate DoP fixtures: {error}") from error
    return paths


def generate_dsd_fixtures(directory: Path, rate: int, *, container: str,
                          frames: int | None = None) -> tuple[list[Path], list[Path]]:
    """Wrap the diagnostic DoP payload in stereo DSF or uncompressed DFF.

    One carrier frame represents 16 DSD samples per channel. The references
    retain exactly those frames; final DSF block padding is container data only.
    """
    if container not in ("dsf", "dff"):
        raise ValueError("DSD container must be dsf or dff")
    frames = rate if frames is None else _integer(frames, "frames", 1)
    references = generate_dop_fixtures(directory, rate, frames)
    dsd_rate = rate * 16
    if container == "dsf":
        payload_size = ((frames * 2 + 4095) // 4096) * 8192
        header = (struct.pack("<4sQQQ", b"DSD ", 28, 92 + payload_size, 0)
                  + struct.pack("<4sQIIIIIIQII", b"fmt ", 52, 1, 0, 2, 2,
                                dsd_rate, 1, frames * 16, 4096, 0)
                  + struct.pack("<4sQ", b"data", 12 + payload_size))
        reversed_bits = bytes(int(f"{byte:08b}"[::-1], 2) for byte in range(256))
    else:
        def chunk(name, payload):
            return struct.pack(">4sQ", name, len(payload)) + payload + b"\0" * (len(payload) & 1)

        properties = (b"SND " + chunk(b"FS  ", struct.pack(">I", dsd_rate))
                      + chunk(b"CHNL", b"\0\x02SLFTSRGT")
                      + chunk(b"CMPR", b"DSD \x0enot compressed"))
        prefix = b"DSD " + chunk(b"FVER", b"\x01\x05\0\0") + chunk(b"PROP", properties)
        header = (struct.pack(">4sQ", b"FRM8", len(prefix) + 12 + frames * 4)
                  + prefix + struct.pack(">4sQ", b"DSD ", frames * 4))
    sources = []
    try:
        for track, reference in enumerate(references, 1):
            path = Path(directory) / f"dsd-{dsd_rate}-track-{track}.{container}"
            with wave.open(str(reference), "rb") as oracle, path.open("wb") as stream:
                stream.write(header)
                for start in range(0, frames, 2048):
                    data = oracle.readframes(min(2048, frames - start))
                    # Little-endian WAV24 is [newer, older, marker]. Emit the
                    # temporal order [older, newer] before changing bit order.
                    if container == "dsf":
                        for channel in (0, 1):
                            payload = bytes(byte for index in range(channel * 3, len(data), 6)
                                            for byte in (data[index + 1], data[index]))
                            stream.write(payload.translate(reversed_bits))
                            stream.write(b"\0" * (4096 - len(payload)))
                    else:
                        stream.write(bytes(byte for index in range(0, len(data), 6)
                                           for byte in (data[index + 1], data[index + 4],
                                                        data[index], data[index + 3])))
            sources.append(path)
    except (OSError, wave.Error, struct.error) as error:
        raise ValueError(f"Cannot generate DSD fixtures: {error}") from error
    return sources, references


def _dop_frames(info):
    """Reuse bounded PCM reads; keep both payload bytes and S32 low padding."""
    frames = _frames(info)
    try:
        for pair in frames:
            yield (tuple((value >> 8) & 0xFFFF for value in pair),
                   tuple((value >> 24) & 0xFF for value in pair),
                   tuple(value & 0xFF for value in pair))
    finally:
        frames.close()


def _dop_reference_frames(references):
    for reference in references:
        yield from _dop_frames(reference)


def _dop_leading(frames, *, startup_pcm=False):
    count = 0
    try:
        for payload, markers, padding in frames:
            zero = payload == (0, 0) and markers == (0, 0) and padding == (0, 0)
            if payload != DOP_IDLE and not (startup_pcm and zero):
                return count, False
            count += 1
        return count, True
    finally:
        frames.close()


def _validate_dop_reference(info):
    first_marker = None
    previous = None
    for index, (_, markers, _) in enumerate(_dop_frames(info)):
        if (markers[0] not in (0x05, 0xFA) or markers[0] != markers[1]
                or (previous is not None and markers[0] != previous ^ 0xFF)):
            raise ValueError(f"Invalid DoP source markers at frame {index}: {info['path']}")
        if first_marker is None:
            first_marker = markers[0]
        previous = markers[0]
    return first_marker


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
    return _compare_pcm_frames(source, captured, offset_frames=offset_frames,
                               max_lead_frames=max_lead_frames)


def compare_pcm_sequence(references, capture, *, capture_format, rate_sequence,
                         offset_frames=None, max_lead_frames=0,
                         max_trailing_frames=0, pacing_rate=None):
    """Compare native PCM frames and independently require ordered engine rates.

    Headerless capture has no sample rate. Consumer pacing describes how the
    stdout bytes were drained; it never changes source samples or expectations.
    Reference and capture frame ranges are half-open, with no boundary alignment.
    """
    if not references:
        raise ValueError("At least one WAV reference is required")
    _integer(max_lead_frames, "max_lead_frames")
    _integer(max_trailing_frames, "max_trailing_frames")
    if offset_frames is not None:
        _integer(offset_frames, "offset_frames")
    if pacing_rate is not None:
        _integer(pacing_rate, "pacing_rate", 1)
    if not isinstance(rate_sequence, (list, tuple)):
        raise ValueError("rate_sequence must be a list or tuple of integer rates")
    observed = [_integer(rate, "rate_sequence entry", 1) for rate in rate_sequence]
    source = [_wav_info(path) for path in references]
    captured = _raw_info(capture, capture_format, None)
    report = _compare_pcm_frames(source, captured, offset_frames=offset_frames,
                                 max_lead_frames=max_lead_frames,
                                 max_trailing_frames=max_trailing_frames)
    expected = [info["rate"] for info in source]
    report.update(expected_rate_sequence=expected, observed_rate_sequence=observed,
                  rate_sequence_match=observed == expected)
    report["capture"]["pacing_rate"] = pacing_rate
    start = 0
    mismatch = report["first_mismatch"]
    for index, info in enumerate(report["references"]):
        end = start + info["frames"]
        info.update(expected_start_frame=start, expected_end_frame=end,
                    capture_start_frame=start + report["leading_frames"],
                    capture_end_frame=end + report["leading_frames"])
        if mismatch is not None and mismatch["expected_frame"] is not None:
            frame = mismatch["expected_frame"]
            if start <= frame < end:
                mismatch.update(reference_index=index, reference_frame=frame - start)
        start = end
    for index, boundary in enumerate(report["boundaries"]):
        boundary.update(from_rate=expected[index], to_rate=expected[index + 1])
    report["status"] = "pass" if report["sequence_match"] and report["rate_sequence_match"] else "fail"
    return report


def _compare_pcm_frames(source, captured, *, offset_frames, max_lead_frames,
                        max_trailing_frames=None):
    """Shared streaming frame gate; None keeps legacy unbounded edge behavior."""
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
    if max_trailing_frames is not None and offset_frames > max_lead_frames:
        first_mismatch = {"reason": "leading_silence_limit", "expected_frame": 0,
                          "capture_frame": offset_frames, "allowed_frames": max_lead_frames}
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
        if (max_trailing_frames is not None and trailing_frames > max_trailing_frames
                and first_mismatch is None):
            first_mismatch = {"reason": "trailing_silence_limit", "expected_frame": None,
                              "capture_frame": expected_frames + offset_frames + max_trailing_frames,
                              "allowed_frames": max_trailing_frames}
    finally:
        capture_frames.close()
    sequence_match = sample_match and first_mismatch is None
    report = {"status": "pass" if sequence_match else "fail", "sample_match": sample_match,
            "sequence_match": sequence_match, "expected_frames": expected_frames,
            "compared_frames": compared_frames, "leading_frames": offset_frames,
            "trailing_frames": trailing_frames, "alignment": alignment,
            "max_lead_frames": max_lead_frames, "boundaries": boundaries,
            "first_mismatch": first_mismatch,
            "references": [_public_info(info) for info in source],
            "capture": _public_info(captured)}
    if max_trailing_frames is not None:
        report["max_trailing_frames"] = max_trailing_frames
    return report


def compare_dop_capture(references: list[Path], capture: Path, *, capture_format: str,
                        capture_rate: int, offset_frames: int | None = None,
                        max_lead_frames: int = 0) -> dict:
    """Compare full stereo DSD payload and legal continuous DoP framing.

    Source WAVs may independently begin with 05 or FA. The capture may begin
    with either phase but must alternate continuously, including border idle.
    Only startup PCM zeros before the first DoP frame and stereo 6969 DoP idle
    may precede the source. Only DoP idle may follow it. Automatic alignment
    subtracts source idle from capture idle; an explicit offset declares the
    leading allowance itself. Neither path searches or drops internal frames.
    """
    if not references:
        raise ValueError("At least one WAV reference is required")
    _integer(capture_rate, "capture_rate", 1)
    _integer(max_lead_frames, "max_lead_frames")
    if offset_frames is not None:
        _integer(offset_frames, "offset_frames")
    if capture_rate not in DOP_RATES:
        raise ValueError("DoP capture rate must be 176400 or 352800")
    if capture_format not in ("s24_3le", "s24_le", "s32_le"):
        raise ValueError("DoP capture requires s24_3le, s24_le or s32_le")
    source = [_wav_info(path) for path in references]
    if any(info["bits"] != 24 for info in source):
        raise ValueError("DoP references must be stereo WAV24")
    if any(info["rate"] != capture_rate for info in source):
        raise ValueError("Reference and capture sample rates must match")
    reference_phases = [_validate_dop_reference(info) for info in source]
    captured = _raw_info(capture, capture_format, capture_rate)
    expected_frames = sum(info["frames"] for info in source)
    alignment = "explicit" if offset_frames is not None else "automatic"
    first_mismatch = None

    def record(error):
        nonlocal first_mismatch
        if first_mismatch is None or error["capture_frame"] < first_mismatch["capture_frame"]:
            first_mismatch = error

    if offset_frames is None:
        source_lead, silent = _dop_leading(_dop_reference_frames(source))
        if silent:
            raise ValueError("All-idle DoP references require an explicit offset_frames")
        capture_lead, _ = _dop_leading(_dop_frames(captured), startup_pcm=True)
        offset_frames = max(0, capture_lead - source_lead)
        if offset_frames > max_lead_frames:
            record({"reason": "leading_silence_limit", "expected_frame": 0,
                    "capture_frame": offset_frames, "allowed_frames": max_lead_frames})
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

    markers_match = True
    padding_match = True
    capture_first_marker = None
    capture_first_dop_frame = None
    previous_marker = None

    def inspect(frame, capture_index, expected_index=None, *, allow_startup_pcm=False):
        nonlocal markers_match, padding_match, previous_marker
        nonlocal capture_first_marker, capture_first_dop_frame
        payload, markers, padding = frame
        good = True
        if padding != (0, 0):
            padding_match = False
            good = False
            channel = 0 if padding[0] else 1
            record({"reason": "nonzero_s32_padding", "expected_frame": expected_index,
                    "capture_frame": capture_index, "channel": channel,
                    "expected": 0, "actual": padding[channel]})
        startup_zero = (allow_startup_pcm and payload == (0, 0) and markers == (0, 0)
                        and padding == (0, 0) and capture_first_dop_frame is None)
        if not startup_zero:
            if capture_first_dop_frame is None:
                capture_first_dop_frame = capture_index
                capture_first_marker = markers[0]
            reason = None
            if markers[0] not in (0x05, 0xFA) or markers[1] not in (0x05, 0xFA):
                reason = "illegal_dop_marker"
            elif markers[0] != markers[1]:
                reason = "dop_channel_marker_mismatch"
            elif previous_marker is not None and markers[0] != previous_marker ^ 0xFF:
                reason = "dop_marker_not_alternating"
            if reason:
                markers_match = False
                good = False
                record({"reason": reason, "expected_frame": expected_index,
                        "capture_frame": capture_index, "actual": list(markers),
                        "expected": None if previous_marker is None else previous_marker ^ 0xFF})
            previous_marker = markers[0]
        return good, startup_zero

    capture_frames = _dop_frames(captured)
    try:
        for index in range(offset_frames):
            actual = next(capture_frames)
            _, startup_zero = inspect(actual, index, allow_startup_pcm=True)
            if actual[0] != DOP_IDLE and not startup_zero:
                record({"reason": "nonidle_leading_frame", "expected_frame": None,
                        "capture_frame": index, "actual": list(actual[0])})
        payload_match = True
        compared_frames = 0
        for index, expected in enumerate(_dop_reference_frames(source)):
            actual = next(capture_frames, None)
            good = False
            if actual is not None:
                compared_frames += 1
                good, _ = inspect(actual, index + offset_frames, index)
            if actual is None or actual[0] != expected[0]:
                payload_match = False
                good = False
                channel = next((channel for channel in (0, 1)
                                if actual is None or actual[0][channel] != expected[0][channel]), 0)
                record({"reason": "missing_frame" if actual is None else "payload_mismatch",
                        "expected_frame": index, "capture_frame": index + offset_frames,
                        "channel": channel, "expected": expected[0][channel],
                        "actual": None if actual is None else actual[0][channel]})
            if not good:
                for boundary in boundary_checks.get(index, ()):
                    boundary["match"] = False
        trailing_frames = 0
        for actual in capture_frames:
            capture_index = expected_frames + offset_frames + trailing_frames
            inspect(actual, capture_index)
            if actual[0] != DOP_IDLE:
                record({"reason": "nonidle_trailing_frame", "expected_frame": None,
                        "capture_frame": capture_index, "actual": list(actual[0])})
            trailing_frames += 1
    finally:
        capture_frames.close()
    sequence_match = payload_match and markers_match and padding_match and first_mismatch is None
    return {"status": "pass" if sequence_match else "fail", "payload_match": payload_match,
            "markers_match": markers_match, "padding_match": padding_match,
            "sequence_match": sequence_match, "expected_frames": expected_frames,
            "compared_frames": compared_frames, "leading_frames": offset_frames,
            "trailing_frames": trailing_frames, "alignment": alignment,
            "max_lead_frames": max_lead_frames, "boundaries": boundaries,
            "first_mismatch": first_mismatch,
            "marker_phase": {"reference_first": reference_phases,
                             "capture_first": capture_first_marker,
                             "capture_first_dop_frame": capture_first_dop_frame,
                             "policy": "independent_initial_phase_continuous_capture"},
            "scope": "software_stdout", "classification": "dop_payload_preserved_legal_framing",
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
    generate_dop = commands.add_parser("generate-dop")
    generate_dop.add_argument("--output", type=Path, required=True)
    generate_dop.add_argument("--rate", type=int, required=True)
    generate_dsd = commands.add_parser("generate-dsd")
    generate_dsd.add_argument("--output", type=Path, required=True)
    generate_dsd.add_argument("--rate", type=int, required=True)
    generate_dsd.add_argument("--container", choices=("dsf", "dff"), required=True)
    for command in ("compare", "compare-dop", "compare-pcm-sequence"):
        compare = commands.add_parser(command)
        compare.add_argument("--reference", type=Path, action="append", required=True)
        compare.add_argument("--capture", type=Path, required=True)
        compare.add_argument("--capture-format", required=True)
        if command == "compare-pcm-sequence":
            compare.add_argument("--observed-rate", type=int, action="append", default=[])
            compare.add_argument("--max-trailing-frames", type=int, default=0)
            compare.add_argument("--pacing-rate", type=int)
        else:
            compare.add_argument("--capture-rate", type=int, required=True)
        compare.add_argument("--offset-frames", type=int)
        compare.add_argument("--max-lead-frames", type=int, default=0)
        compare.add_argument("--report", type=Path)
    report_path = None
    input_paths = []
    try:
        args = parser.parse_args(argv)
        if args.command in ("generate", "generate-dop"):
            paths = (generate_fixtures(args.output, args.rate, args.bits) if args.command == "generate"
                     else generate_dop_fixtures(args.output, args.rate))
            report = {"status": "pass", "references": [_public_info(_wav_info(path)) for path in paths]}
            if args.command == "generate-dop":
                report["data_kind"] = "dop_diagnostic_payload_not_listening_audio"
        elif args.command == "generate-dsd":
            sources, references = generate_dsd_fixtures(args.output, args.rate, container=args.container)
            reference_info = [_public_info(_wav_info(path)) for path in references]
            report = {"status": "pass", "data_kind": "dsd_diagnostic_payload_not_listening_audio",
                      "references": reference_info,
                      "sources": [{"path": str(path), "format": args.container, "rate": args.rate * 16,
                                   "channels": 2, "sample_count": info["frames"] * 16,
                                   "sha256": _sha256(path)} for path, info in zip(sources, reference_info)]}
        else:
            input_paths = [args.capture, *args.reference]
            if args.report is not None:
                # Assign only after validation: even an error report must never
                # be written onto the capture or any reference.
                report_path = _report_output_path(args.report, input_paths)
            options = {"capture_format": args.capture_format, "offset_frames": args.offset_frames,
                       "max_lead_frames": args.max_lead_frames}
            if args.command == "compare-pcm-sequence":
                report = compare_pcm_sequence(args.reference, args.capture, **options,
                                              rate_sequence=args.observed_rate,
                                              max_trailing_frames=args.max_trailing_frames,
                                              pacing_rate=args.pacing_rate)
            else:
                comparator = compare_capture if args.command == "compare" else compare_dop_capture
                report = comparator(args.reference, args.capture, **options,
                                    capture_rate=args.capture_rate)
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
