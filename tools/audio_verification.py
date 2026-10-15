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
DOP_RATES = (176400, 352800, 705600)
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


# --- Sorgenti compresse (FLAC, ALAC) generate dagli stessi WAV di riferimento ---
# Encoder minimi e deterministici, senza dipendenze: solo frame "verbatim" (FLAC)
# e pacchetti non compressi (ALAC). Non comprimono, ma il decoder del player
# percorre lo stesso demux/parser del contenitore e deve restituire gli stessi
# campioni del WAV.
CODECS = ("flac", "alac")
CODEC_EXTENSIONS = {"flac": "flac", "alac": "m4a"}
CODEC_BLOCK_FRAMES = 4096


def _crc(data, polynomial, width):
    top = 1 << (width - 1)
    mask = (1 << width) - 1
    value = 0
    for byte in data:
        value ^= byte << (width - 8)
        for _ in range(8):
            value = ((value << 1) ^ polynomial) & mask if value & top else (value << 1) & mask
    return value


def _wav_pcm(path):
    """Rate, bits and raw little-endian interleaved stereo PCM of a WAV."""
    with wave.open(str(path), "rb") as stream:
        if stream.getnchannels() != 2:
            raise ValueError("codec fixtures need a stereo WAV")
        return stream.getframerate(), stream.getsampwidth() * 8, stream.readframes(stream.getnframes())


def _utf8_number(value):
    if value < 0x80:
        return bytes([value])
    for count in range(2, 7):
        if value < 1 << (5 * count + 1):
            tail = [0x80 | ((value >> (6 * index)) & 0x3F) for index in range(count - 2, -1, -1)]
            return bytes([((0xFF00 >> count) & 0xFF) | (value >> (6 * (count - 1)))] + tail)
    raise ValueError("frame number too large")


def encode_flac(wav: Path, destination: Path) -> Path:
    """Write a FLAC made only of verbatim subframes (STREAMINFO with MD5)."""
    rate, bits, pcm = _wav_pcm(wav)
    if bits not in (16, 24):
        raise ValueError("FLAC fixtures are 16 or 24 bit")
    width = bits // 8
    total = len(pcm) // (2 * width)
    frames = []
    for number, start in enumerate(range(0, total, CODEC_BLOCK_FRAMES)):
        count = min(CODEC_BLOCK_FRAMES, total - start)
        # Sync, fixed block size, size on 16 bit after the number, rate and
        # depth from STREAMINFO, two independent channels.
        header = b"\xff\xf8" + bytes([0x70, 0x10]) + _utf8_number(number) + (count - 1).to_bytes(2, "big")
        header += bytes([_crc(header, 0x07, 8)])
        left = bytearray()
        right = bytearray()
        for index in range(start, start + count):
            offset = index * 2 * width
            left += pcm[offset:offset + width][::-1]
            right += pcm[offset + width:offset + 2 * width][::-1]
        frame = header + b"\x02" + bytes(left) + b"\x02" + bytes(right)  # 0x02: verbatim subframe
        frames.append(frame + _crc(frame, 0x8005, 16).to_bytes(2, "big"))
    sizes = [len(frame) for frame in frames] or [0]
    info = (CODEC_BLOCK_FRAMES.to_bytes(2, "big") + CODEC_BLOCK_FRAMES.to_bytes(2, "big")
            + min(sizes).to_bytes(3, "big") + max(sizes).to_bytes(3, "big")
            + ((rate << 44) | (1 << 41) | ((bits - 1) << 36) | total).to_bytes(8, "big")
            + hashlib.md5(pcm).digest())
    destination = Path(destination)
    destination.write_bytes(b"fLaC" + bytes([0x80, 0, 0, 34]) + info + b"".join(frames))
    return destination


def _box(kind, payload=b""):
    return struct.pack(">I4s", 8 + len(payload), kind) + payload


def _full_box(kind, payload=b"", version_flags=0):
    return _box(kind, struct.pack(">I", version_flags) + payload)


def _alac_packet(pcm, start, count, bits, width):
    """One uncompressed ALAC packet: stereo element, explicit count, raw samples."""
    out = bytearray()
    state = [0, 0]  # bit accumulator, bits in use

    def put(value, size):
        state[0] = (state[0] << size) | (value & ((1 << size) - 1))
        state[1] += size
        while state[1] >= 8:
            state[1] -= 8
            out.append((state[0] >> state[1]) & 0xFF)
        state[0] &= (1 << state[1]) - 1

    put(1, 3)    # CPE (coppia stereo)
    put(0, 4)    # instance tag
    put(0, 12)   # non usati
    put(1, 1)    # il pacchetto porta il numero di campioni
    put(0, 2)    # nessun bit extra
    put(1, 1)    # non compresso
    put(count, 32)
    for index in range(start, start + count):
        offset = index * 2 * width
        for channel in (0, 1):
            put(int.from_bytes(pcm[offset + channel * width:offset + (channel + 1) * width],
                               "little", signed=True), bits)
    put(7, 3)    # fine del pacchetto
    if state[1]:
        put(0, 8 - state[1])
    return bytes(out)


def encode_alac(wav: Path, destination: Path) -> Path:
    """Write an ALAC in an M4A with uncompressed packets (one chunk)."""
    rate, bits, pcm = _wav_pcm(wav)
    if bits not in (16, 24):
        raise ValueError("ALAC fixtures are 16 or 24 bit")
    width = bits // 8
    total = len(pcm) // (2 * width)
    packets = [_alac_packet(pcm, start, min(CODEC_BLOCK_FRAMES, total - start), bits, width)
               for start in range(0, total, CODEC_BLOCK_FRAMES)]
    sizes = [len(packet) for packet in packets]
    cookie = _full_box(b"alac", struct.pack(">IBBBBBBHIII", CODEC_BLOCK_FRAMES, 0, bits, 40, 10, 14, 2, 255,
                                            max(sizes), rate * bits * 2, rate))
    entry = (b"\0" * 6 + struct.pack(">HHHIHHHHI", 1, 0, 0, 0, 2, bits, 0, 0, (rate << 16) & 0xFFFFFFFF)
             + cookie)
    last = total - CODEC_BLOCK_FRAMES * (len(packets) - 1)
    durations = [(len(packets) - 1, CODEC_BLOCK_FRAMES)] if len(packets) > 1 else []
    durations.append((1, last))
    ftyp = _box(b"ftyp", b"M4A \0\0\0\0M4A mp42isom")
    matrix = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)

    def moov(offset):
        stbl = (_full_box(b"stsd", struct.pack(">I", 1) + _box(b"alac", entry))
                + _full_box(b"stts", struct.pack(">I", len(durations))
                            + b"".join(struct.pack(">II", n, d) for n, d in durations))
                + _full_box(b"stsc", struct.pack(">IIII", 1, 1, len(packets), 1))
                + _full_box(b"stsz", struct.pack(">II", 0, len(packets))
                            + b"".join(struct.pack(">I", size) for size in sizes))
                + _full_box(b"stco", struct.pack(">II", 1, offset)))
        minf = (_full_box(b"smhd", b"\0\0\0\0")
                + _box(b"dinf", _full_box(b"dref", struct.pack(">I", 1) + _full_box(b"url ", b"", 1)))
                + _box(b"stbl", stbl))
        mdia = (_full_box(b"mdhd", struct.pack(">IIIIHH", 0, 0, rate, total, 0x55C4, 0))
                + _full_box(b"hdlr", struct.pack(">I4s12s", 0, b"soun", b"") + b"\0")
                + _box(b"minf", minf))
        tkhd = _full_box(b"tkhd", struct.pack(">IIIII8xhhhh", 0, 0, 1, 0, total, 0, 0, 0x100, 0)
                         + matrix + struct.pack(">II", 0, 0), 3)
        mvhd = _full_box(b"mvhd", struct.pack(">IIII", 0, 0, rate, total) + struct.pack(">iH10x", 0x10000, 0x100)
                         + matrix + b"\0" * 24 + struct.pack(">I", 2))
        return _box(b"moov", mvhd + _box(b"trak", tkhd + _box(b"mdia", mdia)))

    offset = len(ftyp) + len(moov(0)) + 8
    destination = Path(destination)
    destination.write_bytes(ftyp + moov(offset) + _box(b"mdat", b"".join(packets)))
    return destination


def generate_codec_fixtures(directory: Path, rate: int, bits: int, codec: str,
                            frames: int | None = None) -> tuple[list[Path], list[Path]]:
    """FLAC or ALAC sources of the same two WAV references the PCM matrix uses."""
    if codec not in CODECS:
        raise ValueError("codec must be flac or alac")
    references = generate_fixtures(directory, rate, bits, frames)
    encode = encode_flac if codec == "flac" else encode_alac
    sources = [encode(reference, Path(directory) / f"{reference.stem}.{CODEC_EXTENSIONS[codec]}")
               for reference in references]
    return sources, references


def generate_dop_fixtures(directory: Path, rate: int,
                          frames: int | None = None) -> list[Path]:
    """Emit two deterministic WAV24 DoP diagnostic tracks, not listening audio."""
    _integer(rate, "rate", 1)
    if rate not in DOP_RATES:
        raise ValueError("DoP rate must be 176400, 352800 or 705600")
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
                        max_lead_frames: int = 0, scope: str = "software_stdout") -> dict:
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
        raise ValueError("DoP capture rate must be 176400, 352800 or 705600")
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
            "scope": scope, "classification": "dop_payload_preserved_legal_framing",
            "references": [_public_info(info) for info in source],
            "capture": _public_info(captured)}


DSD_TONE_LEVEL = 0.35          # ampiezza del tono principale, frazione del fondo scala DSD
DSD_ALIAS_LEVEL = 0.10         # ampiezza del tono ultrasonico che non deve ripiegare
DSD_ALIAS_HZ = 117600          # DSD64 / 24 e DSD128 / 48 campioni: periodo intero
DSD_TONE_PERIODS = (2800, 1400)  # campioni per periodo del tono di sinistra e di destra
DSD_TONE_SECONDS = 0.75


def dsd_tone_spec(dsd_rate, pcm_rate):
    """Tono (e tono ultrasonico) dei due canali del DSD di prova, e dove ripiegherebbe."""
    _integer(dsd_rate, "dsd_rate", 1)
    _integer(pcm_rate, "pcm_rate", 1)
    if dsd_rate % DSD_ALIAS_HZ or any(dsd_rate % period for period in DSD_TONE_PERIODS):
        raise ValueError("DSD rate has no whole period for the test tones")
    alias = abs(DSD_ALIAS_HZ - round(DSD_ALIAS_HZ / pcm_rate) * pcm_rate)
    return {"dsd_rate": dsd_rate, "pcm_rate": pcm_rate, "level": DSD_TONE_LEVEL,
            "tone_hz": [dsd_rate // period for period in DSD_TONE_PERIODS],
            "ultrasonic_hz": DSD_ALIAS_HZ, "ultrasonic_level": DSD_ALIAS_LEVEL,
            "alias_hz": alias}


def _dsd_modulate(dsd_rate, period, count):
    """Modulatore delta-sigma del secondo ordine: tono + tono ultrasonico -> 1 bit per campione."""
    from math import gcd, pi, sin
    ultra = dsd_rate // DSD_ALIAS_HZ
    length = period * ultra // gcd(period, ultra)
    table = [DSD_TONE_LEVEL * sin(2 * pi * index / period)
             + DSD_ALIAS_LEVEL * sin(2 * pi * index / ultra) for index in range(length)]
    bits = bytearray(count)
    v1 = v2 = 0.0
    y = 1.0
    position = 0
    for index in range(count):
        v1 += table[position] - y
        v2 += v1 - y
        position += 1
        if position == length:
            position = 0
        if v2 >= 0.0:
            y = 1.0
            bits[index] = 1
        else:
            y = -1.0
    return bits


def _dsd_pack(bits, lsb_first):
    groups = [bits[offset::8] for offset in range(8)]
    if lsb_first:
        groups.reverse()
    return bytes(a << 7 | b << 6 | c << 5 | d << 4 | e << 3 | f << 2 | g << 1 | h
                 for a, b, c, d, e, f, g, h in zip(*groups))


def generate_dsd_tone_fixtures(directory: Path, dsd_rate: int, *, container: str,
                               pcm_rate: int, seconds: float = DSD_TONE_SECONDS):
    """Two identical stereo DSF or DFF tracks with real tones, for the DSD to PCM check.

    Left and right carry different tones, each with a strong ultrasonic tone
    which the PCM conversion must remove instead of folding it into the band.
    Returns (sources, spec); spec comes from dsd_tone_spec.
    """
    if container not in ("dsf", "dff"):
        raise ValueError("DSD container must be dsf or dff")
    spec = dsd_tone_spec(dsd_rate, pcm_rate)
    count = int(dsd_rate * seconds) // 8 * 8
    channels = [_dsd_modulate(dsd_rate, period, count) for period in DSD_TONE_PERIODS]
    nbytes = count // 8
    if container == "dsf":
        # LSB first, one 4096 byte block per channel in turn.
        data = [_dsd_pack(bits, True) for bits in channels]
        blocks = (nbytes + 4095) // 4096
        payload = bytearray()
        for block in range(blocks):
            for channel in data:
                piece = channel[block * 4096:(block + 1) * 4096]
                payload += piece + b"\x69" * (4096 - len(piece))
        payload_size = blocks * 8192
        header = (struct.pack("<4sQQQ", b"DSD ", 28, 92 + payload_size, 0)
                  + struct.pack("<4sQIIIIIIQII", b"fmt ", 52, 1, 0, 2, 2,
                                dsd_rate, 1, count, 4096, 0)
                  + struct.pack("<4sQ", b"data", 12 + payload_size))
    else:
        # MSB first, one byte per channel in turn.
        data = [_dsd_pack(bits, False) for bits in channels]
        payload = bytearray(2 * nbytes)
        payload[0::2] = data[0]
        payload[1::2] = data[1]

        def chunk(name, body):
            return struct.pack(">4sQ", name, len(body)) + body + b"\0" * (len(body) & 1)

        properties = (b"SND " + chunk(b"FS  ", struct.pack(">I", dsd_rate))
                      + chunk(b"CHNL", b"\0\x02SLFTSRGT")
                      + chunk(b"CMPR", b"DSD \x0enot compressed"))
        prefix = b"DSD " + chunk(b"FVER", b"\x01\x05\0\0") + chunk(b"PROP", properties)
        header = (struct.pack(">4sQ", b"FRM8", len(prefix) + 12 + len(payload))
                  + prefix + struct.pack(">4sQ", b"DSD ", len(payload)))
    directory = Path(directory)
    sources = []
    try:
        directory.mkdir(parents=True, exist_ok=True)
        for track in (1, 2):
            path = directory / f"dsdtone-{dsd_rate}-track-{track}.{container}"
            path.write_bytes(header + bytes(payload))
            sources.append(path)
    except OSError as error:
        raise ValueError(f"Cannot generate DSD tone fixtures: {error}") from error
    return sources, spec


def _fft(real, imag):
    """In-place iterative radix-2 FFT of two equal-length lists (length a power of two)."""
    from math import cos, pi, sin
    size = len(real)
    j = 0
    for i in range(1, size):
        bit = size >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            real[i], real[j] = real[j], real[i]
            imag[i], imag[j] = imag[j], imag[i]
    length = 2
    while length <= size:
        half = length >> 1
        wr = [cos(-2 * pi * k / length) for k in range(half)]
        wi = [sin(-2 * pi * k / length) for k in range(half)]
        for start in range(0, size, length):
            for k in range(half):
                a = start + k
                b = a + half
                tr = real[b] * wr[k] - imag[b] * wi[k]
                ti = real[b] * wi[k] + imag[b] * wr[k]
                real[b] = real[a] - tr
                imag[b] = imag[a] - ti
                real[a] += tr
                imag[a] += ti
        length <<= 1


def dsd_pcm_spectra(left, right):
    """Hann windowed power spectra (bins 0..N/2) of two channels with one complex FFT."""
    from math import cos, pi
    size = len(left)
    window = [0.5 - 0.5 * cos(2 * pi * index / size) for index in range(size)]
    real = [value * w for value, w in zip(left, window)]
    imag = [value * w for value, w in zip(right, window)]
    _fft(real, imag)
    power = [[], []]
    for k in range(size // 2 + 1):
        m = (size - k) % size
        l_re, l_im = (real[k] + real[m]) / 2, (imag[k] - imag[m]) / 2
        r_re, r_im = (imag[k] + imag[m]) / 2, (real[m] - real[k]) / 2
        power[0].append(l_re * l_re + l_im * l_im)
        power[1].append(r_re * r_re + r_im * r_im)
    return power, sum(w * w for w in window)


def _median(values):
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def analyze_dsd_pcm_channel(power, window_energy, size, rate, tone_hz, other_hz, spec, margin_db):
    """Measure one channel: tone level, SNR in the band, ultrasonic tone folded or not, other channel."""
    from math import log10, sqrt
    bin_hz = rate / size

    def amplitude(center_hz, half=3):
        k = round(center_hz / bin_hz)
        total = sum(power[max(1, k - half):k + half + 1])
        return sqrt(4 * total / (size * window_energy))

    tone = amplitude(tone_hz)
    expected = spec["level"] * 10 ** (margin_db / 20) * 2147483648.0
    k_tone = round(tone_hz / bin_hz)
    band = sum(power[bin_] for bin_ in range(max(1, round(40 / bin_hz)), round(20000 / bin_hz))
               if abs(bin_ - k_tone) > 12)
    noise = 2 * band / (size * window_energy)
    k_alias = round(spec["alias_hz"] / bin_hz)
    neighbours = [power[bin_] for bin_ in range(k_alias - 200, k_alias + 201) if abs(bin_ - k_alias) > 8]
    floor = _median(neighbours) / 0.693
    peak = sum(power[k_alias - 3:k_alias + 4])
    alias = amplitude(spec["alias_hz"])
    return {"tone_hz": tone_hz, "amplitude": tone, "expected_amplitude": expected,
            "level_db": 20 * log10(tone / expected) if tone > 0 else None,
            "snr_db": 10 * log10((tone * tone / 2) / noise) if noise > 0 and tone > 0 else None,
            "alias_hz": spec["alias_hz"], "alias_db": 20 * log10(alias / tone) if alias > 0 and tone > 0 else None,
            "alias_over_floor_db": 10 * log10(peak / (7 * floor)) if peak > 0 and floor > 0 else None,
            "other_channel_db": 20 * log10(max(amplitude(other_hz), 1e-30) / tone) if tone > 0 else None}


def analyze_dsd_pcm_capture(capture: Path, *, capture_format: str, rate: int, spec: dict,
                            margin_db: float, size: int = 65536, skip_seconds: float = 0.1,
                            lead_threshold: float = 1e-3) -> dict:
    """Check a DSD to PCM capture: tone level with the margin, no folded tone, low noise.

    Looks for the first sample above the threshold, skips the filter's start,
    and analyses `size` frames. Reports every measure; "status" is "pass" when
    the tone is within 0.5 dB of the expected level, the ultrasonic tone has
    not folded (60 dB under the tone and no peak over the noise floor), the
    in band signal to noise ratio is at least 60 dB, the other channel's tone
    is 60 dB down, and no frame clips.
    """
    info = _raw_info(capture, capture_format, rate)
    result = {"status": "fail", "rate": rate, "size": size, "margin_db": margin_db, "spec": spec,
              "frames": info["frames"]}
    full_scale = 2147483648.0
    skip = int(rate * skip_seconds)
    left, right = [], []
    first = None
    peak = 0
    for index, (a, b) in enumerate(_frames(info)):
        if first is None:
            if abs(a) < lead_threshold * full_scale and abs(b) < lead_threshold * full_scale:
                continue
            first = index
        peak = max(peak, abs(a), abs(b))
        if index - first >= skip:
            left.append(float(a))
            right.append(float(b))
            if len(left) == size:
                break
    result["first_frame"] = first
    if first is None or len(left) < size:
        result["reason"] = "capture does not hold %d frames of signal" % size
        return result
    result["peak"] = peak / full_scale
    power, window_energy = dsd_pcm_spectra(left, right)
    channels = []
    for own, other in ((0, 1), (1, 0)):
        channels.append(analyze_dsd_pcm_channel(power[own], window_energy, size, rate, spec["tone_hz"][own],
                                                spec["tone_hz"][other], spec, margin_db))
    result["channels"] = channels
    problems = []
    if result["peak"] >= 0.999:
        problems.append("clipping")
    for name, channel in zip(("left", "right"), channels):
        if channel["level_db"] is None or abs(channel["level_db"]) > 0.5:
            problems.append("%s tone level %s dB from expected" % (name, channel["level_db"]))
        if channel["snr_db"] is None or channel["snr_db"] < 60:
            problems.append("%s in-band SNR %s dB" % (name, channel["snr_db"]))
        if channel["alias_db"] is None or channel["alias_db"] > -60:
            problems.append("%s folded ultrasonic tone at %s dB" % (name, channel["alias_db"]))
        if channel["alias_over_floor_db"] is None or channel["alias_over_floor_db"] > 12:
            problems.append("%s peak at %s Hz %s dB over the noise" % (name, channel["alias_hz"],
                                                                         channel["alias_over_floor_db"]))
        if channel["other_channel_db"] is None or channel["other_channel_db"] > -60:
            problems.append("%s carries the other channel's tone at %s dB" % (name, channel["other_channel_db"]))
    result["problems"] = problems
    result["status"] = "pass" if not problems else "fail"
    return result


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
