#!/usr/bin/env python3
"""Offline driver tests; these do not certify Lyrion or a physical DAC."""
import importlib.util
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
                with self.assertRaisesRegex(DRIVER.AudioError, "connect"):
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

    def orchestration_result(self, directory, *, altered):
        """Run orchestration against a protocol stand-in and real PCM writer."""
        rootfs = directory / "rootfs"
        (rootfs / "tmp").mkdir(parents=True)
        output = directory / "out"
        state = {}
        children = []
        fixture_mac = [None]

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
            fixture_mac[0] = _command[_command.index("-m") + 1]
            payload = bytearray()
            for reference in sorted((output / "44100-16" / "references").glob("*.wav")):
                with wave.open(str(reference), "rb") as source:
                    samples = source.readframes(source.getnframes())
                for (sample,) in struct.iter_unpack("<h", samples):
                    payload.extend(struct.pack("<i", sample << 16))
            if altered:
                payload[5 * 8] ^= 1
            raw = directory / "writer.raw"
            raw.write_bytes(payload)
            code = "import os,sys; data=open(sys.argv[1],'rb').read(); os.write(1,data)\nwhile True: os.write(1,b'\\0'*8192)"
            process = subprocess.Popen([sys.executable, "-u", "-c", code, str(raw)], **kwargs)
            children.append(process)
            return process

        with rpc_server(respond) as url, patch.object(DRIVER, "CAPTURE_SECONDS", 3), patch.object(DRIVER, "STARTUP_SECONDS", 1), patch.object(DRIVER, "WALL_SECONDS", 4):
            result = DRIVER.run_case(rootfs, DRIVER.LmsClient(url), output, 44100, 16, process_factory=launch)
        self.assertIsNotNone(children[0].poll())
        self.assertEqual(list((rootfs / "tmp").glob("sweetspot-audio-*")), [])
        self.assertEqual(json.loads((output / "44100-16" / "report.json").read_text())["status"], result["status"])
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

    def test_missing_rootfs_is_nonzero_and_persists_six_missing_cases(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "out"
            rc = DRIVER.main(["--rootfs", str(Path(temp) / "absent"), "--server", "http://127.0.0.1:9000", "--output", str(output), "--version", "fixture-version"])
            report = json.loads((output / "report.json").read_text())
            self.assertNotEqual(rc, 0)
            self.assertEqual(report["scope"], "software_stdout")
            self.assertEqual(report["version"], "fixture-version")
            self.assertEqual(len(report["cases"]), 6)
            self.assertTrue(all(case["status"] == "fail" for case in report["cases"]))


if __name__ == "__main__":
    unittest.main()
