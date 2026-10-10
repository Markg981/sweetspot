# PCM rate switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax.

**Goal:** Extend the software audio gate from 18 to 24 cases with all six directed WAV24 transitions among 44100, 48000 and 96000 Hz.

**Architecture:** A separate streaming PCM sequence comparison accepts different reference rates and checks the full native-frame concatenation plus the ordered output-rate evidence. The driver collects actual track-start announcements and reports its fixed stdout consumer pacing separately. Existing PCM/DoP/DSD behavior stays compatible.

**Tech Stack:** Python3 standard library, unittest, Lyrion9.1.1 and pinned Squeezelite stdout, Linux chroot, BusyBox and GitHub Actions.

**Spec:** docs/daphile-parity.md, milestone1, and docs/audio-verification.md. This is a bounded continuation of the approved roadmap and the requested branch/push/PR workflow.

## Global Constraints

- Retain the existing18case IDs, order and comparison behavior; add six `pcm_rate_transition` cases with IDs `pcm-rate-44100-48000-24-24` and equivalent directed pairs.
- Reference WAV headers determine expected per-track rates, frame counts and significant bits. No resampling, per-track realignment or internal silence removal.
- New comparator interface: `compare_pcm_sequence(references, capture, *, capture_format, rate_sequence, offset_frames=None, max_lead_frames=0, max_trailing_frames=0, pacing_rate=None)`.
- Report expected_rate_sequence, observed_rate_sequence, rate_sequence_match, boundaries with from_rate/to_rate, per-track frame ranges and first damaged reference/frame. Capture rate is None; pacing_rate is descriptive only.
- The new sequence comparator bounds leading and trailing zero frames; explicit offsets also obey max_lead_frames. Existing compare_capture edge behavior remains compatible.
- Only an exact ordered pair of output track-start rates passes evidence; missing, malformed, extra, duplicated, reordered or wrong announcements fail closed. Preserve engine logs, path and SHA256 in evidence.
- Mixed cases advertise `-r 44100,48000,96000:0` and `-d output=info`; do not enable -R, -u, volume scaling or DSP. Software consumer pacing is44100Hz.
- Mixed capture budget derives from total reference frames plus10seconds of leading silence and10seconds of trailing silence at pacing_rate; wall timeout derives from this byte budget with bounded cleanup slack. Preserve current homogeneous-case limits.
- Diagnostic mixed sources begin with a nonzero stereo frame. The actual initial zero frames determine an adaptive stop threshold within the maximum cap; keep every captured byte and never realign or trim internal silence.
- A failed comparison, rate evidence, capture or cleanup fails the case; any missing/duplicate/failed required case fails the aggregate and release gate.
- Scope is software_stdout. No claim about ALSA reopens, real DAC clocks, audible quality, analog gapless or universal hardware support.
- Root handles docs/Git. No engine, runtime audio settings or dependency changes. Work branch codex/pcm-rate-switch-verification from merged main0ac8e42. Push/PR authorized; merge excluded.

## Review Focus

- A byte-identical capture accompanied by missing/reversed/extra engine rates must fail; cover both API and orchestration.
- A lost or duplicated frame and inserted zero frame at either rate boundary must fail without per-track alignment.
- Headerless stdout pacing must not masquerade as the track or DAC rate; assert capture.rate is None and pacing metadata separate.
- Numeric/edge-budget errors and report aliases must reject safely with exit2; legacy mixed-rate compare must still reject.
- Reusing evidence from a previous run or completing only a subset must not pass; retain unique-run aggregate tests.

### Task1: PCM sequence comparator

**Files:** tools/audio_verification.py; tests/audio-verification.py.
**Consumes:** existing _wav_info, _raw_info, _frames, _reference_frames, report-path guard and normalization.
**Produces:** compare_pcm_sequence API above and `compare-pcm-sequence` CLI with repeated --observed-rate, --max-lead-frames, --max-trailing-frames, --pacing-rate and existing capture/reference/report options.

- [x] Write RED tests using native PCM24 references44100/48000 and their exact signed32 concatenation; every ordered directed pair succeeds only with its matching rate_sequence.

```python
result = av.compare_pcm_sequence(refs, raw, capture_format="s32_le",
    rate_sequence=[44100,48000], max_lead_frames=3,
    max_trailing_frames=2, pacing_rate=44100)
assert result["status"] == "pass"
assert result["capture"]["rate"] is None
assert result["expected_rate_sequence"] == [44100,48000]
assert result["rate_sequence_match"] is True
```

- [x] Run `python3 tests/audio-verification.py` and record expected RED for the absent API/CLI, then implement the validated streaming sequence comparison and CLI. Preserve existing compare/DoP/DSD behavior.
- [x] Cover exact samples, damages in both tracks, boundary drop/duplication/pause, rate-evidence defects, bounded edge silence, explicit offsets, malformed arguments, mixed-depth normalization and CLI alias safety. Run the same full comparator suite GREEN; report commands/counts and any implementation decisions.

### Task2: Mixed-rate playback driver

**Files:** tests/prova-audio.py; tests/prova-audio-tests.py.
**Consumes:** Task1 API. **Produces:** six added cases, retained18cases, rate_evidence and explicit pacing metadata in reports; aggregate requires24complete successful cases.

- [x] Add RED orchestration cases that independently generate the actual WAV source headers and native raw frames at each rate; update expected matrix cardinality and exact directed pair set.

```python
pairs = {(44100,48000),(48000,44100),(44100,96000),
         (96000,44100),(48000,96000),(96000,48000)}
assert len(driver.CASES) == 24
assert {(case["rate"],case["second_rate"]) for case in driver.CASES
        if case.get("kind", "pcm") == "pcm_rate_transition"} == pairs
```

- [x] Run `python3 tests/prova-audio-tests.py` RED. Add optional second_rate to run_case, choose trackA from first fixture and trackB from second-rate fixture, command flags and validated exact ordered output-rate parser. Compute mixed budgets from WAV frames and pacing, call Task1 comparator, preserve failures and logs.
- [x] Test all six positive pairs and missing/wrong/reversed/duplicated/extra/malformed announcements plus damaged samples in either track, capture failure and incomplete aggregate. Run driver suite GREEN; save evidence.

### Task3: Integration, documentation and delivery

**Files:** README.md; docs/audio-verification.md; docs/daphile-parity.md; this plan.

- [x] Run fresh `sh tests/run.sh` in Ubuntu WSL: 245 passed, 30 failed, identical on a main-based worktree (UI/plugin checks needing host tools absent in WSL: shellcheck, xmllint, minisign). Python suites run separately: comparator and driver GREEN. CI test job is the authoritative run.
- [ ] Run complete `tests/prova-lyrion.sh` locally: not done (WSL sudo requires a password). The PR CI `lyrion` job runs the 24 cases on the x86 and ARM images; its artifacts are the evidence for this branch.
- [x] Document six rate pairs, command/comparison/evidence semantics, pacing and budgets; record CI16success and now-present audio artifacts separately from new local proof and pending new CI.
- [x] Final whole-branch review, UTF8/LF/diff checked, commit/push and PR opened. Record exact-head CI state in the PR; do not merge.
