#!/bin/bash
# Prove CamillaDSP is applying the room correction filter, and applying it
# correctly, by running the *installed* config offline.
#
# An impulse convolved with a filter is the filter, so this feeds a unit impulse
# through the same filters/mixers/pipeline the live path uses and compares the
# result sample by sample against the impulse response file itself. It also
# checks the mixer, by confirming outputs 3 and 4 stay silent.
#
# Only the `devices:` block is swapped, for file in / file out — everything
# below it is taken verbatim from the installed config, so this cannot pass
# while the real pipeline differs.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

CONFIG="${CONFIG:-/etc/camilladsp/roomcorr.yaml}"
IR="${IR:-/etc/camilladsp/Test900.wav}"
CAMILLADSP="${CAMILLADSP:-/usr/local/bin/camilladsp}"
RATE=96000
TAPS=32768
FRAMES=$((TAPS * 2))          # room for the whole tail
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f $CONFIG ]] || { echo "no such config: $CONFIG" >&2; exit 1; }
[[ -f $IR ]] || { echo "no such impulse response: $IR" >&2; exit 1; }

echo "config: $CONFIG"
echo "filter: $IR"

# --- input: a unit impulse on both channels ---------------------------------
# 0.5 full scale, so that even a filter with 0 dB gain cannot clip the output.
python3 - "$WORK/in.raw" "$FRAMES" <<'PY'
import array, sys
path, frames = sys.argv[1], int(sys.argv[2])
a = array.array('i', [0]) * (frames * 2)
a[0] = a[1] = 2**30          # 0.5 of full scale, both channels
open(path, 'wb').write(a.tobytes())
PY

# --- config: the installed one, with file devices ---------------------------
{
	cat <<EOF
devices:
  samplerate: $RATE
  chunksize: 4096
  queuelimit: 4
  capture:
    type: RawFile
    channels: 2
    filename: "$WORK/in.raw"
    format: S32LE
    extra_samples: $TAPS
  playback:
    type: File
    channels: 4
    filename: "$WORK/out.raw"
    format: S32LE
EOF
	# Everything from `filters:` onwards, verbatim from the live config.
	sed -n '/^filters:/,$p' "$CONFIG"
} > "$WORK/offline.yaml"

grep -q '^filters:' "$WORK/offline.yaml" ||
	{ echo "could not find a 'filters:' section in $CONFIG" >&2; exit 1; }

"$CAMILLADSP" "$WORK/offline.yaml" -l error

# --- compare ----------------------------------------------------------------
python3 - "$WORK/out.raw" "$IR" <<'PY'
import array, struct, sys, math

out_path, ir_path = sys.argv[1], sys.argv[2]

raw = open(ir_path, 'rb').read()
i = 12
while i < len(raw):
    cid, sz = raw[i:i+4], struct.unpack('<I', raw[i+4:i+8])[0]
    if cid == b'data':
        off, size = i + 8, sz
        break
    i += 8 + sz + (sz & 1)
ir = array.array('f'); ir.frombytes(raw[off:off+size])
ir_ch = [ir[0::2], ir[1::2]]
taps = len(ir_ch[0])

o = array.array('i'); o.frombytes(open(out_path, 'rb').read())
out = [o[c::4] for c in range(4)]
print('output: %d frames, 4 channels' % len(out[0]))

# The impulse went in at sample 0, but the pipeline may emit a leading chunk of
# silence; find the offset from the strongest sample and check both channels
# agree on it.
def peak_index(x):
    return max(range(len(x)), key=lambda k: abs(x[k]))
offsets = []
for c in (0, 1):
    offsets.append(peak_index(out[c]) - peak_index(ir_ch[c]))
if offsets[0] != offsets[1]:
    print('FAIL: channels disagree on alignment: %r' % offsets); sys.exit(1)
off = offsets[0]
print('pipeline delay: %d samples (%.1f ms)' % (off, off * 1000.0 / 96000))

fail = 0
for c in (0, 1):
    n = min(taps, len(out[c]) - off)
    worst = 0.0; worst_at = -1
    energy = 0.0
    for k in range(n):
        got = out[c][off + k] / 2**31
        want = ir_ch[c][k] * 0.5          # the impulse was at 0.5 full scale
        e = abs(got - want)
        energy += want * want
        if e > worst:
            worst, worst_at = e, k
    rms = math.sqrt(energy / n)
    # 24-bit output quantises at 2^-24 = 6e-8; allow a couple of LSBs.
    ok = worst < 5e-7
    print('channel %d: %d taps compared, worst error %.2e at tap %d '
          '(filter RMS %.4f) -> %s'
          % (c, n, worst, worst_at, rms, 'ok' if ok else 'FAIL'))
    if not ok:
        fail = 1

for c in (2, 3):
    mx = max(abs(v) for v in out[c])
    ok = mx == 0
    print('channel %d: silent (max |sample| = %d) -> %s' % (c, mx, 'ok' if ok else 'FAIL'))
    if not ok:
        fail = 1

print('\n%s' % ('convolution verified' if not fail else 'MISMATCH'))
sys.exit(fail)
PY
