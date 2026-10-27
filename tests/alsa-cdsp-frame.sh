#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sweetspot - alsa-cdsp: frame intero nella FIFO anche dopo un timeout.
# Estrae session_silence() dalla patch, la compila con gcc e la prova con un
# lettore fermo (tests/alsa-cdsp-frame.c). Esce con 0 se il test passa.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
awk '/^\+static int session_silence/ { f = 1 } f { print substr($0, 2) } f && /^\+}$/ { exit }' \
	"$ROOT/package/alsa-cdsp/0002-session-mode.patch" > "$D/session_silence.inc"
[ -s "$D/session_silence.inc" ] || { echo "session_silence non trovata nella patch" >&2; exit 1; }
gcc -Wall -I"$D" -o "$D/frame" "$ROOT/tests/alsa-cdsp-frame.c" || exit 1
"$D/frame"
