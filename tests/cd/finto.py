#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - lettore CD e servizi in rete finti per provare la copia dei CD
# senza un lettore vero: un disco di 4 tracce con audio casuale, letto da un
# lettore con correzione (offset) di +48 campioni, piu' le risposte di
# MusicBrainz, della copertina e del database AccurateRip calcolate sullo
# stesso audio.
#
#   finto.py cd-paranoia ARGOMENTI...     come cd-paranoia
#   finto.py curl ARGOMENTI...            come curl
import os, random, struct, sys, hashlib, base64, json

SECTOR = 588
TRACKS = [300, 420, 360, 240]          # settori
DRIVE_OFFSET = 48                      # campioni
# Copertina: un JPEG 8x8 valido
JPEG = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDIooorkPoT/9k='
random.seed(1234)
TOTAL = sum(TRACKS) * SECTOR
PAD = 4000
# Audio "vero" del disco, con un margine di silenzio prima e dopo
DISC = [0] * PAD + [random.getrandbits(32) for _ in range(TOTAL)] + [0] * PAD

def begins():
    b, out = 0, []
    for t in TRACKS:
        out.append(b); b += t
    return out, b

def read(sample_from, count, corr):
    # Il lettore restituisce l'audio spostato del suo offset: con la
    # correzione corr giusta (= DRIVE_OFFSET) si ottiene quello vero.
    out = []
    for x in range(sample_from, sample_from + count):
        i = x + corr - DRIVE_OFFSET + PAD
        out.append(DISC[i] if 0 <= i < len(DISC) else 0)
    return out

def write_wav(path, samples):
    data = b''.join(struct.pack('<I', s) for s in samples)
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE')
        f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 2, 44100, 176400, 4, 16))
        f.write(b'data' + struct.pack('<I', len(data)) + data)

def parse_time(t):       # [mm:ss.ff] -> settori
    t = t.strip('[]')
    m, rest = t.split(':'); s, f = rest.split('.')
    return (int(m) * 60 + int(s)) * 75 + int(f)

def cd_paranoia(args):
    b, lead = begins()
    if '-Q' in args:
        sys.stderr.write('Table of contents (audio tracks only):\ntrack        length               begin        copy pre ch\n'
                         '===========================================================\n')
        for i, (bb, ln) in enumerate(zip(b, TRACKS), 1):
            sys.stderr.write('%3d.  %7d [00:00.00]  %7d [00:00.00]    no   no  2\n' % (i, ln, bb))
        sys.stderr.write('TOTAL  %7d [00:00.00]    (audio only)\n' % lead)
        return 0
    corr = 0
    if '-O' in args:
        corr = int(args[args.index('-O') + 1])
    out = args[-1]; span = args[-2]
    if span.startswith('['):
        s, e = span.split('-')
        s, e = parse_time(s), parse_time(e)
        write_wav(out, read(s * SECTOR, (e - s + 1) * SECTOR, corr))
    else:
        t = int(span)
        write_wav(out, read(b[t - 1] * SECTOR, TRACKS[t - 1] * SECTOR, corr))
    return 0

def ar_crc(samples, first, last):
    n = len(samples); frm, to = 1, n
    if first: frm += SECTOR * 5 - 1
    if last: to -= SECTOR * 5
    v1 = 0
    for i, x in enumerate(samples):
        m = i + 1
        if frm <= m <= to: v1 = (v1 + m * x) & 0xffffffff
    return v1

def curl(args):
    url = [a for a in args if a.startswith('http')][-1]
    out = args[args.index('-o') + 1] if '-o' in args else None
    b, lead = begins()
    if 'musicbrainz.org' in url:
        discid = url.split('/discid/')[1].split('?')[0]
        rel = {'releases': [{'id': 'f00d-cafe', 'title': 'Prova di copia: "Sinfonia" n.1', 'date': '1999-05-01',
               'artist-credit': [{'name': 'Orchestra Finta', 'joinphrase': ''}],
               'media': [{'position': 1, 'discs': [{'id': discid}],
                          'tracks': [{'position': i, 'title': 'Movimento %d' % i,
                                      'artist-credit': [{'name': 'Orchestra Finta'}]} for i in range(1, 5)]}]}]}
        print(json.dumps(rel)); return 0
    if 'coverartarchive.org' in url:
        open(out, 'wb').write(base64.b64decode(JPEG)); return 0
    if 'accuraterip.com' in url:
        n = len(TRACKS)
        chunk = bytes([n]) + b'\0' * 12
        for i, (bb, ln) in enumerate(zip(b, TRACKS), 1):
            true = DISC[PAD + bb * SECTOR: PAD + (bb + ln) * SECTOR]
            chunk += bytes([9]) + struct.pack('<I', ar_crc(true, i == 1, i == n)) + b'\0\0\0\0'
        open(out, 'wb').write(chunk); return 0
    return 22

if __name__ == '__main__':
    tool = sys.argv[1]
    sys.exit(cd_paranoia(sys.argv[2:]) if tool == 'cd-paranoia' else curl(sys.argv[2:]))
