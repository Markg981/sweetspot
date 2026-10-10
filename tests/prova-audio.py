#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify isolated rootfs Lyrion/Squeezelite PCM, DoP and DSD output.

The software_stdout backend reads Squeezelite stdout. The alsa_loopback
backend plays to hw:Loopback (snd-aloop) with the production ALSA access
settings and records the paired capture substream. Neither certifies a DAC,
its clock, or analog output. Lyrion must already be running in the isolated
rootfs, on loopback.
"""
import argparse
import hashlib
import json
import math
import os
import re
import secrets
import shlex
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
CASES = [{"id": "pcm-%s-%s-%s" % (rate, first, second), "kind": "pcm",
          "rate": rate, "source_bits": [first, second]}
         for first, second in ((16, 16), (24, 24), (16, 24), (24, 16))
         for rate in (44100, 48000, 96000)]
CASES += [{"id": "dop-%s-24-24" % rate, "kind": "dop_pcm_passthrough",
           "rate": rate, "source_bits": [24, 24]}
          for rate in (176400, 352800)]
CASES += [{"id": "%s-%s-dop" % (container, rate * 16), "kind": "dsd_to_dop",
           "rate": rate, "source_bits": [1, 1], "source_format": container,
           "carrier_bits": 24, "dsd_rate": rate * 16, "scope": "software_stdout"}
          for container in ("dsf", "dff") for rate in (176400, 352800)]
STARTUP_SECONDS = 10
CAPTURE_SECONDS = STARTUP_SECONDS + 2 + 1
WALL_SECONDS = CAPTURE_SECONDS + 3
BACKENDS = ("software_stdout", "alsa_loopback")
# Same device class and access as sweetspot-player without CamillaDSP: hw:
# device, 400 ms ALSA buffer in four periods, automatic format, mmap.
ALSA_PLAYBACK = "hw:CARD=Loopback,DEV=0"
ALSA_CAPTURE = "hw:CARD=Loopback,DEV=1"
ALSA_BUFFER = "400:4::1"
ALSA_FORMATS = {"S16_LE": ("s16_le", 4), "S24_3LE": ("s24_3le", 6),
                "S24_LE": ("s24_le", 8), "S32_LE": ("s32_le", 8)}
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
    """Copy playback sources into a unique, LMS-readable rootfs directory."""
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


class ChrootTarget:
    """Run the engine in the extracted rootfs on this host, with its kernel."""
    def __init__(self, rootfs, asound=Path("/proc/asound")):
        self.rootfs = rootfs
        self.asound_root = asound
        self.description = str(rootfs)

    def command(self, argv):
        return ["chroot", str(self.rootfs)] + argv

    def fixtures(self, sources):
        return LocalFixtures(self.rootfs, sources)

    def read_bytes(self, path):
        return (self.rootfs / path.lstrip("/")).read_bytes()

    def asound(self, relative):
        return (self.asound_root / relative).read_text(encoding="ascii")

    def remove(self, path):
        (self.rootfs / path.lstrip("/")).unlink(missing_ok=True)

    def fetch(self, path, destination):
        """Copy a target file; False when it does not exist."""
        source = self.rootfs / path.lstrip("/")
        if not source.exists():
            return False
        shutil.copyfile(source, destination)
        return True

    def stop_engine(self):
        """Owned process groups already stop chroot children."""


class SshTarget:
    """Run the engine on a booted Sweetspot system, e.g. a QEMU guest.

    Commands go through an argv prefix such as sshpass/ssh. Killing the local
    ssh client does not stop the remote engine, so stop_engine does it.
    """
    def __init__(self, ssh, *, description, timeout=30):
        self.ssh = list(ssh)
        self.description = description
        self.timeout = timeout

    def run(self, script, data=None):
        try:
            result = subprocess.run(self.ssh + [script], input=data, capture_output=True,
                                    timeout=self.timeout)
        except subprocess.TimeoutExpired as error:
            raise OSError("remote command timed out: %s" % script) from error
        if result.returncode != 0:
            raise OSError("remote command failed (%s): %s: %s" % (
                result.returncode, script, result.stderr.decode(errors="replace").strip()))
        return result.stdout

    def command(self, argv):
        return self.ssh + ["exec " + " ".join(shlex.quote(part) for part in argv)]

    def fixtures(self, sources):
        return RemoteFixtures(self, sources)

    def read_bytes(self, path):
        return self.run("cat " + shlex.quote(path))

    def asound(self, relative):
        return self.read_bytes("/proc/asound/" + relative).decode("ascii")

    def remove(self, path):
        self.run("rm -f " + shlex.quote(path))

    def fetch(self, path, destination):
        quoted = shlex.quote(path)
        if self.run("if [ -e %s ]; then echo yes; fi" % quoted).strip() != b"yes":
            return False
        destination.write_bytes(self.read_bytes(path))
        return True

    def stop_engine(self):
        self.run("killall -q squeezelite aplay; true")


class RemoteFixtures:
    """Copy playback sources into a unique, LMS-readable directory on the target."""
    def __init__(self, target, references):
        self.target = target
        self.references = references
        self.directory = None

    def __enter__(self):
        self.directory = self.target.run(
            'd=$(mktemp -d /tmp/sweetspot-audio-XXXXXX) && chmod 755 "$d" && echo "$d"').decode().strip()
        if not re.fullmatch(r"/tmp/sweetspot-audio-[A-Za-z0-9]+", self.directory):
            raise AudioError("unexpected remote fixture directory %r" % self.directory)
        try:
            self.urls = []
            for reference in self.references:
                remote = self.directory + "/" + reference.name
                self.target.run("cat > %s && chmod 644 %s" % (shlex.quote(remote), shlex.quote(remote)),
                                reference.read_bytes())
                self.urls.append("file://" + remote)
            self.player_path = self.directory + "/pair.m3u"
            playlist = ("#EXTM3U\n" + "\n".join(self.urls) + "\n").encode("utf-8")
            self.target.run("cat > %s && chmod 644 %s" % (shlex.quote(self.player_path),
                                                           shlex.quote(self.player_path)), playlist)
            return self
        except BaseException:
            self.target.run("rm -rf " + shlex.quote(self.directory))
            raise

    def __exit__(self, *_):
        self.target.run("rm -rf " + shlex.quote(self.directory))


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


def loopback_state(target, stream):
    """Read hw_params and status of the paired Loopback substream 0.

    Returns None while the substream is closed. Malformed or missing kernel
    files never produce parameters.
    """
    directory = "Loopback/pcm0%s/sub0/" % stream
    try:
        text = target.asound(directory + "hw_params")
        status = target.asound(directory + "status")
    except (OSError, UnicodeError) as error:
        raise AudioError("Loopback %s substream is not readable: %s" % (stream, error)) from error
    if text.strip() == "closed":
        return None
    fields = {}
    for line in text.splitlines():
        name, separator, value = line.partition(":")
        if separator:
            fields[name.strip()] = value.strip()
    state = re.search(r"^state:\s*(\S+)", status, re.M)
    try:
        return {"access": fields["access"], "format": fields["format"],
                "channels": int(fields["channels"]), "rate": int(fields["rate"].split()[0]),
                "period_size": int(fields["period_size"]), "buffer_size": int(fields["buffer_size"]),
                "state": state.group(1) if state else None, "hw_params": text}
    except (KeyError, ValueError, IndexError) as error:
        raise AudioError("malformed Loopback %s hw_params: %r" % (stream, text)) from error


def wait_loopback_playback(target, rate, process, timeout=8, interval=.05):
    """Wait for the player to run on hw:Loopback with the production access."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AudioError("Squeezelite exited with status %s before opening ALSA" % process.returncode)
        params = loopback_state(target, "p")
        if params is not None and params["state"] == "RUNNING":
            expected = {"access": "MMAP_INTERLEAVED", "channels": 2, "rate": rate}
            for name, value in expected.items():
                if params[name] != value:
                    raise AudioError("Loopback playback %s is %r, wanted %r" % (name, params[name], value))
            if params["format"] not in ALSA_FORMATS:
                raise AudioError("Loopback playback format %s is not a verified container" % params["format"])
            return params
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
    raise AudioError("Squeezelite did not start hw:Loopback playback before deadline")


class LoopbackCapture:
    """Record the paired snd-aloop capture substream with the target's aplay.

    snd-aloop paces both sides with its own timer, so the capture is bounded
    by an exact frame count and a wall deadline rather than by read pacing.
    """
    def __init__(self, target, path, *, params, seconds, wall_seconds, process_factory, stderr):
        self.path = path
        self.format, self.frame_bytes = ALSA_FORMATS[params["format"]]
        self.max_bytes = seconds * params["rate"] * self.frame_bytes
        self.wall_seconds = wall_seconds
        self.command = target.command(["/usr/bin/aplay", "-C", "-q", "-D", ALSA_CAPTURE,
                                       "-t", "raw", "-f", params["format"], "-c", "2",
                                       "-r", str(params["rate"]), "-d", str(seconds)])
        self.process_factory = process_factory
        self.stderr = stderr
        self.process = None
        self.bytes_written = 0
        self.reason = None
        self.error = None
        self.finished = threading.Event()
        self.thread = threading.Thread(target=self._wait, name="alsa-capture")

    def start(self):
        self.started = time.monotonic()
        self.deadline = self.started + self.wall_seconds
        with self.path.open("wb") as capture:
            self.process = self.process_factory(self.command, stdout=capture, stderr=self.stderr,
                                                start_new_session=os.name == "posix")
        self.thread.start()

    def _wait(self):
        try:
            try:
                status = self.process.wait(max(0, self.deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                self.reason = "wall_limit"
                return
            self.bytes_written = self.path.stat().st_size
            if status != 0:
                self.reason = "exit_status_%s" % status
            elif self.bytes_written == self.max_bytes:
                self.reason = "byte_limit"
            else:
                self.reason = "eof"
        except Exception as error:
            self.error = str(error)
            self.reason = "read_error"
        finally:
            self.finished.set()

    def stop(self):
        if self.process is not None:
            stop_process(self.process, owned_group=os.name == "posix")

    def join(self):
        self.thread.join(3)
        if self.thread.is_alive():
            raise AudioError("ALSA capture did not stop after termination")
        self.bytes_written = self.path.stat().st_size


def alsa_output_evidence(log, destination, capture_stderr):
    """Require an engine-logged hw:Loopback open without XRUN on either side."""
    data = log.read_bytes() if log.exists() else b""
    text = data.decode("utf-8", errors="replace")
    overruns = capture_stderr.read_text(errors="replace").count("overrun") if capture_stderr.exists() else None
    evidence = {"path": str(destination), "sha256": hashlib.sha256(data).hexdigest() if data else None,
                "device": ALSA_PLAYBACK, "opens": text.count("open output device: %s" % ALSA_PLAYBACK),
                "xruns": len(re.findall(r"\bXRUN\b(?! recover failed)", text)),
                "xrun_recover_failures": text.count("XRUN recover failed"),
                "capture_overruns": overruns}
    evidence["status"] = ("pass" if evidence["opens"] >= 1 and evidence["xruns"] == 0
                          and evidence["xrun_recover_failures"] == 0 and overruns == 0 else "fail")
    return evidence


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


def dsd_decoder_evidence(log, destination, source_format, rate):
    """Require both source decodes and DoP output from the pinned engine log."""
    data = log.read_bytes() if log.exists() else b""
    text = data.decode("utf-8", errors="replace")
    header = "DSF version: 1 format: 0" if source_format == "dsf" else "DSDIFF version: 1.5.0.0"
    output = "DSD%s stream, format: DOP, rate: %sHz" % (64 if rate == 176400 else 128, rate)
    evidence = {"path": str(destination), "sha256": hashlib.sha256(data).hexdigest() if data else None,
                "dsd_codec_opens": text.count("codec open: 'd'"), "source_headers": text.count(header),
                "source_rates": len(re.findall(r"sample rate: %s(?!\d)" % (rate * 16), text)),
                "stereo_headers": len(re.findall(r"channels: 2(?!\d)", text)),
                "dop_outputs": text.count(output),
                "pcm_fallback": "DSD sample rate too high for device - converting to PCM" in text
                                or "DSD to PCM output" in text}
    required = ("dsd_codec_opens", "source_headers", "source_rates", "stereo_headers", "dop_outputs")
    if source_format == "dsf":
        evidence["lsb_first"] = len(re.findall(r"lsb first: 1(?!\d)", text))
        evidence["block_sizes"] = len(re.findall(r"block size: 4096(?!\d)", text))
        required += ("lsb_first", "block_sizes")
    evidence["status"] = "pass" if not evidence["pcm_fallback"] and all(evidence[name] >= 2 for name in required) else "fail"
    return evidence


def run_case(rootfs, client, output, rate, bits, *, second_bits=None, dop=False,
             source_format=None, case_id=None, process_factory=subprocess.Popen,
             backend="software_stdout", asound=Path("/proc/asound"), target=None):
    from tools.audio_verification import compare_capture, generate_fixtures
    target = target or ChrootTarget(rootfs, asound)
    if backend not in BACKENDS:
        raise ValueError("unknown audio backend %r" % backend)
    alsa = backend == "alsa_loopback"
    second_bits = bits if second_bits is None else second_bits
    identity = case_id or ("%s-%s-dop" % (source_format, rate * 16) if source_format else
                           "%s-%s-%s-%s" % ("dop" if dop else "pcm", rate, bits, second_bits))
    # Existing callers without an ID keep their original homogeneous PCM path.
    directory_name = "%s-%s" % (rate, bits) if case_id is None and not dop and not source_format and bits == second_bits else identity
    directory = output / directory_name
    directory.mkdir(parents=True, exist_ok=True)
    report = {"id": identity, "kind": "dsd_to_dop" if source_format else "dop_pcm_passthrough" if dop else "pcm",
              "rate": rate, "bits": bits, "source_bits": [bits, second_bits],
              "status": "fail", "scope": backend}
    if dop or source_format:
        report["dsd_rate"] = rate * 16
    if source_format:
        report.update(source_format=source_format, carrier_bits=24)
    report["limits"] = {"capture_format": "s32_le", "channels": 2,
                        "max_lead_frames": STARTUP_SECONDS * rate,
                        "max_bytes": CAPTURE_SECONDS * rate * 8, "wall_seconds": WALL_SECONDS}
    if alsa:
        # The capture container follows the format the engine negotiated.
        report["limits"].update(capture_format=None, max_bytes=None, capture_seconds=CAPTURE_SECONDS)
    mac = "02:" + ":".join("%02x" % value for value in secrets.token_bytes(5))
    report["player_mac"] = mac
    process = None
    capture = None
    engine_log = "/tmp/audio-verification.log"
    local_log = directory / "squeezelite.log"
    local_log.unlink(missing_ok=True)
    started = time.monotonic()
    journal_start = len(client.journal)
    try:
        if source_format:
            from tools.audio_verification import compare_dop_capture, generate_dsd_fixtures
            if source_format not in ("dsf", "dff") or bits != 1 or second_bits != 1:
                raise AudioError("DSD to DoP requires two one-bit DSF or DFF sources")
            sources, references = generate_dsd_fixtures(directory / "references", rate,
                                                         container=source_format)
            report["sources"] = [{"path": str(source), "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                                  "format": source_format, "bits": 1, "rate": rate * 16, "channels": 2}
                                 for source in sources]
            compare = compare_dop_capture
        elif dop:
            from tools.audio_verification import compare_dop_capture, generate_dop_fixtures
            if bits != 24 or second_bits != 24:
                raise AudioError("DoP passthrough requires two WAV24 sources")
            references = generate_dop_fixtures(directory / "references", rate)
            compare = compare_dop_capture
        elif bits != second_bits:
            references = [generate_fixtures(directory / "references", rate, bits)[0],
                          generate_fixtures(directory / "references", rate, second_bits)[1]]
            compare = compare_capture
        else:
            references = generate_fixtures(directory / "references", rate, bits)
            compare = compare_capture
        if not source_format:
            sources = references
        with target.fixtures(sources) as fixtures, (directory / "squeezelite-stderr.log").open("wb") as stderr:
            target.remove(engine_log)
            if alsa:
                # A single-rate range opens the device at the case rate while
                # idle, so the capture attaches before the first track.
                engine = ["/usr/bin/squeezelite", "-o", ALSA_PLAYBACK,
                          "-a", ALSA_BUFFER, "-r", "%s-%s" % (rate, rate)]
            else:
                engine = ["/usr/bin/squeezelite", "-o", "-", "-a", "32", "-r", str(rate)]
            engine += ["-s", "127.0.0.1", "-m", mac, "-n", "Audio-test", "-f", engine_log]
            if dop or source_format:
                engine.extend(["-D", "0:dop"])
            if source_format:
                engine.extend(["-d", "decode=info", "-d", "stream=info"])
            if alsa:
                engine.extend(["-d", "output=info"])
            command = target.command(engine)
            report["command"] = command
            try:
                if alsa:
                    for stream in ("p", "c"):
                        if loopback_state(target, stream) is not None:
                            raise AudioError("Loopback %s substream is already open by another process" % stream)
                    process = process_factory(command, stdout=subprocess.DEVNULL, stderr=stderr,
                                              start_new_session=os.name == "posix")
                    wait_connected(client, mac, process)
                    playback = wait_loopback_playback(target, rate, process)
                    report["alsa"] = {"playback": playback}
                    capture_stderr = (directory / "capture-stderr.log").open("wb")
                    try:
                        capture = LoopbackCapture(target, directory / "capture.raw", params=playback,
                                                  seconds=CAPTURE_SECONDS, wall_seconds=WALL_SECONDS,
                                                  process_factory=process_factory, stderr=capture_stderr)
                        report["capture_command"] = capture.command
                        report["limits"].update(capture_format=capture.format, max_bytes=capture.max_bytes)
                        capture.start()
                    finally:
                        capture_stderr.close()
                else:
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
                target.stop_engine()
            target.fetch(engine_log, local_log)
            options = {}
            if alsa and compare is not compare_capture:
                options["scope"] = backend
            report["comparison"] = compare(references, directory / "capture.raw",
                                           capture_format=report["limits"]["capture_format"],
                                           capture_rate=rate, max_lead_frames=STARTUP_SECONDS * rate, **options)
            report["status"] = report["comparison"]["status"]
            if alsa:
                report["alsa"]["output"] = alsa_output_evidence(local_log, local_log,
                                                                directory / "capture-stderr.log")
                if report["alsa"]["output"]["status"] != "pass":
                    raise AudioError("ALSA evidence did not verify a hw:Loopback open without XRUN")
            if source_format:
                report["decoder"] = dsd_decoder_evidence(local_log, local_log, source_format, rate)
                if report["decoder"]["status"] != "pass":
                    raise AudioError("DSD decoder evidence did not verify both source tracks and DoP output")
    except Exception as error:
        report["status"] = "fail"
        report["error"] = str(error)
    finally:
        report["rpc"] = client.journal[journal_start:]
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        if capture is not None:
            report["capture"] = {"path": str(capture.path), "bytes": capture.bytes_written,
                                 "reason": capture.reason, "error": capture.error}
        if not local_log.exists():
            try:
                target.fetch(engine_log, local_log)
            except OSError as error:
                report["log_error"] = str(error)
        write_json(directory / "report.json", report)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--rootfs", type=Path, help="extracted rootfs, run with chroot on this host")
    where.add_argument("--ssh-port", type=int,
                       help="booted Sweetspot on --ssh-host (root password in SSHPASS), e.g. a QEMU guest")
    parser.add_argument("--ssh-host", default="127.0.0.1")
    parser.add_argument("--server", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--backend", choices=BACKENDS, default="software_stdout")
    args = parser.parse_args(argv)
    if args.ssh_port is not None:
        rootfs = None
        target = SshTarget(["sshpass", "-e", "ssh", "-p", str(args.ssh_port),
                            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                            "-o", "LogLevel=ERROR", "-o", "ServerAliveInterval=5",
                            "root@" + args.ssh_host],
                           description="ssh://root@%s:%s" % (args.ssh_host, args.ssh_port))
    else:
        rootfs = args.rootfs.resolve()
        target = ChrootTarget(rootfs)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"scope": args.backend, "version": args.version, "rootfs": target.description,
              "server": args.server, "status": "fail", "cases": []}
    try:
        report["squeezelite_sha256"] = hashlib.sha256(target.read_bytes("/usr/bin/squeezelite")).hexdigest()
        client = LmsClient(args.server)
        for case in CASES:
            first, second = case["source_bits"]
            result = run_case(rootfs, client, output, case["rate"], first, second_bits=second,
                              dop=case["kind"] == "dop_pcm_passthrough", source_format=case.get("source_format"),
                              case_id=case["id"], backend=args.backend, target=target)
            report["cases"].append(result)
            write_json(output / "report.json", report)
            print("%s: %s" % (case["id"], result["status"]), flush=True)
    except Exception as error:
        report["error"] = str(error)
    finally:
        completed = {case.get("id") for case in report["cases"] if isinstance(case.get("id"), str)}
        for case in CASES:
            if case["id"] not in completed:
                missing = dict(case, bits=case["source_bits"][0], status="fail", error="case was not completed",
                               scope=args.backend)
                if case["kind"] == "dop_pcm_passthrough":
                    missing["dsd_rate"] = case["rate"] * 16
                report["cases"].append(missing)
        expected = {case["id"] for case in CASES}
        if ("error" not in report and len(report["cases"]) == len(expected) and completed == expected
                and all(case.get("status") == "pass" and "error" not in case for case in report["cases"])):
            report["status"] = "pass"
        write_json(output / "report.json", report)
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
