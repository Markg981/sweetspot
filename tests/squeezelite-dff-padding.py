#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the pinned Squeezelite header parser after applying our real patch.

Runs offline with a C compiler and Git. --unpatched is the negative control:
the odd-sized DSDIFF cases must fail against the unmodified upstream parser.
The fixture preserves upstream's parser, not a Python implementation of it.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/squeezelite-dsd-header.c"
PATCH = ROOT / "patches/squeezelite/0001-dsdiff-even-chunk-padding.patch"
UNPATCHED = False
# A literal interleaved stereo payload; header parsing must leave it untouched.
AUDIO = bytes.fromhex("6996a55a96695aa5") * 8


HARNESS = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <inttypes.h>

typedef uint8_t u8_t;
typedef uint32_t u32_t;
typedef uint64_t u64_t;
typedef int32_t s32_t;
typedef void dsd2pcm_ctx;
#define min(a, b) ((a) < (b) ? (a) : (b))
#define FMT_u64 "%" PRIu64

/* Only the byte buffer and log dependencies are stubbed. The parser itself
 * is the upstream C fixture, patched by Git before this file is compiled. */
struct buffer { u8_t *readp; unsigned used; };
static struct buffer input;
static struct buffer *streambuf = &input;
static unsigned _buf_used(struct buffer *b) { return b->used; }
static unsigned _buf_cont_read(struct buffer *b) { return b->used; }
static void _buf_inc_readp(struct buffer *b, unsigned count) {
    if (count > b->used) { fprintf(stderr, "buffer overread\n"); exit(2); }
    if (b->used >= 4) {
        fprintf(stderr, "advance=%u id=%02x%02x%02x%02x\n", count,
                b->readp[0], b->readp[1], b->readp[2], b->readp[3]);
    }
    b->readp += count;
    b->used -= count;
}
static u32_t unpackN(const void *ptr) {
    const u8_t *p = ptr;
    return (u32_t)p[0] << 24 | (u32_t)p[1] << 16 |
           (u32_t)p[2] << 8 | (u32_t)p[3];
}
static unsigned unpackn(const void *ptr) {
    const u8_t *p = ptr;
    return (unsigned)p[0] << 8 | (unsigned)p[1];
}
static void log_line(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt); vfprintf(stderr, fmt, args); va_end(args);
    fputc('\n', stderr);
}
#define LOG_INFO(...) log_line(__VA_ARGS__)
#define LOG_WARN(...) log_line(__VA_ARGS__)
#define LOG_DEBUG(...) log_line(__VA_ARGS__)

#include "dsd.c"

int main(int argc, char **argv) {
    FILE *file;
    long length;
    u8_t *data;
    unsigned fed = 0, partial_skips = 0, pad_only_skips = 0;
    int result = 0, next_fragment = 2;
    struct dsd state = {0};
    if (argc < 2 || !(file = fopen(argv[1], "rb"))) return 2;
    if (fseek(file, 0, SEEK_END) || (length = ftell(file)) < 0 ||
            length > 1024 * 1024 || fseek(file, 0, SEEK_SET)) return 2;
    data = malloc((size_t)length);
    if (!data || fread(data, 1, (size_t)length, file) != (size_t)length) return 2;
    fclose(file);
    d = &state;
    input.readp = data;
    input.used = 0;
    while (fed < (unsigned)length) {
        unsigned available = (unsigned)length - fed;
        unsigned fragment = next_fragment < argc ?
            (unsigned)strtoul(argv[next_fragment++], NULL, 10) : available;
        if (!fragment || fragment > available) return 2;
        fed += fragment;
        input.used += fragment;
        /* dsd_decode drains d->consume before calling _read_header again.
         * Reproduce that buffer boundary without invoking audio conversion. */
        if (d->consume) {
            unsigned skip = min(d->consume, input.used);
            partial_skips++;
            if (d->consume == 1) pad_only_skips++;
            _buf_inc_readp(streambuf, skip);
            d->consume -= skip;
            if (d->consume) continue;
        }
        result = _read_header();
        if (result) break;
    }
    printf("{\"result\":%d,\"type\":%u,\"rate\":%u,\"channels\":%u,"
           "\"sample_bytes\":%" PRIu64 ",\"offset\":%zu,\"remaining\":%u,"
           "\"consume\":%u,\"partial_skips\":%u,\"pad_only_skips\":%u,"
           "\"payload_prefix\":\"", result, (unsigned)d->type, d->sample_rate,
           d->channels, d->sample_bytes, (size_t)(input.readp - data), input.used,
           d->consume, partial_skips, pad_only_skips);
    for (unsigned i = 0; i < min(input.used, 8); i++) printf("%02x", input.readp[i]);
    puts("\"}");
    free(data);
    return 0;
}
'''


def dff_chunk(identifier, body):
    """DSDIFF 1.5 section 2.3: length excludes header and optional even pad."""
    return identifier + struct.pack(">Q", len(body)) + body + b"\0" * (len(body) % 2)


def dff(rate, name=b"not compressed", unknown=b"", cmpr_first=False):
    cmpr = dff_chunk(b"CMPR", b"DSD " + bytes([len(name)]) + name)
    fs = dff_chunk(b"FS  ", struct.pack(">I", rate))
    channels = dff_chunk(b"CHNL", b"\0\2SLFTSRGT")
    properties = cmpr + fs + channels if cmpr_first else fs + channels + cmpr
    body = (b"DSD " + dff_chunk(b"FVER", b"\1\5\0\0") + unknown +
            dff_chunk(b"PROP", b"SND " + properties) + dff_chunk(b"DSD ", AUDIO))
    return dff_chunk(b"FRM8", body)


def dsf(rate):
    # The DSF size includes its 12-byte header, with no DSDIFF padding rule.
    fmt = b"fmt " + struct.pack("<QIIIIIIQII", 52, 1, 0, 2, 2, rate, 1, 32768, 4096, 0)
    payload = AUDIO * 128  # Two valid 4096-byte channel blocks.
    return (b"DSD " + struct.pack("<QQQ", 28, 8284, 0) + fmt +
            b"data" + struct.pack("<Q", 8204) + payload)


class DsdHeaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="sweetspot-dff-header-")
        cls.work = Path(cls.temp.name)
        shutil.copyfile(FIXTURE, cls.work / "dsd.c")
        if not UNPATCHED:
            subprocess.run(["git", "apply", "--check", str(PATCH)], cwd=cls.work, check=True)
            subprocess.run(["git", "apply", str(PATCH)], cwd=cls.work, check=True)
        (cls.work / "harness.c").write_text(HARNESS, encoding="utf-8")
        cls.binary = cls.work / "dsd-header"
        subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
            "-std=c99", "-Wall", "-Wextra", "-Wno-sign-compare", "-Werror",
            str(cls.work / "harness.c"), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def parse(self, source, fragments=()):
        path = self.work / "input.bin"
        path.write_bytes(source)
        run = subprocess.run([str(self.binary), str(path), *map(str, fragments)],
                             text=True, capture_output=True, check=True)
        return json.loads(run.stdout), run.stderr

    def assert_audio(self, parsed, trace, rate, offset=130, kind=2, sample_bytes=64):
        self.assertEqual(parsed["result"], 1, trace)
        self.assertEqual(parsed["type"], kind)
        self.assertEqual(parsed["rate"], rate)
        self.assertEqual(parsed["channels"], 2)
        self.assertEqual(parsed["sample_bytes"], sample_bytes)
        self.assertEqual(parsed["offset"], offset)
        self.assertEqual(parsed["consume"], 0)
        self.assertEqual(parsed["payload_prefix"], "6996a55a96695aa5")

    def test_odd_cmpr_dsd64_reaches_audio(self):
        self.assert_audio(*self.parse(dff(2822400)), 2822400)

    def test_odd_cmpr_dsd128_reaches_audio(self):
        self.assert_audio(*self.parse(dff(5644800)), 5644800)

    def test_even_cmpr_does_not_skip_an_extra_byte(self):
        self.assert_audio(*self.parse(dff(2822400, name=b"raw DSD")), 2822400, offset=122)

    def test_odd_unknown_chunk_before_prop_is_skipped(self):
        source = dff(2822400, name=b"raw DSD", unknown=dff_chunk(b"JUNK", b"abcde"))
        self.assert_audio(*self.parse(source), 2822400, offset=140)

    def test_even_unknown_chunk_before_prop_is_skipped(self):
        source = dff(2822400, name=b"raw DSD", unknown=dff_chunk(b"JUNK", b"abcd"))
        self.assert_audio(*self.parse(source), 2822400, offset=138)

    def test_odd_nested_cmpr_keeps_following_fs_and_chnl_aligned(self):
        self.assert_audio(*self.parse(dff(5644800, cmpr_first=True)), 5644800)

    def test_partial_odd_cmpr_skip_resumes_at_the_audio_header(self):
        parsed, trace = self.parse(dff(2822400), fragments=(100, 8, 8, 16))
        self.assert_audio(parsed, trace, 2822400)
        self.assertGreater(parsed["partial_skips"], 0)

    def test_padding_arriving_alone_is_consumed_before_the_next_header(self):
        # Offset 117 is the end of the 19-byte CMPR body, just before its pad.
        parsed, trace = self.parse(dff(5644800), fragments=(117, 1))
        self.assert_audio(parsed, trace, 5644800)
        self.assertEqual(parsed["pad_only_skips"], 1)

    def test_dsf_dsd64_keeps_its_existing_chunk_sizes(self):
        self.assert_audio(*self.parse(dsf(2822400)), 2822400, offset=92, kind=1,
                          sample_bytes=4096)

    def test_dsf_dsd128_keeps_its_existing_chunk_sizes(self):
        self.assert_audio(*self.parse(dsf(5644800)), 5644800, offset=92, kind=1,
                          sample_bytes=4096)


if __name__ == "__main__":
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("--unpatched", action="store_true", help="run the RED negative control")
    options, remaining = arguments.parse_known_args()
    UNPATCHED = options.unpatched
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
