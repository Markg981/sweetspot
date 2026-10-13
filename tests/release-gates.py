#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Release eligibility and the real workflow signing checks, without a build."""

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/build.yml").read_text())
PUBKEY = Path("board/sweetspot/rootfs-overlay/etc/sweetspot/aggiornamenti.pub")


def ancestors(job):
    needs = WORKFLOW["jobs"][job].get("needs", [])
    if isinstance(needs, str):
        needs = [needs]
    return set(needs).union(*(ancestors(dep) for dep in needs))


def eligible(job, ref, results):
    """Evaluate the narrow release expression plus Actions' success default."""
    expression = str(WORKFLOW["jobs"][job].get("if", "success()"))
    expression = expression.removeprefix("${{").removesuffix("}}").strip()
    success = all(results[dep] == "success" for dep in ancestors(job))
    if not re.search(r"\b(?:always|success|failure|cancelled)\s*\(", expression):
        expression = "success() && (" + expression + ")"
    expression = expression.replace("success()", repr(success))
    expression = expression.replace("always()", "True")
    expression = expression.replace("cancelled()", repr("cancelled" in results.values()))
    expression = expression.replace("failure()", repr("failure" in results.values()))
    expression = re.sub(r"needs\.([a-z_]+)\.result", lambda m: repr(results[m[1]]), expression)
    expression = expression.replace("github.ref", repr(ref))
    expression = re.sub(r"startsWith\(([^,]+),\s*([^)]*)\)", r"(\1).startswith(\2)", expression)
    expression = expression.replace("&&", " and ").replace("||", " or ")
    expression = re.sub(r"!(?!=)", " not ", expression)
    return eval(expression, {"__builtins__": {}}, {})


def workflow_script(job, name, board="x86_64", runner_temp=None):
    if job not in WORKFLOW["jobs"]:
        raise AssertionError(f"missing workflow job: {job}")
    for step in WORKFLOW["jobs"][job]["steps"]:
        if step.get("name") == name:
            script = step["run"].replace("${{ matrix.scheda }}", board)
            if runner_temp is not None:
                script = re.sub(r"\$\{\{\s*runner\.temp\s*\}\}",
                                lambda _: str(runner_temp), script)
            return script
    raise AssertionError(f"missing workflow check: {job}/{name}")


class ReleaseGateTests(unittest.TestCase):
    def test_audio_evidence_survives_sudo_environment_filtering(self):
        steps = WORKFLOW["jobs"]["lyrion"]["steps"]
        run_step = next(step for step in steps
                        if step.get("name") == "Lyrion e verifica PCM nel sistema compilato")
        upload = next(step for step in steps
                      if step.get("name") == "Evidenza della verifica audio software")
        for board in ("x86_64", "rpi"):
            for dirname in ("runner-temp", "runner temp with spaces"):
                with self.subTest(board=board, dirname=dirname), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    runner_temp = root / dirname
                    tools = root / "test-bin"
                    tools.mkdir()
                    # Model a sudo policy that drops the caller's report variable,
                    # even with -E. The real env applet must receive the assignment.
                    sudo = tools / "sudo"
                    sudo.write_text('#!/bin/sh\n[ "$1" = -E ] && shift\n'
                                    'exec env -u SWEETSPOT_AUDIO_REPORT_DIR "$@"\n')
                    sudo.chmod(0o755)
                    tests = root / "tests"
                    tests.mkdir()
                    (tests / "prova-lyrion.sh").write_text(
                        '#!/bin/sh\nset -eu\n'
                        'report=${SWEETSPOT_AUDIO_REPORT_DIR:-graphify-out/audio-evidence}\n'
                        'mkdir -p "$report/run.fixture"\n'
                        'printf "%s\\n" "$1" > "$report/run.fixture/report.txt"\n')
                    expand = lambda value: re.sub(r"\$\{\{\s*runner\.temp\s*\}\}",
                                                 lambda _: str(runner_temp), value)
                    env = {**os.environ, "PATH": str(tools) + ":" + os.environ["PATH"],
                           **{key: expand(value) for key, value in run_step.get("env", {}).items()}}
                    result = subprocess.run(
                        ["bash", "-e", "-o", "pipefail", "-c",
                         workflow_script("lyrion", run_step["name"], board, runner_temp)],
                        cwd=root, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    report = Path(expand(upload["with"]["path"])) / "run.fixture/report.txt"
                    self.assertTrue(report.is_file(), f"no evidence under upload path: {report}")
                    self.assertEqual(report.read_text(), f"sweetspot-{board}-aggiornamento.tar\n")

    def test_pull_requests_rebuild_only_when_image_inputs_change(self):
        step = next(step for step in WORKFLOW["jobs"]["modifiche"]["steps"] if step.get("id") == "file")
        cases = (("pull_request", ["docs/audio-verification.md", "README.md"], "false"),
                 ("pull_request", ["tests/prova-audio.py", "tools/audio_verification.py",
                                   ".github/workflows/build.yml"], "false"),
                 ("pull_request", ["tests/x.py", "board/sweetspot/x86/linux.fragment"], "true"),
                 ("pull_request", ["package/lms/lms.mk"], "true"),
                 ("pull_request", ["scripts/build.sh"], "true"),
                 ("pull_request", ["external.mk"], "true"),
                 ("pull_request", ["docs/configs/nota.md"], "false"),
                 ("push", [], "true"), ("workflow_dispatch", [], "true"))
        for event, files, expected in cases:
            with self.subTest(event=event, files=files), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                tools = root / "bin"
                tools.mkdir()
                (root / "files.txt").write_text("".join(name + "\n" for name in files))
                (tools / "git").write_text('#!/bin/sh\ncat "%s"\n' % (root / "files.txt"))
                (tools / "git").chmod(0o755)
                output = root / "output"
                env = {**os.environ, "PATH": str(tools) + ":" + os.environ["PATH"], "EVENTO": event,
                       "BASE": "0" * 40, "GITHUB_OUTPUT": str(output)}
                result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step["run"]],
                                        cwd=root, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(), "compila=%s\n" % expected)

    def test_reused_main_packages_feed_every_proof_and_are_recorded(self):
        jobs = WORKFLOW["jobs"]
        self.assertEqual(jobs["build"]["if"], "${{ needs.modifiche.outputs.compila == 'true' }}")
        self.assertIn("modifiche", jobs["build"]["needs"])
        self.assertEqual(jobs["lyrion"]["permissions"].get("actions"), "read")
        downloads = [step for step in jobs["lyrion"]["steps"]
                     if step.get("uses", "").startswith("actions/download-artifact@")]
        self.assertEqual({step["with"]["name"] for step in downloads},
                         {"sweetspot-${{ matrix.scheda }}-aggiornamento.tar", "sweetspot.img.xz"})
        for step in downloads:
            self.assertEqual(step["with"]["run-id"], "${{ steps.pacchetti.outputs.id }}")
        choose = next(step for step in jobs["lyrion"]["steps"] if step.get("id") == "pacchetti")
        self.assertIn("branch=main&event=push&status=success", choose["run"])
        self.assertIn("pacchetti.txt", choose["run"])
        # Tags never reuse packages: modifiche compiles on every non-PR event.
        self.assertIn("needs.build.result == 'success'", jobs["release"]["if"])

    def test_x86_alsa_proof_boots_the_image_and_keeps_evidence(self):
        steps = WORKFLOW["jobs"]["lyrion"]["steps"]
        names = [step.get("name") for step in steps]
        proof = steps[names.index("Verifica PCM/DoP sul percorso ALSA in QEMU")]
        download = steps[names.index("Verifica PCM/DoP sul percorso ALSA in QEMU") - 1]
        upload = steps[names.index("Evidenza della verifica audio software")]
        self.assertEqual(download["with"]["name"], "sweetspot.img.xz")
        for step in (download, proof):
            self.assertIn("matrix.scheda == 'x86_64'", step["if"])
            self.assertIn("!cancelled()", step["if"])
            self.assertFalse(step.get("continue-on-error", False))
        self.assertLess(names.index("Verifica PCM/DoP sul percorso ALSA in QEMU"),
                        names.index("Evidenza della verifica audio software"))
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner_temp = root / "runner temp"
            tools = root / "test-bin"
            tools.mkdir()
            sudo = tools / "sudo"
            sudo.write_text('#!/bin/sh\n[ "$1" = -E ] && shift\n'
                            'exec env -u SWEETSPOT_AUDIO_REPORT_DIR "$@"\n')
            (tools / "apt-get").write_text("#!/bin/sh\nexit 0\n")
            for tool in tools.iterdir():
                tool.chmod(0o755)
            (root / "versione").write_text("v-fixture\n")
            subprocess.run(["tar", "-cf", "sweetspot-x86_64-aggiornamento.tar", "versione"], cwd=root, check=True)
            (root / "tests").mkdir()
            (root / "tests" / "prova-alsa-qemu.sh").write_text(
                '#!/bin/sh\nset -eu\n'
                'mkdir -p "$SWEETSPOT_AUDIO_REPORT_DIR/alsa-qemu.fixture"\n'
                'printf "%s %s\\n" "$1" "$2" > "$SWEETSPOT_AUDIO_REPORT_DIR/alsa-qemu.fixture/report.txt"\n')
            env = {**os.environ, "PATH": str(tools) + ":" + os.environ["PATH"]}
            result = subprocess.run(
                ["bash", "-e", "-o", "pipefail", "-c",
                 workflow_script("lyrion", proof["name"], "x86_64", runner_temp)],
                cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            path = re.sub(r"\$\{\{\s*runner\.temp\s*\}\}", lambda _: str(runner_temp), upload["with"]["path"])
            report = Path(path) / "alsa-qemu.fixture/report.txt"
            self.assertEqual(report.read_text(), "sweetspot.img.xz v-fixture\n")

    def test_audio_upload_is_required_even_after_probe_failure(self):
        definition = WORKFLOW["jobs"]["lyrion"]
        upload = next(step for step in definition["steps"]
                      if step.get("name") == "Evidenza della verifica audio software")
        self.assertTrue(upload.get("uses", "").startswith("actions/upload-artifact@"))
        self.assertEqual(upload.get("if"), "always()")
        self.assertEqual(upload["with"].get("if-no-files-found"), "error")
        self.assertFalse(upload.get("continue-on-error", False))
        self.assertFalse(definition.get("continue-on-error", False))
        self.assertIn("lyrion", ancestors("release"))

    def test_publication_waits_for_every_required_job(self):
        publishers = [(job, step) for job, definition in WORKFLOW["jobs"].items()
                      for step in definition["steps"]
                      if step.get("uses", "").startswith("softprops/action-gh-release@")]
        self.assertEqual(len(publishers), 1, "publish once after both architectures pass")
        job, step = publishers[0]
        self.assertTrue({"test", "build", "lyrion"} <= ancestors(job),
                        "publication can run before all test/build/Lyrion jobs finish")
        self.assertFalse(step.get("continue-on-error", False))
        self.assertFalse(WORKFLOW["jobs"][job].get("continue-on-error", False))
        self.assertTrue(step["with"].get("fail_on_unmatched_files"),
                        "missing release assets must fail publication")

    def test_publication_rejects_failed_skipped_cancelled_and_non_tag_runs(self):
        self.assertIn("release", WORKFLOW["jobs"], "publication needs a downstream job")
        good = {"modifiche": "success", "test": "success", "build": "success", "lyrion": "success"}
        self.assertTrue(eligible("release", "refs/tags/v1.0.0", good))
        for job in good:
            for result in ("failure", "skipped", "cancelled"):
                with self.subTest(job=job, result=result):
                    self.assertFalse(eligible("release", "refs/tags/v1.0.0", {**good, job: result}))
        self.assertFalse(eligible("release", "refs/heads/main", good))


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sweetspot-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pub = self.root / PUBKEY
        self.pub.parent.mkdir(parents=True)
        self.key = self.root / "fixture.key"
        subprocess.run(["minisign", "-G", "-W", "-p", str(self.pub), "-s", str(self.key)],
                       check=True, capture_output=True)
        # Only dependency installation is external; hashes, tar, cpio and minisign are real.
        tools = self.root / "test-bin"
        tools.mkdir()
        sudo = tools / "sudo"
        sudo.write_text("#!/bin/sh\n[ \"$1\" = apt-get ] && exit 0\nexit 1\n")
        sudo.chmod(0o755)
        self.env = {**os.environ, "PATH": str(tools) + ":" + os.environ["PATH"],
                    "GITHUB_REF": "refs/tags/v1.0.0", "FIRMA": self.key.read_text()}
        self.package()

    def package(self, embedded=None, tamper=False, board="x86_64"):
        fs = self.root / "rootfs"
        embedded_key = fs / "etc/sweetspot/aggiornamenti.pub"
        embedded_key.parent.mkdir(parents=True, exist_ok=True)
        embedded_key.write_bytes(self.pub.read_bytes() if embedded is None else embedded)
        cpio = subprocess.run(["cpio", "--create", "--format=newc", "--quiet"],
                              cwd=fs, input=b"./etc/sweetspot/aggiornamenti.pub\n",
                              check=True, capture_output=True).stdout
        compressed = subprocess.run(["zstd", "-q", "-c"], input=cpio,
                                    check=True, capture_output=True).stdout
        pkg = self.root / "package"
        pkg.mkdir(exist_ok=True)
        (pkg / "bzImage").write_bytes(b"fixture kernel")
        (pkg / "rootfs.cpio.zst").write_bytes(compressed)
        (pkg / "versione").write_text("v1.0.0\n")
        (pkg / "architettura").write_text(board + "\n")
        names = ["architettura", "bzImage", "rootfs.cpio.zst", "versione"]
        (pkg / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256((pkg / name).read_bytes()).hexdigest()}  {name}\n" for name in names))
        if tamper:
            (pkg / "bzImage").write_bytes(b"changed after hashing")
        self.tar = self.root / f"output/images/sweetspot-{board}-aggiornamento.tar"
        self.tar.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(self.tar, "w") as archive:
            for name in names + ["SHA256SUMS"]:
                archive.add(pkg / name, arcname=name)

    def sign(self, board="x86_64"):
        return subprocess.run(["bash", "-e", "-o", "pipefail", "-c",
                               workflow_script("build", "Firma del pacchetto di aggiornamento", board)],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_official_tag_requires_signing_secret(self):
        self.env["FIRMA"] = ""
        self.assertNotEqual(self.sign().returncode, 0, "an official update was left unsigned")

    def test_development_build_can_remain_unsigned(self):
        self.env.update(FIRMA="", GITHUB_REF="refs/heads/main")
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning", result.stdout)
        with tarfile.open(self.tar) as archive:
            self.assertNotIn("SHA256SUMS.minisig", archive.getnames())

    def test_signing_requires_public_key(self):
        self.pub.unlink()
        self.assertNotEqual(self.sign().returncode, 0, "signature was never checked against the project key")

    def test_signing_rejects_hash_mismatch(self):
        self.package(tamper=True)
        self.assertNotEqual(self.sign().returncode, 0, "signed a manifest that does not match its payload")

    def test_signing_rejects_different_embedded_key(self):
        self.package(embedded=b"different embedded key\n")
        self.assertNotEqual(self.sign().returncode, 0, "devices embed a different verification key")

    def test_signed_archive_verifies_with_the_embedded_key(self):
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        signed = self.root / "signed"
        signed.mkdir()
        with tarfile.open(self.tar) as archive:
            archive.extractall(signed, filter="data")
        subprocess.run(["minisign", "-V", "-p", str(self.pub), "-m", str(signed / "SHA256SUMS"),
                        "-x", str(signed / "SHA256SUMS.minisig")], check=True, capture_output=True)
        subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=signed, check=True, capture_output=True)

    def release_artifacts(self):
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        for board in ("x86_64", "rpi"):
            self.package(board=board)
            result = self.sign(board)
            self.assertEqual(result.returncode, 0, result.stderr)
            (artifacts / self.tar.name).write_bytes(self.tar.read_bytes())
            self.tar.unlink()
        for image in ("sweetspot.img.xz", "sweetspot-rpi.img.xz", "sweetspot-vmware.vmdk"):
            (artifacts / image).write_bytes(b"fixture image")

    def verify_release(self):
        return subprocess.run(["bash", "-e", "-o", "pipefail", "-c",
                               workflow_script("release", "Verifica degli aggiornamenti firmati")],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def change_release_archive(self, change):
        archive_path = self.root / "artifacts/sweetspot-x86_64-aggiornamento.tar"
        extracted = self.root / "downloaded"
        extracted.mkdir()
        with tarfile.open(archive_path) as archive:
            archive.extractall(extracted, filter="data")
        change(extracted)
        with tarfile.open(archive_path, "w") as archive:
            for path in extracted.iterdir():
                archive.add(path, arcname=path.name)

    def test_release_verifies_both_downloaded_archives(self):
        self.release_artifacts()
        result = self.verify_release()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_rejects_unsigned_download(self):
        self.release_artifacts()
        self.change_release_archive(lambda path: (path / "SHA256SUMS.minisig").unlink())
        self.assertNotEqual(self.verify_release().returncode, 0)

    def test_release_rejects_payload_changed_after_signing(self):
        self.release_artifacts()
        self.change_release_archive(lambda path: (path / "bzImage").write_bytes(b"corrupted download"))
        self.assertNotEqual(self.verify_release().returncode, 0)

    def test_release_rejects_missing_architecture_artifact(self):
        self.release_artifacts()
        (self.root / "artifacts/sweetspot-rpi-aggiornamento.tar").unlink()
        self.assertNotEqual(self.verify_release().returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
