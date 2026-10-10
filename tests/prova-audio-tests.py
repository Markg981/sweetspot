#!/usr/bin/env python3
"""Offline driver tests; these do not certify Lyrion or a physical DAC."""
import importlib.util
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("prova-audio.py")
DRIVER = None
if SCRIPT.exists():
    spec = importlib.util.spec_from_file_location("prova_audio", SCRIPT)
    DRIVER = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = DRIVER
    spec.loader.exec_module(DRIVER)


@contextmanager
def rpc_server(responder):
    """A protocol stand-in on a real socket, never described as real LMS."""
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            reply = responder(request)
            if isinstance(reply, tuple):
                slow_headers, delay, payload = reply
                headers = b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n"
                data = headers + payload if slow_headers else payload
                try:
                    if not slow_headers:
                        self.wfile.write(headers)
                    for byte in data:
                        self.wfile.write(bytes([byte]))
                        self.wfile.flush()
                        time.sleep(delay)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass
                return
            body = reply if isinstance(reply, bytes) else json.dumps(reply).encode()
            try:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01})
    thread.start()
    try:
        yield "http://127.0.0.1:%s" % server.server_port
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)


def success(request, result):
    return {"id": request["id"], "result": result}


def dsd_source(path, *, reverse_dsf_bits=True):
    """Unpack the diagnostic containers independently from the fixture writer."""
    data = path.read_bytes()
    if path.suffix == ".dsf":
        if data[:4] != b"DSD " or data[28:32] != b"fmt " or data[80:84] != b"data":
            raise ValueError("unexpected DSF fixture layout")
        version, format_id, channel_type, channels, rate, bits, count, block, reserved = struct.unpack_from("<IIIIIIQII", data, 40)
        if (version, format_id, channel_type, channels, bits, block, reserved) != (1, 0, 2, 2, 1, 4096, 0):
            raise ValueError("unexpected DSF format")
        channel_bytes = count // 8
        pair = [bytearray(), bytearray()]
        for start in range(92, len(data), block * channels):
            for channel in range(channels):
                pair[channel].extend(data[start + channel * block:start + (channel + 1) * block])
        pair = [bytes(samples[:channel_bytes]) for samples in pair]
        if reverse_dsf_bits:
            pair = [bytes(int(f"{value:08b}"[::-1], 2) for value in samples) for samples in pair]
    else:
        if data[:4] != b"FRM8" or data[12:16] != b"DSD ":
            raise ValueError("unexpected DFF fixture layout")

        def chunks(start, end):
            while start < end:
                name = data[start:start + 4]
                length = struct.unpack_from(">Q", data, start + 4)[0]
                yield name, start + 12, start + 12 + length
                start += 12 + length + length % 2

        rate = channels = None
        samples = None
        for name, start, end in chunks(16, len(data)):
            if name == b"PROP":
                if data[start:start + 4] != b"SND ":
                    raise ValueError("unexpected DFF properties")
                for child, value, limit in chunks(start + 4, end):
                    if child == b"FS  ":
                        rate = struct.unpack_from(">I", data, value)[0]
                    elif child == b"CHNL":
                        channels = struct.unpack_from(">H", data, value)[0]
                    elif child == b"CMPR" and data[value:value + 4] != b"DSD ":
                        raise ValueError("compressed DFF is outside this fixture test")
            elif name == b"DSD ":
                samples = data[start:end]
        if channels != 2 or rate is None or samples is None:
            raise ValueError("incomplete DFF fixture")
        bits = 1
        pair = [samples[channel::channels] for channel in range(channels)]
    return {"bits": bits, "rate": rate, "channels": channels,
            "frames": len(pair[0]) // 2, "samples": pair}


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(DRIVER, "The bounded real-player driver is not implemented")

    def test_rpc_rejects_error_envelope(self):
        with rpc_server(lambda r: {"id": r["id"], "error": {"code": -1}, "result": {}}) as url:
            with self.assertRaisesRegex(DRIVER.RpcError, "RPC error"):
                DRIVER.LmsClient(url).request("02:00:00:00:00:01", ["connected", "?"])

    def test_rpc_failure_reports_the_command_and_keeps_request_journal(self):
        with rpc_server(lambda r: {"id": r["id"], "error": {"code": -1}}) as url:
            client = DRIVER.LmsClient(url)
            with self.assertRaisesRegex(DRIVER.RpcError, "connected"):
                client.request("02:00:00:00:00:01", ["connected", "?"])
            self.assertEqual(client.journal[0]["command"], ["connected", "?"])
            self.assertIn("RPC error", client.journal[0]["error"])

    def test_rpc_rejects_malformed_and_missing_result(self):
        for reply in (b"not JSON", {"id": 1}, {"id": 1, "result": []}, {"id": 99, "result": {}}):
            with self.subTest(reply=reply), rpc_server(lambda _, reply=reply: reply) as url:
                with self.assertRaises(DRIVER.RpcError):
                    DRIVER.LmsClient(url).request("02:00:00:00:00:01", ["connected", "?"])

    def test_rpc_timeout_is_bounded(self):
        def slow(request):
            time.sleep(.15)
            return success(request, {"_connected": 1})
        with rpc_server(slow) as url:
            started = time.monotonic()
            with self.assertRaises(DRIVER.RpcError):
                DRIVER.LmsClient(url, timeout=.025).request("02:00:00:00:00:01", ["connected", "?"])
            self.assertLess(time.monotonic() - started, .12)

    def test_rpc_response_size_is_bounded(self):
        with rpc_server(lambda _: b" " * (1024 * 1024 + 1)) as url:
            with self.assertRaisesRegex(DRIVER.RpcError, "limit"):
                DRIVER.LmsClient(url).request("02:00:00:00:00:01", ["connected", "?"])

    def test_rpc_total_deadline_stops_trickling_headers_and_body(self):
        for slow_headers in (False, True):
            with self.subTest(slow_headers=slow_headers), rpc_server(lambda r: (slow_headers, .01, json.dumps(success(r, {"_connected": 1})).encode())) as url:
                started = time.monotonic()
                with self.assertRaises(DRIVER.RpcError):
                    DRIVER.LmsClient(url, timeout=.05).request("02:00:00:00:00:01", ["connected", "?"])
                self.assertLess(time.monotonic() - started, .15)

    @unittest.skipUnless(os.name == "posix", "deadline timers require POSIX")
    def test_rpc_deadline_restores_existing_signal_handler_and_timer(self):
        original_handler = signal.getsignal(signal.SIGALRM)
        original_timer = signal.getitimer(signal.ITIMER_REAL)
        previous_handler = lambda *_: None
        try:
            signal.signal(signal.SIGALRM, previous_handler)
            signal.setitimer(signal.ITIMER_REAL, 5, .3)
            with rpc_server(lambda r: success(r, {"_connected": 1})) as url:
                DRIVER.LmsClient(url).request("02:00:00:00:00:01", ["connected", "?"])
            self.assertIs(signal.getsignal(signal.SIGALRM), previous_handler)
            remaining, interval = signal.getitimer(signal.ITIMER_REAL)
            self.assertGreater(remaining, 1)
            self.assertLess(remaining, 5)
            self.assertAlmostEqual(interval, .3)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, original_handler)
            if original_timer[0]:
                signal.setitimer(signal.ITIMER_REAL, *original_timer)

    def test_remote_server_is_rejected(self):
        for url in ("http://example.com:9000", "http://127.0.0.1:9000/other", "file:///tmp/lms", "http://u:p@127.0.0.1:9000"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                DRIVER.LmsClient(url)

    def test_unconnected_player_times_out_without_claiming_ready(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            with rpc_server(lambda r: success(r, {"count": 1, "players_loop": [{"playerid": "02:00:00:00:00:01", "connected": 0}]})) as url:
                # The last RPC can exhaust the same registration deadline.
                # Both errors reject readiness; malformed replies still fail this assertion.
                with self.assertRaisesRegex(DRIVER.AudioError, "connect|RPC.*deadline"):
                    DRIVER.wait_connected(DRIVER.LmsClient(url), "02:00:00:00:00:01", process, timeout=.08, interval=.01)
        finally:
            DRIVER.stop_process(process)
        self.assertIsNotNone(process.poll())

    def test_player_exit_is_reported_before_registration_timeout(self):
        process = subprocess.Popen([sys.executable, "-c", "raise SystemExit(7)"])
        process.wait()
        with rpc_server(lambda r: success(r, {"_connected": 0})) as url:
            with self.assertRaisesRegex(DRIVER.AudioError, "7"):
                DRIVER.wait_connected(DRIVER.LmsClient(url), "02:00:00:00:00:01", process, timeout=2)

    def test_preferences_are_verified_with_real_protocol_roundtrip(self):
        state = {"playlist shuffle": 1, "playlist repeat": 2, "mixer volume": 35}
        players = set()
        def respond(request):
            player, command = request["params"]
            if command[0] != "players":
                players.add(player)
            if command[0] == "playerpref":
                state[command[1]] = int(command[2])
            elif command[0] == "mixer":
                state["mixer volume"] = int(command[2])
            elif command[0] == "playlist":
                state["playlist " + command[1]] = int(command[2])
            if command[0] == "players":
                return success(request, {"count": 1, "players_loop": [dict(state, playerid="02:00:00:00:00:01", connected=1)]})
            return success(request, {key: value for key, value in state.items() if key not in DRIVER.PLAYER_PREFS} if command[0] == "status" else {})
        with rpc_server(respond) as url:
            settings = DRIVER.configure_player(DRIVER.LmsClient(url), "02:00:00:00:00:01")
        self.assertEqual(settings["digitalVolumeControl"], 0)
        self.assertEqual(settings["replayGainMode"], 0)
        self.assertEqual(settings["transitionType"], 0)
        self.assertEqual(settings["transitionDuration"], 0)
        self.assertEqual(settings["mixer volume"], 100)
        self.assertEqual(settings["playlist shuffle"], 0)
        self.assertEqual(settings["playlist repeat"], 0)
        self.assertEqual(players, {"02:00:00:00:00:01"})

    def test_preferences_fail_if_server_does_not_apply_them(self):
        def respond(request):
            command = request["params"][1]
            result = {"count": 1, "players_loop": [{"playerid": "02:00:00:00:00:01", "connected": 1}]} if command[0] == "players" else {"mixer volume": 5}
            return success(request, result)
        with rpc_server(respond) as url:
            with self.assertRaisesRegex(DRIVER.AudioError, "setting"):
                DRIVER.configure_player(DRIVER.LmsClient(url), "02:00:00:00:00:01")

    def test_registration_waits_for_exact_fixture_in_server_player_list(self):
        calls = []
        replies = [[], [{"playerid": "02:00:00:00:00:99", "connected": 1}], [{"playerid": "02:00:00:00:00:01", "connected": 1}]]
        def respond(request):
            player, command = request["params"]
            calls.append((player, command))
            if player or command[0] != "players":
                return {"id": request["id"], "error": {"code": -1}}
            rows = replies[min(len(calls) - 1, 2)]
            return success(request, {"count": len(rows), "players_loop": rows})
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            with rpc_server(respond) as url:
                DRIVER.wait_connected(DRIVER.LmsClient(url), "02:00:00:00:00:01", process, timeout=1, interval=.01)
        finally:
            DRIVER.stop_process(process)
        self.assertEqual(len(calls), 3)

    def test_playlist_wait_requires_both_fixture_urls_in_order(self):
        expected = ["http://127.0.0.1:1/a.wav", "http://127.0.0.1:1/b.wav"]
        reply = {"playlist_tracks": 2, "playlist_loop": [{"url": expected[1]}, {"url": expected[0]}]}
        with rpc_server(lambda r: success(r, reply)) as url:
            with self.assertRaisesRegex(DRIVER.AudioError, "playlist"):
                DRIVER.wait_playlist(DRIVER.LmsClient(url), "02:00:00:00:00:01", expected, timeout=.05, interval=.01)

    def test_local_fixture_playlist_has_two_readable_tracks_and_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            rootfs = directory / "rootfs"
            (rootfs / "tmp").mkdir(parents=True)
            unrelated = rootfs / "tmp" / "unrelated"
            unrelated.write_text("keep")
            (directory / "a.wav").write_bytes(b"first")
            (directory / "b.wav").write_bytes(b"second")
            with DRIVER.LocalFixtures(rootfs, [directory / "a.wav", directory / "b.wav"]) as fixtures:
                self.assertEqual(fixtures.playlist.read_text().splitlines()[1:], fixtures.urls)
                self.assertTrue(all(url.startswith("file:///tmp/sweetspot-audio-") for url in fixtures.urls))
                self.assertEqual((fixtures.directory / "b.wav").read_bytes(), b"second")
                self.assertEqual(fixtures.directory.stat().st_mode & 0o777, 0o755)
                self.assertEqual(fixtures.playlist.stat().st_mode & 0o777, 0o644)
            self.assertFalse(fixtures.directory.exists())
            self.assertEqual(unrelated.read_text(), "keep")

    def test_unpaced_stdout_is_paced_and_byte_limited(self):
        with tempfile.TemporaryDirectory() as temp:
            process = subprocess.Popen([sys.executable, "-u", "-c", "import os; data=b'abcdefgh'*1024\nwhile True: os.write(1,data)"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            capture = DRIVER.PacedCapture(process.stdout, Path(temp) / "capture.raw", rate=1000, max_bytes=800, wall_seconds=2)
            started = time.monotonic()
            try:
                capture.start()
                self.assertTrue(capture.finished.wait(2))
            finally:
                capture.stop()
                DRIVER.stop_process(process)
                capture.join()
            self.assertGreaterEqual(time.monotonic() - started, .075)
            self.assertEqual(capture.path.read_bytes(), b"abcdefgh" * 100)
            self.assertEqual(capture.reason, "byte_limit")
            self.assertFalse(capture.thread.is_alive())
            self.assertIsNone(capture.error)

    def test_blocked_stdout_has_wall_limit_and_owned_process_is_stopped(self):
        with tempfile.TemporaryDirectory() as temp:
            unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], stdout=subprocess.PIPE)
            capture = DRIVER.PacedCapture(process.stdout, Path(temp) / "partial.raw", rate=1000, max_bytes=8000, wall_seconds=.08)
            try:
                capture.start()
                self.assertFalse(capture.finished.wait(.12))
                capture.stop()
                DRIVER.stop_process(process)
                capture.join()
                self.assertIsNotNone(process.poll())
                self.assertIsNone(unrelated.poll())
                self.assertFalse(capture.thread.is_alive())
                self.assertTrue(capture.path.exists())
            finally:
                DRIVER.stop_process(unrelated)
                DRIVER.stop_process(process)

    def test_capture_short_eof_preserves_partial_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            process = subprocess.Popen([sys.executable, "-c", "import os; os.write(1,b'abcdefgh')"], stdout=subprocess.PIPE)
            capture = DRIVER.PacedCapture(process.stdout, Path(temp) / "partial.raw", rate=1000, max_bytes=800, wall_seconds=1)
            try:
                capture.start()
                self.assertTrue(capture.finished.wait(1))
            finally:
                DRIVER.stop_process(process)
                capture.join()
            self.assertEqual(capture.reason, "eof")
            self.assertEqual(capture.path.read_bytes(), b"abcdefgh")

    @unittest.skipUnless(os.name == "posix", "private process groups require POSIX")
    def test_owned_descendant_is_stopped_even_if_group_leader_already_exited(self):
        process = subprocess.Popen([sys.executable, "-u", "-c", "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print(p.pid)"], stdout=subprocess.PIPE, start_new_session=True)
        descendant = int(process.stdout.readline())
        process.wait()
        process.stdout.close()
        try:
            DRIVER.stop_process(process, owned_group=True)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                stat = Path("/proc/%s/stat" % descendant)
                if not stat.exists() or stat.read_text().rsplit(")", 1)[1].strip().startswith("Z"):
                    break
                time.sleep(.01)
            else:
                self.fail("owned descendant remains running after cleanup")
        finally:
            try:
                os.kill(descendant, 9)
            except ProcessLookupError:
                pass

    def test_bad_capture_limits_are_rejected(self):
        for rate, max_bytes, wall in ((0, 8, 1), (1000, 7, 1), (1000, 8, 0)):
            with self.subTest(rate=rate, max_bytes=max_bytes, wall=wall), self.assertRaises(ValueError):
                DRIVER.PacedCapture(None, Path("unused.raw"), rate=rate, max_bytes=max_bytes, wall_seconds=wall)

    def test_case_failure_cleans_child_and_keeps_report_and_stderr(self):
        with tempfile.TemporaryDirectory() as temp:
            rootfs = Path(temp) / "rootfs"
            (rootfs / "tmp").mkdir(parents=True)
            output = Path(temp) / "out"
            children = []
            def launch(_command, **kwargs):
                process = subprocess.Popen([sys.executable, "-u", "-c", "import os,time; os.write(2,b'fixture stderr\\n'); os.write(1,b'abcdefgh'*100); time.sleep(60)"], **kwargs)
                children.append(process)
                return process
            with rpc_server(lambda r: {"id": r["id"], "error": {"code": -1}}) as url:
                result = DRIVER.run_case(rootfs, DRIVER.LmsClient(url), output, 44100, 16, process_factory=launch)
            self.assertEqual(result["status"], "fail")
            self.assertIsNotNone(children[0].poll())
            self.assertTrue((output / "44100-16" / "capture.raw").exists())
            self.assertTrue((output / "44100-16" / "report.json").exists())
            self.assertTrue((output / "44100-16" / "squeezelite-stderr.log").exists())

    def orchestration_result(self, directory, *, altered=False, rate=44100, bits=16, second_bits=None, dop=False, source_format=None, decoder_log_defect=None, case_id=None):
        """Run orchestration with independent container unpacking and a real pipe writer."""
        rootfs = directory / "rootfs"
        (rootfs / "tmp").mkdir(parents=True)
        output = directory / "out"
        state = {}
        children = []
        fixture_mac = [None]
        case_directory = output / (case_id or "%s-%s" % (rate, bits))
        commands = []
        source_widths = []
        source_hashes = []
        source_frames = []
        playlist_urls = []

        def respond(request):
            _, command = request["params"]
            if command[0] == "players":
                return success(request, {"count": 1, "players_loop": [dict(state, playerid=fixture_mac[0], connected=1)]})
            if command[0] == "playerpref":
                state[command[1]] = command[2]
            elif command[0] == "mixer":
                state["mixer volume"] = command[2]
            elif command[:2] in (["playlist", "shuffle"], ["playlist", "repeat"]):
                state["playlist " + command[1]] = command[2]
            elif command[:2] == ["playlist", "play"]:
                playlist = rootfs / command[2].lstrip("/")
                state["playlist_loop"] = [{"url": url} for url in playlist.read_text().splitlines()[1:]]
                state["playlist_tracks"] = 2
            return success(request, dict(state) if command[0] == "status" else {})

        def launch(_command, **kwargs):
            commands.append(_command)
            fixture_mac[0] = _command[_command.index("-m") + 1]
            if source_format and decoder_log_defect != "missing":
                header = "DSF version: 1 format: 0\nlsb first: 1\nblock size: 4096\n" if source_format == "dsf" else "DSDIFF version: 1.5.0.0\n"
                decoder_log = ("codec open: 'd'\n" + header + "channels: 2\nsample rate: %s\n" % (rate * 16) +
                               "DSD%s stream, format: DOP, rate: %sHz\n" % (64 if rate == 176400 else 128, rate)) * 2
                if decoder_log_defect == "missing_headers":
                    decoder_log = decoder_log.replace(header, "using dsd to decode dsf,dff\n")
                elif decoder_log_defect == "wrong_carrier":
                    decoder_log = decoder_log.replace("rate: %sHz" % rate, "rate: 44100Hz")
                elif decoder_log_defect == "fallback":
                    decoder_log += "DSD sample rate too high for device - converting to PCM\nDSD to PCM output\n"
                (rootfs / "tmp" / "audio-verification.log").write_text(decoder_log)
            payload = bytearray()
            marker_index = 0
            fixture_directory = next((rootfs / "tmp").glob("sweetspot-audio-*"))
            references = [rootfs / url.removeprefix("file://").lstrip("/")
                          for url in (fixture_directory / "pair.m3u").read_text().splitlines()[1:]]
            playlist_urls.extend((fixture_directory / "pair.m3u").read_text().splitlines()[1:])
            for reference in references:
                source_hashes.append(hashlib.sha256(reference.read_bytes()).hexdigest())
                if source_format:
                    self.assertEqual(reference.suffix, "." + source_format)
                    info = dsd_source(reference, reverse_dsf_bits=altered != "bit_order")
                    source_widths.append(info["bits"])
                    source_frames.append(info["frames"])
                    left, right = info["samples"]
                    for index in range(info["frames"]):
                        marker = (0xFA, 0x05)[marker_index % 2]
                        channels = (right, left) if altered == "channels" else (left, right)
                        for samples in channels:
                            first, second = samples[index * 2:index * 2 + 2]
                            if altered == "byte_order":
                                first, second = second, first
                            if altered == "bit_order" and source_format == "dff":
                                first = int(f"{first:08b}"[::-1], 2)
                                second = int(f"{second:08b}"[::-1], 2)
                            payload.extend(bytes((0, second, first, marker)))
                        marker_index += 1
                    continue
                with wave.open(str(reference), "rb") as source:
                    width = source.getsampwidth()
                    source_widths.append(width * 8)
                    samples = source.readframes(source.getnframes())
                for position in range(0, len(samples), width * 2):
                    for channel in (0, 1):
                        sample_bytes = samples[position + channel * width:position + (channel + 1) * width]
                        if dop:
                            # Squeezelite regenerates a continuous marker phase.
                            marker = (0xFA, 0x05)[marker_index % 2]
                            payload.extend(bytes((0, sample_bytes[0], sample_bytes[1], marker)))
                        else:
                            sample = int.from_bytes(sample_bytes, "little", signed=True)
                            payload.extend(struct.pack("<i", sample << (32 - 8 * width)))
                    marker_index += 1
            if altered:
                if altered == "marker":
                    payload[5 * 8 + 3] = 0x06
                elif altered == "boundary_lost":
                    del payload[rate * 8:rate * 8 + 8]
                elif altered == "boundary_duplicated":
                    payload[rate * 8:rate * 8] = payload[rate * 8 - 8:rate * 8]
                elif source_format and altered in ("byte_order", "bit_order", "channels"):
                    pass
                elif dop or source_format:
                    payload[5 * 8 + 1] ^= 1
                else:
                    # Corrupt a significant low PCM24 bit in either direction.
                    offset = 5 if bits == 24 else rate + 5
                    payload[offset * 8 + 1] ^= 1
            raw = directory / "writer.raw"
            raw.write_bytes(payload)
            idle = bytes(8)
            if dop or source_format:
                idle = b"".join(bytes((0, 0x69, 0x69, marker)) * 2
                                for marker in ((0xFA, 0x05)[marker_index % 2],
                                               (0xFA, 0x05)[(marker_index + 1) % 2]))
            code = "import os,sys; data=open(sys.argv[1],'rb').read(); os.write(1,data); idle=bytes.fromhex(sys.argv[2])*1024\nwhile True: os.write(1,idle)"
            process = subprocess.Popen([sys.executable, "-u", "-c", code, str(raw), idle.hex()], **kwargs)
            children.append(process)
            return process

        with rpc_server(respond) as url, patch.object(DRIVER, "CAPTURE_SECONDS", 3), patch.object(DRIVER, "STARTUP_SECONDS", 1), patch.object(DRIVER, "WALL_SECONDS", 4):
            kwargs = {"process_factory": launch}
            if second_bits is not None:
                kwargs["second_bits"] = second_bits
            if dop:
                kwargs["dop"] = True
            if source_format:
                kwargs["source_format"] = source_format
            if case_id is not None:
                kwargs["case_id"] = case_id
            result = DRIVER.run_case(rootfs, DRIVER.LmsClient(url), output, rate, bits, **kwargs)
        self.assertTrue(children, result.get("error"))
        self.assertIsNotNone(children[0].poll())
        self.assertEqual(list((rootfs / "tmp").glob("sweetspot-audio-*")), [])
        self.assertEqual(json.loads((case_directory / "report.json").read_text())["status"], result["status"])
        result["test_source_bits"] = source_widths
        result["test_command"] = commands[0]
        result["test_source_hashes"] = source_hashes
        result["test_source_frames"] = source_frames
        result["test_playlist_urls"] = playlist_urls
        decoder_log = case_directory / "squeezelite.log"
        result["test_decoder_hash"] = hashlib.sha256(decoder_log.read_bytes()).hexdigest() if decoder_log.exists() else None
        return result

    def test_complete_orchestration_compares_every_pcm_frame(self):
        with tempfile.TemporaryDirectory() as temp:
            result = self.orchestration_result(Path(temp), altered=False)
        self.assertEqual(result["status"], "pass", result.get("error"))
        self.assertTrue(result["comparison"]["sample_match"])
        self.assertTrue(result["comparison"]["sequence_match"])
        self.assertEqual(result["comparison"]["expected_frames"], 88200)

    def test_orchestration_fails_when_one_captured_sample_differs(self):
        with tempfile.TemporaryDirectory() as temp:
            result = self.orchestration_result(Path(temp), altered=True)
        self.assertEqual(result["status"], "fail")
        self.assertFalse(result["comparison"]["sample_match"])
        self.assertIsNotNone(result["comparison"]["first_mismatch"])

    def test_case_cleanup_failure_revokes_successful_audio_comparison(self):
        original_cleanup = DRIVER.LocalFixtures.__exit__

        def failed_cleanup(fixtures, *exception):
            original_cleanup(fixtures, *exception)
            raise OSError("fixture cleanup failed")

        with tempfile.TemporaryDirectory() as temp, patch.object(DRIVER.LocalFixtures, "__exit__", failed_cleanup):
            result = self.orchestration_result(Path(temp), altered=False)
        self.assertEqual(result["comparison"]["status"], "pass")
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["error"], "fixture cleanup failed")

    def test_mixed_depth_orchestration_preserves_both_wav_depths_and_every_frame(self):
        for first, second in ((16, 24), (24, 16)):
            with self.subTest(first=first), tempfile.TemporaryDirectory() as temp:
                result = self.orchestration_result(Path(temp), bits=first, second_bits=second,
                                                    case_id="mixed-%s-%s" % (first, second))
                self.assertEqual(result["status"], "pass", result.get("error"))
                self.assertEqual(result["source_bits"], [first, second])
                self.assertEqual(result["test_source_bits"], [first, second])
                self.assertEqual(result["comparison"]["expected_frames"], 88200)
                self.assertTrue(result["comparison"]["sample_match"])

    def test_mixed_depth_orchestration_rejects_one_low_pcm24_bit_in_either_track(self):
        for first, second in ((16, 24), (24, 16)):
            with self.subTest(first=first), tempfile.TemporaryDirectory() as temp:
                result = self.orchestration_result(Path(temp), altered=True, bits=first, second_bits=second,
                                                    case_id="mixed-%s-%s" % (first, second))
                self.assertEqual(result["status"], "fail")
                self.assertFalse(result["comparison"]["sample_match"])
                self.assertIsNotNone(result["comparison"]["first_mismatch"])

    def test_dop_orchestration_checks_payload_and_regenerated_markers(self):
        with tempfile.TemporaryDirectory() as temp:
            result = self.orchestration_result(Path(temp), rate=176400, bits=24, dop=True, case_id="dop-positive")
        self.assertEqual(result["status"], "pass", result.get("error"))
        self.assertEqual(result["kind"], "dop_pcm_passthrough")
        self.assertEqual(result["source_bits"], [24, 24])
        self.assertTrue(result["comparison"]["payload_match"])
        self.assertTrue(result["comparison"]["markers_match"])
        self.assertTrue(result["comparison"]["sequence_match"])
        command = result["test_command"]
        self.assertEqual(command[command.index("-D") + 1], "0:dop")
        self.assertEqual(command[command.index("-a") + 1], "32")
        self.assertNotIn("-R", command)
        self.assertNotIn("dop24", command)

    def test_dop_orchestration_rejects_payload_and_illegal_marker(self):
        for defect, field in (("payload", "payload_match"), ("marker", "markers_match")):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temp:
                result = self.orchestration_result(Path(temp), rate=176400, bits=24, dop=True, altered=defect,
                                                    case_id="dop-" + defect)
                self.assertEqual(result["status"], "fail")
                self.assertFalse(result["comparison"][field])

    def test_dsd_orchestration_decodes_both_containers_and_rates_from_sources_only(self):
        for container in ("dsf", "dff"):
            for rate in (176400, 352800):
                with self.subTest(container=container, rate=rate), tempfile.TemporaryDirectory() as temp:
                    result = self.orchestration_result(Path(temp), rate=rate, bits=1,
                                                       source_format=container,
                                                       case_id="%s-%s-dop" % (container, rate * 16))
                    self.assertEqual(result["status"], "pass", result.get("error"))
                    self.assertEqual(result["kind"], "dsd_to_dop")
                    self.assertEqual(result["scope"], "software_stdout")
                    self.assertEqual(result["source_format"], container)
                    self.assertEqual(result["source_bits"], [1, 1])
                    self.assertEqual(result["carrier_bits"], 24)
                    self.assertEqual(result["dsd_rate"], rate * 16)
                    self.assertEqual(result["test_source_bits"], [1, 1])
                    self.assertEqual(result["test_source_frames"], [rate, rate])
                    self.assertEqual(result["comparison"]["expected_frames"], rate * 2)
                    self.assertTrue(result["comparison"]["payload_match"])
                    self.assertTrue(result["comparison"]["markers_match"])
                    self.assertTrue(result["comparison"]["sequence_match"])
                    self.assertTrue(all(url.endswith("." + container) for url in result["test_playlist_urls"]))
                    self.assertTrue(all(Path(source["path"]).suffix == "." + container for source in result["sources"]))
                    self.assertEqual([source["sha256"] for source in result["sources"]], result["test_source_hashes"])
                    self.assertTrue(all((source["format"], source["rate"], source["channels"], source["bits"]) ==
                                        (container, rate * 16, 2, 1) for source in result["sources"]))
                    self.assertTrue(all(Path(source["path"]).suffix == ".wav" and len(source["sha256"]) == 64
                                        for source in result["comparison"]["references"]))
                    self.assertEqual(result["decoder"]["status"], "pass")
                    self.assertEqual(result["decoder"]["source_headers"], 2)
                    self.assertEqual(result["decoder"]["dop_outputs"], 2)
                    self.assertEqual(len(result["decoder"]["sha256"]), 64)
                    self.assertEqual(result["decoder"]["sha256"], result["test_decoder_hash"])
                    command = result["test_command"]
                    self.assertEqual(command[command.index("-D") + 1], "0:dop")
                    self.assertEqual(command[command.index("-a") + 1], "32")
                    self.assertEqual(command[command.index("-r") + 1], str(rate))
                    self.assertNotIn("-R", command)
                    self.assertIn("decode=info", command)
                    self.assertIn("stream=info", command)

    def test_dsd_orchestration_rejects_payload_order_channels_markers_and_boundary_damage(self):
        matrix = (("dsf", 176400, "byte_order", "payload_match"),
                  ("dsf", 352800, "bit_order", "payload_match"),
                  ("dff", 176400, "channels", "payload_match"),
                  ("dff", 352800, "payload", "payload_match"),
                  ("dsf", 176400, "boundary_lost", "sequence_match"),
                  ("dff", 352800, "boundary_duplicated", "sequence_match"),
                  ("dff", 176400, "marker", "markers_match"))
        for container, rate, defect, field in matrix:
            with self.subTest(container=container, rate=rate, defect=defect), tempfile.TemporaryDirectory() as temp:
                result = self.orchestration_result(Path(temp), rate=rate, bits=1,
                                                   source_format=container, altered=defect,
                                                   case_id="%s-%s-dop" % (container, rate * 16))
                self.assertEqual(result["status"], "fail")
                self.assertFalse(result["comparison"][field])

    def test_dsd_orchestration_rejects_missing_decoder_headers_wrong_carrier_and_pcm_fallback(self):
        matrix = (("dsf", 176400, "missing"), ("dff", 352800, "missing_headers"),
                  ("dsf", 352800, "wrong_carrier"), ("dff", 176400, "fallback"))
        for container, rate, defect in matrix:
            with self.subTest(container=container, rate=rate, defect=defect), tempfile.TemporaryDirectory() as temp:
                result = self.orchestration_result(Path(temp), rate=rate, bits=1,
                                                   source_format=container, decoder_log_defect=defect,
                                                   case_id="%s-%s-dop" % (container, rate * 16))
                self.assertEqual(result["comparison"]["status"], "pass")
                self.assertEqual(result["status"], "fail")
                self.assertEqual(result["decoder"]["status"], "fail")
                self.assertIn("decoder evidence", result["error"])

    def test_decoder_evidence_requires_each_source_property_for_both_tracks(self):
        track = ("codec open: 'd'\nDSF version: 1 format: 0\nchannels: 2\n"
                 "sample rate: 2822400\nlsb first: 1\nblock size: 4096\n"
                 "DSD64 stream, format: DOP, rate: 176400Hz\n")
        required = (("codec open: 'd'", "dsd_codec_opens"),
                    ("DSF version: 1 format: 0", "source_headers"),
                    ("channels: 2", "stereo_headers"),
                    ("sample rate: 2822400", "source_rates"),
                    ("lsb first: 1", "lsb_first"),
                    ("block size: 4096", "block_sizes"),
                    ("DSD64 stream, format: DOP, rate: 176400Hz", "dop_outputs"))
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "squeezelite.log"
            path.write_text(track * 2)
            self.assertEqual(DRIVER.dsd_decoder_evidence(path, path, "dsf", 176400)["status"], "pass")
            for line, field in required:
                with self.subTest(property=field):
                    # One matching track is insufficient even when audio passes.
                    path.write_text(track + track.replace(line, "unverified source property"))
                    result = DRIVER.dsd_decoder_evidence(path, path, "dsf", 176400)
                    self.assertEqual(result[field], 1)
                    self.assertEqual(result["status"], "fail")

    def aggregate_report(self, directory, *, defect=None):
        """Keep main's aggregation real, replacing only the external player run."""
        rootfs = directory / "rootfs"
        (rootfs / "usr/bin").mkdir(parents=True)
        (rootfs / "usr/bin/squeezelite").write_bytes(b"offline engine boundary")
        output = directory / "out"
        count = [0]
        first_id = [None]

        def complete_case(_rootfs, _client, destination, rate, bits, **kwargs):
            count[0] += 1
            case_id = kwargs.get("case_id", "legacy-%s-%s" % (rate, bits))
            first_id[0] = first_id[0] or case_id
            second = kwargs.get("second_bits") or bits
            container = kwargs.get("source_format")
            result = {"id": case_id, "rate": rate, "source_bits": [bits, second],
                      "bits": bits, "kind": "dsd_to_dop" if container else "dop_pcm_passthrough" if kwargs.get("dop") else "pcm",
                      "status": "pass"}
            (destination / case_id).mkdir()
            if kwargs.get("dop") or container:
                result["dsd_rate"] = rate * 16
            if container:
                result["source_format"] = container
                result["carrier_bits"] = 24
            if count[0] == 2:
                if defect == "duplicate":
                    result["id"] = first_id[0]
                elif defect == "unexpected":
                    result["id"] = "not-a-required-case"
                elif defect == "missing_id":
                    del result["id"]
                elif defect == "incomplete":
                    raise DRIVER.AudioError("engine did not complete")
                elif defect == "failed":
                    result["status"] = "fail"
                elif defect == "case_error":
                    result["error"] = "fixture cleanup failed"
            return result

        with patch.object(DRIVER, "run_case", side_effect=complete_case), patch("builtins.print"):
            rc = DRIVER.main(["--rootfs", str(rootfs), "--server", "http://127.0.0.1:9000",
                              "--output", str(output), "--version", "offline-version"])
        return rc, json.loads((output / "report.json").read_text()), [entry.name for entry in output.iterdir() if entry.is_dir()]

    def test_main_preserves_fourteen_cases_and_runs_four_dsd_source_cases(self):
        with tempfile.TemporaryDirectory() as temp:
            rc, report, entries = self.aggregate_report(Path(temp))
        self.assertEqual(rc, 0)
        self.assertEqual(report["status"], "pass")
        self.assertEqual(len(report["cases"]), 18)
        self.assertEqual(len({case["id"] for case in report["cases"]}), 18)
        self.assertEqual([case["id"] for case in report["cases"][:14]],
                         ["pcm-%s-%s-%s" % (rate, first, second)
                          for first, second in ((16, 16), (24, 24), (16, 24), (24, 16))
                          for rate in (44100, 48000, 96000)] +
                         ["dop-176400-24-24", "dop-352800-24-24"])
        self.assertEqual({(case["rate"], tuple(case["source_bits"])) for case in report["cases"]
                          if case["kind"] == "pcm"},
                         {(44100, (16, 16)), (44100, (24, 24)), (48000, (16, 16)), (48000, (24, 24)),
                          (96000, (16, 16)), (96000, (24, 24)), (44100, (16, 24)), (44100, (24, 16)),
                          (48000, (16, 24)), (48000, (24, 16)), (96000, (16, 24)), (96000, (24, 16))})
        self.assertEqual({(case["rate"], case["dsd_rate"], tuple(case["source_bits"]))
                          for case in report["cases"] if case["kind"] == "dop_pcm_passthrough"},
                         {(176400, 2822400, (24, 24)), (352800, 5644800, (24, 24))})
        self.assertEqual(set(entries), {case["id"] for case in report["cases"]})
        self.assertEqual({(case["id"], case["source_format"], case["rate"], case["dsd_rate"],
                           tuple(case["source_bits"]), case["carrier_bits"])
                          for case in report["cases"] if case["kind"] == "dsd_to_dop"},
                         {("dsf-2822400-dop", "dsf", 176400, 2822400, (1, 1), 24),
                          ("dsf-5644800-dop", "dsf", 352800, 5644800, (1, 1), 24),
                          ("dff-2822400-dop", "dff", 176400, 2822400, (1, 1), 24),
                          ("dff-5644800-dop", "dff", 352800, 5644800, (1, 1), 24)})

    def test_aggregate_fails_closed_for_missing_duplicate_unexpected_or_incomplete_case(self):
        for defect in ("duplicate", "unexpected", "missing_id", "incomplete", "failed", "case_error"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temp:
                rc, report, _ = self.aggregate_report(Path(temp), defect=defect)
                self.assertNotEqual(rc, 0)
                self.assertEqual(report["status"], "fail")

    def test_missing_rootfs_is_nonzero_and_persists_eighteen_missing_cases(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "out"
            rc = DRIVER.main(["--rootfs", str(Path(temp) / "absent"), "--server", "http://127.0.0.1:9000", "--output", str(output), "--version", "fixture-version"])
            report = json.loads((output / "report.json").read_text())
            self.assertNotEqual(rc, 0)
            self.assertEqual(report["scope"], "software_stdout")
            self.assertEqual(report["version"], "fixture-version")
            self.assertEqual(len(report["cases"]), 18)
            self.assertEqual(len({case["id"] for case in report["cases"]}), 18)
            self.assertTrue(all(case["status"] == "fail" for case in report["cases"]))


if __name__ == "__main__":
    unittest.main()
