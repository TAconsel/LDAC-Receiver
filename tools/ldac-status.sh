#!/bin/bash
# What the LDAC receiver is actually doing right now: which codecs it offers,
# what a connected sender picked, and the rate and format the sound card is
# really running at.
#
# SPDX-License-Identifier: MIT

set -uo pipefail

CARD="${CARD:-U192k}"
BLUEALSACTL="${BLUEALSACTL:-/usr/local/bin/bluealsactl}"

hdr() { printf '\n\033[1m-- %s\033[0m\n' "$*"; }

hdr "services"
for u in bluetooth bluealsa bluealsa-aplay bt-agent bluetooth-sink-setup; do
	printf '  %-24s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
done

hdr "adapter"
btmgmt info 2>/dev/null | sed -n '/^hci/,/^$/p' | sed 's/^/  /'

hdr "codecs offered to senders"
# LDAC appears on the A2DP-sink line only if BlueALSA found an LDAC decoder at
# build time: codec_has_direction() tests the codec's decode callback before
# registering a sink endpoint, so an encode-only build offers SBC/AAC alone.
if status=$("$BLUEALSACTL" status 2>/dev/null); then
	echo "$status" | sed -n '/^Profiles:/,$p' | tail -n +2 | sed 's/^ */  /'
	echo "$status" | grep -q 'A2DP-sink.*LDAC' ||
		echo "  !! LDAC missing from A2DP-sink — senders will only be offered SBC/AAC"
else
	echo "  (BlueALSA not running)"
fi

hdr "connected streams"
pcms=$("$BLUEALSACTL" list-pcms 2>/dev/null | grep -i 'sink\|source' || true)
if [[ -z $pcms ]]; then
	echo "  (nothing connected)"
else
	for p in $pcms; do
		echo "  $p"
		"$BLUEALSACTL" info "$p" 2>/dev/null |
			grep -iE 'device|codec|rate|channels|format|selected|transport|running' |
			sed 's/^/    /'
	done
fi

hdr "AVDTP MTU fix"
# The MTU this box advertises for the media channel is also the sender's
# outgoing MTU. Sony's LDAC encoder refuses to start below 679 bytes, so at
# BlueZ's 672-byte default a sender cannot stream LDAC to us however well the
# decoder works: it negotiates LDAC, reports the transport active, and sends
# nothing. patches/bluez-a2dp-imtu.patch raises it to 1024.
if pgrep -af 'bluetoothd' | grep -q /usr/local/libexec/bluetooth/bluetoothd; then
	echo "  patched bluetoothd in use (AVDTP IMTU 1024)"
else
	echo "  !! stock bluetoothd in use — AVDTP IMTU is 672 and LDAC will stay silent"
fi
# Only debug builds of BlueALSA log the negotiated value.
journalctl -u bluealsa -b --no-pager 2>/dev/null |
	sed -n 's/.*\(Media transport socket MTU.*\)/  \1/p' | tail -1

hdr "sound card"
hw=$(echo /proc/asound/card*/pcm0p/sub0/hw_params)
for f in $hw; do
	c=${f#/proc/asound/}; c=${c%%/*}
	[[ -r $f ]] || continue
	if grep -q closed "$f" 2>/dev/null; then
		printf '  %s: closed (nothing playing)\n' "$c"
	else
		printf '  %s:\n' "$c"
		sed 's/^/    /' "$f"
	fi
done

hdr "output volume"
amixer -c "$CARD" sget 'UMC404HD 192k Output' 2>/dev/null |
	grep -E 'Front Left:|Front Right:' | sed 's/^/  /' || echo "  (no such control)"

echo
