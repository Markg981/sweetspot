#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""CVE triage gate: the real table, the main snapshot and synthetic reports."""

import datetime
import importlib.util
import io
import json
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("triage", ROOT / "scripts/triage-cve.py")
triage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(triage)
TABLE = ROOT / "docs/triage-cve.tsv"
SNAPSHOT = ROOT / "docs/evidenze/grype-x86_64.json"
TODAY = datetime.date(2026, 10, 25)
HEADER = "\t".join(triage.COLONNE)


def match(cve, severity="High", name="ffmpeg", version="9.0.2", related=()):
    return {"vulnerability": {"id": cve, "severity": severity},
            "artifact": {"name": name, "version": version},
            "relatedVulnerabilities": [{"id": r} for r in related]}


class TriageGate(unittest.TestCase):
    def run_gate(self, matches, rows, today=TODAY):
        with tempfile.TemporaryDirectory() as d:
            table = Path(d, "t.tsv")
            table.write_text("# comment\n" + HEADER + "\n" + "".join(r + "\n" for r in rows))
            report = Path(d, "g.json")
            report.write_text(json.dumps({"matches": matches}))
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                rc = triage.main([str(report), "--triage", str(table), "--oggi", today.isoformat()])
            return rc, err.getvalue()

    def test_real_table_is_valid(self):
        rows, errors = triage.leggi_triage(TABLE)
        self.assertEqual(errors, [])
        self.assertTrue(rows)
        for r in rows:
            if r["decisione"] == "accettata":
                self.assertGreater(r["scadenza"], TODAY, r["cve"])

    def test_snapshot_fails_only_on_cves_fixed_by_the_upgrades(self):
        rows, _ = triage.leggi_triage(TABLE)
        report = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        problems, _ = triage.controlla(report, rows, TODAY)
        missing = sorted(p.split()[0] for p in problems)
        self.assertEqual(missing, sorted([
            # mov.c: the mov demuxer is compiled (ALAC), fixed in ffmpeg 9.0
            "CVE-2026-40962", "CVE-2026-96611", "CVE-2026-52297",
            # openssl 3.6.4, fixed by Buildroot 2026.08.1 (3.6.5)
            "CVE-2026-54873", "CVE-2026-72897", "CVE-2026-84782", "CVE-2026-84784",
        ]))

    def test_curl_without_http2_holds(self):
        # CVE-2026-92392 is non-affetta only while curl is built without nghttp2
        for defconfig in sorted(ROOT.glob("configs/*_defconfig")):
            with self.subTest(defconfig=defconfig.name):
                self.assertNotIn("BR2_PACKAGE_NGHTTP2=y", defconfig.read_text())

    def test_untriaged_high_fails_and_medium_does_not(self):
        rc, err = self.run_gate([match("CVE-1"), match("CVE-2", "Medium")], [])
        self.assertEqual(rc, 1)
        self.assertIn("CVE-1 (High)", err)
        self.assertNotIn("CVE-2", err)
        self.assertEqual(self.run_gate([match("CVE-2", "Medium")], [])[0], 0)

    def test_critical_needs_triage(self):
        self.assertEqual(self.run_gate([match("CVE-1", "Critical")], [])[0], 1)

    def test_wildcard_exact_version_and_alias(self):
        rows = ["CVE-1\tffmpeg\t*\tnon-affetta\t\tnot built",
                "CVE-2\tbusybox\t1.38.0\taccettata\t2027-01-31\tno fix yet",
                "CVE-3\tffmpeg\t*\tnon-affetta\t\tnot built"]
        matches = [match("CVE-1"), match("CVE-2", name="busybox", version="1.38.0"),
                   match("GHSA-x", related=["CVE-3"])]
        self.assertEqual(self.run_gate(matches, rows)[0], 0)

    def test_other_version_or_package_is_not_covered(self):
        rows = ["CVE-2\tbusybox\t1.38.0\taccettata\t2027-01-31\tno fix yet"]
        self.assertEqual(self.run_gate([match("CVE-2", name="busybox", version="1.39.0")], rows)[0], 1)
        self.assertEqual(self.run_gate([match("CVE-2", name="openssl", version="1.38.0")], rows)[0], 1)

    def test_expired_acceptance_fails(self):
        rows = ["CVE-2\tbusybox\t1.38.0\taccettata\t2026-10-24\tno fix yet"]
        rc, err = self.run_gate([match("CVE-2", name="busybox", version="1.38.0")], rows)
        self.assertEqual(rc, 1)
        self.assertIn("scaduto", err)

    def test_malformed_table_fails_even_without_matches(self):
        for bad in ("CVE-1\tffmpeg\t*\tforse\t\twhy",
                    "CVE-1\tffmpeg\t*\taccettata\t\tno date",
                    "CVE-1\tffmpeg\t*\taccettata\t31/01/2027\tbad date",
                    "CVE-1\tffmpeg\t*\tnon-affetta\t\t ",
                    "CVE-1\tffmpeg\tnon-affetta"):
            with self.subTest(bad=bad):
                self.assertEqual(self.run_gate([], [bad])[0], 1)


class Workflow(unittest.TestCase):
    def test_gate_runs_in_build_and_blocks(self):
        build = yaml.safe_load((ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8"))
        steps = build["jobs"]["build"]["steps"]
        gate = [s for s in steps if "triage-cve.py" in s.get("run", "")]
        self.assertEqual(len(gate), 1)
        self.assertNotIn("continue-on-error", gate[0])

    def test_esito_aggregates_every_job(self):
        build = yaml.safe_load((ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8"))
        esito = build["jobs"]["esito"]
        self.assertIn("always()", esito["if"])
        self.assertTrue({"test", "modifiche", "build", "lyrion"} <= set(esito["needs"]))

    def test_actions_are_pinned_to_a_commit(self):
        for wf in sorted((ROOT / ".github/workflows").glob("*.yml")):
            for line in wf.read_text(encoding="utf-8").splitlines():
                if "uses:" in line and not line.strip().startswith("#"):
                    ref = line.split("uses:", 1)[1].split("#")[0].strip()
                    with self.subTest(workflow=wf.name, uses=ref):
                        self.assertRegex(ref, r"@[0-9a-f]{40}$")

    def test_docker_base_pinned_by_digest(self):
        text = (ROOT / "docker/Dockerfile").read_text(encoding="utf-8")
        self.assertRegex(text, r"(?m)^FROM debian:[a-z-]+@sha256:[0-9a-f]{64}$")
        self.assertIn("snapshot.debian.org", text)


if __name__ == "__main__":
    unittest.main()
