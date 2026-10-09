#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify an isolated rootfs Lyrion/Squeezelite software stdout PCM path.

This deliberately cannot certify ALSA, a DAC, its clock, or analog output.
Lyrion must already be running in the isolated rootfs, on loopback.
"""
import argparse
import hashlib
import json
import math
import os
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
CASES = [(rate, bits) for rate in (44100, 48000, 96000) for bits in (16, 24)]
STARTUP_SECONDS = 10
CAPTURE_SECONDS = STARTUP_SECONDS + 2 + 1
WALL_SECONDS = CAPTURE_SECONDS + 3
PLAYER_PREFS = {
    "digitalVolumeControl": 0,
    "replayGainMode": 0,
    "transitionType": 0,
    "transitionDuration": 0,
    "maxBitrate": 0,
}


class AudioError(RuntimeError):
    pass


class RpcError(AudioError):
    pass


@contextmanager
def rpc_wall_timeout(seconds):
    """Bound DNS/open/headers/body together, including continuously sent bytes.

    The chroot harness is Linux and calls RPC from its main thread. Restoring
    an existing timer accounts for elapsed wall time, rather than postponing it.
    """
    if os.name != "posix" or threading.current_thread() is not threading.main_thread():
        raise RpcError("total RPC deadlines require the Linux main thread")
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()

    def expired(*_):
        raise RpcError("RPC total wall time deadline expired")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_timer[0] > 0:
            remaining = max(.000001, previous_timer[0] - (time.monotonic() - started))
            signal.setitimer(signal.ITIMER_REAL, remaining, previous_timer[1])


def write_json(path, report):
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class LmsClient:
    """Strict, bounded JSON-RPC requests to the isolated loopback server."""
    def __init__(self, server, timeout=2):
        parsed = urllib.parse.urlsplit(server)
        if (parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost")
                or parsed.username is not None or parsed.password is not None
                or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
            raise ValueError("server must be an isolated HTTP loopback origin")
        if timeout <= 0 or not math.isfinite(timeout):
            raise ValueError("RPC timeout must be positive and finite")
        self.url = server.rstrip("/") + "/jsonrpc.js"
        self.timeout = timeout
        self._id = 0
        self.journal = []
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, player, command, *, deadline=None):
        entry = {"player": player, "command": command}
        self.journal.append(entry)
        try:
            timeout = self.timeout if deadline is None else min(self.timeout, deadline - time.monotonic())
            if timeout <= 0:
                raise RpcError("RPC deadline expired")
            with rpc_wall_timeout(timeout):
                result = self._request(player, command, deadline=deadline)
            entry["result"] = result
            return result
        except RpcError as error:
            entry["error"] = str(error)
            raise RpcError("player %s command %s: %s" % (player, command, error)) from error

    def _request(self, player, command, *, deadline=None):
        timeout = self.timeout
        if deadline is not None:
            timeout = min(timeout, deadline - time.monotonic())
            if timeout <= 0:
                raise RpcError("RPC deadline expired")
        self._id += 1
        payload = {"id": self._id, "method": "slim.request", "params": [player, command]}
        request = urllib.request.Request(self.url, data=json.dumps(payload).encode(),
                                         headers={"Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=timeout) as response:
                body = response.read(1024 * 1024 + 1)
            if len(body) > 1024 * 1024:
                raise RpcError("RPC response exceeded size limit")
            reply = json.loads(body)
        except (OSError, ValueError, urllib.error.URLError) as error:
            raise RpcError("RPC request failed: %s" % error) from error
        if not isinstance(reply, dict) or reply.get("id") != self._id:
            raise RpcError("malformed RPC envelope or mismatched request id")
        if reply.get("error") is not None:
            raise RpcError("RPC error: %s" % reply["error"])
        result = reply.get("result")
        if not isinstance(result, dict):
            raise RpcError("malformed RPC result")
        if result.get("error") is not None or result.get("_error") is not None:
            raise RpcError("RPC error result: %s" % result)
        return result


def listed_player(client, mac, *, deadline, preferences=False):
    command = ["players", 0, 100]
    if preferences:
        command.append("playerprefs:" + ",".join(PLAYER_PREFS))
    reply = client.request("", command, deadline=deadline)
    rows = reply.get("players_loop", [])
    if not isinstance(rows, list) or "count" not in reply:
        raise RpcError("malformed server player list")
    if any(not isinstance(row, dict) or not isinstance(row.get("playerid"), str) for row in rows):
        raise RpcError("malformed server player entry")
    return next((row for row in rows if row["playerid"].lower() == mac.lower()), None)


def wait_connected(client, mac, process, timeout=8, interval=.1):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AudioError("Squeezelite exited with status %s before connection" % process.returncode)
        # LMS closes an RPC connection addressed to an unknown client. Discover
        # the fixture via the server command before sending player commands.
        player = listed_player(client, mac, deadline=deadline)
        state = player.get("connected") if player is not None else 0
        if str(state) == "1":
            return
        if str(state) != "0":
            raise RpcError("malformed connected state: %r" % state)
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
    raise AudioError("player did not connect before registration deadline")


def configure_player(client, mac, *, deadline=None):
    deadline = deadline or time.monotonic() + 8
    for name, value in PLAYER_PREFS.items():
        client.request(mac, ["playerpref", name, value], deadline=deadline)
    client.request(mac, ["mixer", "volume", 100], deadline=deadline)
    client.request(mac, ["playlist", "shuffle", 0], deadline=deadline)
    client.request(mac, ["playlist", "repeat", 0], deadline=deadline)
    player = listed_player(client, mac, deadline=deadline, preferences=True)
    if player is None:
        raise AudioError("player setting readback failed: fixture disappeared")
    reply = {name: player.get(name) for name in PLAYER_PREFS}
    status = client.request(mac, ["status", "-", 1], deadline=deadline)
    reply.update({name: status.get(name) for name in ("mixer volume", "playlist shuffle", "playlist repeat")})
    expected = dict(PLAYER_PREFS, **{"mixer volume": 100, "playlist shuffle": 0, "playlist repeat": 0})
    for name, value in expected.items():
        if str(reply.get(name)) != str(value):
            raise AudioError("player setting %s was not applied (wanted %s, received %r)" % (name, value, reply.get(name)))
    return {name: reply[name] for name in expected}


def wait_playlist(client, mac, urls, timeout=3, interval=.1):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        reply = client.request(mac, ["status", 0, 2, "tags:u"], deadline=deadline)
        tracks = reply.get("playlist_loop", [])
        if str(reply.get("playlist_tracks")) == "2" and isinstance(tracks, list):
            actual = [track.get("url") if isinstance(track, dict) else None for track in tracks]
            if actual == urls:
                return reply
            if len(actual) == 2:
                raise AudioError("loaded playlist differs from the two fixtures: %r" % actual)
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
    raise AudioError("two-track playlist was not loaded before deadline")


class LocalFixtures:
    """Copy references into a unique, LMS-readable directory inside the rootfs."""
    def __init__(self, rootfs, references):
        self.rootfs = rootfs
        self.references = references
        self.directory = None

    def __enter__(self):
        self.directory = Path(tempfile.mkdtemp(prefix="sweetspot-audio-", dir=self.rootfs / "tmp"))
        try:
            self.directory.chmod(0o755)
            relative = "/tmp/" + self.directory.name
            self.urls = []
            for reference in self.references:
                target = self.directory / reference.name
                shutil.copyfile(reference, target)
                target.chmod(0o644)
                self.urls.append("file://" + relative + "/" + reference.name)
            self.playlist = self.directory / "pair.m3u"
            self.playlist.write_text("#EXTM3U\n" + "\n".join(self.urls) + "\n", encoding="utf-8")
            self.playlist.chmod(0o644)
            self.player_path = relative + "/pair.m3u"
            return self
        except BaseException:
            shutil.rmtree(self.directory)
            raise

    def __exit__(self, *_):
        shutil.rmtree(self.directory)


class PacedCapture:
    """Consume stdout at PCM speed; stdout otherwise emits unbounded silence.

    The owner enforces the wall deadline even when a pipe read is blocked,
    then terminates the owned writer before joining the reader thread.
    """
    def __init__(self, stream, path, *, rate, max_bytes, wall_seconds):
        if rate <= 0 or max_bytes <= 0 or max_bytes % 8 or wall_seconds <= 0 or not math.isfinite(wall_seconds):
            raise ValueError("capture limits require a positive rate, whole stereo s32 frames and finite wall time")
        self.stream = stream
        self.path = path
        self.rate = rate
        self.max_bytes = max_bytes
        self.wall_seconds = wall_seconds
        self.bytes_written = 0
        self.reason = None
        self.error = None
        self.finished = threading.Event()
        self._stop = threading.Event()
        self.thread = threading.Thread(target=self._read, name="audio-capture")

    def start(self):
        self.started = time.monotonic()
        self.deadline = self.started + self.wall_seconds
        self.thread.start()

    def _read(self):
        try:
            with self.path.open("wb") as capture:
                chunk_bytes = max(8, self.rate // 50 * 8)
                while not self._stop.is_set():
                    if time.monotonic() >= self.deadline:
                        self.reason = "wall_limit"
                        return
                    if self.bytes_written == self.max_bytes:
                        self.reason = "byte_limit"
                        return
                    target = self.started + self.bytes_written / (self.rate * 8)
                    delay = max(0, target - time.monotonic())
                    if self._stop.wait(delay):
                        break
                    wanted = min(chunk_bytes, self.max_bytes - self.bytes_written)
                    # read1/os.read avoid a buffered read waiting to fill wanted.
                    data = os.read(self.stream.fileno(), wanted)
                    if not data:
                        self.reason = "eof"
                        return
                    if time.monotonic() >= self.deadline:
                        self.reason = "wall_limit"
                        return
                    capture.write(data)
                    self.bytes_written += len(data)
                self.reason = self.reason or "stopped"
        except Exception as error:
            self.error = str(error)
            self.reason = "read_error"
        finally:
            self.finished.set()

    def stop(self):
        self._stop.set()

    def join(self):
        self.thread.join(3)
        if self.thread.is_alive():
            raise AudioError("capture reader did not stop after writer termination")
        self.stream.close()


def stop_process(process, *, owned_group=False):
    """Signal only this process, or its private group when it owns that group."""
    group = process.pid if owned_group and os.name == "posix" else None
    if group is None and process.poll() is not None:
        return
    if os.name == "posix" and group is None:
        try:
            if os.getpgid(process.pid) == process.pid:
                group = process.pid
        except ProcessLookupError:
            return
    try:
        if group is not None:
            os.killpg(group, signal.SIGTERM)
        else:
            process.terminate()
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        if group is not None:
            os.killpg(group, signal.SIGKILL)
        else:
            process.kill()
        process.wait(timeout=3)
    except ProcessLookupError:
        process.wait(timeout=3)
    finally:
        # An exec'd writer normally has no children. A child which outlived
        # the group leader still belongs to our private session and must stop.
        if group is not None:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass


def run_case(rootfs, client, output, rate, bits, *, process_factory=subprocess.Popen):
    from tools.audio_verification import compare_capture, generate_fixtures
    directory = output / ("%s-%s" % (rate, bits))
    directory.mkdir(parents=True, exist_ok=True)
    report = {"rate": rate, "bits": bits, "status": "fail", "scope": "software_stdout"}
    report["limits"] = {"capture_format": "s32_le", "channels": 2,
                        "max_lead_frames": STARTUP_SECONDS * rate,
                        "max_bytes": CAPTURE_SECONDS * rate * 8, "wall_seconds": WALL_SECONDS}
    mac = "02:" + ":".join("%02x" % value for value in secrets.token_bytes(5))
    report["player_mac"] = mac
    process = None
    capture = None
    root_log = rootfs / "tmp" / "audio-verification.log"
    started = time.monotonic()
    journal_start = len(client.journal)
    try:
        references = generate_fixtures(directory / "references", rate, bits)
        with LocalFixtures(rootfs, references) as fixtures, (directory / "squeezelite-stderr.log").open("wb") as stderr:
            root_log.unlink(missing_ok=True)
            command = ["chroot", str(rootfs), "/usr/bin/squeezelite", "-o", "-", "-a", "32",
                       "-r", str(rate), "-s", "127.0.0.1", "-m", mac,
                       "-n", "Audio-test", "-f", "/tmp/audio-verification.log"]
            report["command"] = command
            try:
                process = process_factory(command, stdout=subprocess.PIPE, stderr=stderr,
                                          start_new_session=os.name == "posix")
                capture = PacedCapture(process.stdout, directory / "capture.raw", rate=rate,
                                       max_bytes=report["limits"]["max_bytes"], wall_seconds=WALL_SECONDS)
                capture.start()
                wait_connected(client, mac, process)
                report["settings"] = configure_player(client, mac, deadline=capture.deadline)
                client.request(mac, ["playlist", "play", fixtures.player_path], deadline=capture.deadline)
                report["playlist"] = wait_playlist(client, mac, fixtures.urls)
                while not capture.finished.wait(.05):
                    if time.monotonic() >= capture.deadline:
                        raise AudioError("capture exceeded wall time limit")
                    if process.poll() is not None:
                        raise AudioError("Squeezelite exited with status %s during capture" % process.returncode)
                if capture.error or capture.reason != "byte_limit":
                    raise AudioError("capture ended early: %s (%s bytes; %s)" % (capture.reason, capture.bytes_written, capture.error))
            finally:
                if capture is not None:
                    capture.stop()
                if process is not None:
                    stop_process(process, owned_group=os.name == "posix")
                if capture is not None:
                    capture.join()
            report["comparison"] = compare_capture(references, directory / "capture.raw", capture_format="s32_le",
                                                    capture_rate=rate, max_lead_frames=STARTUP_SECONDS * rate)
            report["status"] = report["comparison"]["status"]
    except Exception as error:
        report["error"] = str(error)
    finally:
        report["rpc"] = client.journal[journal_start:]
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        if capture is not None:
            report["capture"] = {"path": str(capture.path), "bytes": capture.bytes_written,
                                 "reason": capture.reason, "error": capture.error}
        if root_log.exists():
            shutil.copyfile(root_log, directory / "squeezelite.log")
        write_json(directory / "report.json", report)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args(argv)
    rootfs = args.rootfs.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"scope": "software_stdout", "version": args.version, "rootfs": str(rootfs),
              "server": args.server, "status": "fail", "cases": []}
    try:
        binary = rootfs / "usr" / "bin" / "squeezelite"
        with binary.open("rb") as executable:
            digest = hashlib.sha256()
            for chunk in iter(lambda: executable.read(65536), b""):
                digest.update(chunk)
        report["squeezelite_sha256"] = digest.hexdigest()
        client = LmsClient(args.server)
        for rate, bits in CASES:
            result = run_case(rootfs, client, output, rate, bits)
            report["cases"].append(result)
            write_json(output / "report.json", report)
            print("%s Hz / %s bit: %s" % (rate, bits, result["status"]), flush=True)
    except Exception as error:
        report["error"] = str(error)
    finally:
        completed = {(case["rate"], case["bits"]) for case in report["cases"]}
        for rate, bits in CASES:
            if (rate, bits) not in completed:
                report["cases"].append({"rate": rate, "bits": bits, "status": "fail", "error": "case was not completed"})
        if len(report["cases"]) == 6 and all(case["status"] == "pass" for case in report["cases"]):
            report["status"] = "pass"
        write_json(output / "report.json", report)
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
