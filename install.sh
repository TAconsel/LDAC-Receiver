#!/bin/bash
# Turn this machine into a Bluetooth LDAC receiver (A2DP sink) that plays into
# a USB audio interface at 24-bit/96 kHz.  See README.md.
#
# Run as your normal user, not with sudo — it escalates only where needed.
#
#   ./install.sh              full install
#   ./install.sh --build-only build and self-test, change nothing on the system
#   ./install.sh --uninstall  undo it
#
# SPDX-License-Identifier: MIT

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLUEZALSA_SRC="${BLUEZALSA_SRC:-$HOME/bluez-alsa}"
BLUEZALSA_REPO="https://github.com/arkq/bluez-alsa.git"
LDACDEC_REPO="https://github.com/hegdi/libldacdec.git"

# BlueZ is rebuilt from the matching upstream release with one patch; see
# patches/bluez-a2dp-imtu.patch for why LDAC cannot work without it.
BLUEZ_SRC="${BLUEZ_SRC:-$HOME/bluez-build}"
BLUEZ_TARBALL_URL="https://www.kernel.org/pub/linux/bluetooth"

# The card and its mixer control, as they appear in /proc/asound/cards and
# `amixer controls`.  Override if the interface is a different one; the PCM
# definitions in config/asound.conf name the card too.
CARD="${CARD:-U192k}"

PREFIX=/usr/local
DEC_INCLUDEDIR="$PREFIX/include/ldac-dec"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

[[ ${EUID} -ne 0 ]] || die "run this as your normal user, not with sudo"
sudo -n true 2>/dev/null || sudo true || die "this needs sudo"

MODE=install
case "${1:-}" in
	--build-only) MODE=build ;;
	--uninstall)  MODE=uninstall ;;
	"")           ;;
	*)            die "unknown option: $1" ;;
esac

# --- uninstall --------------------------------------------------------------
if [[ $MODE == uninstall ]]; then
	say "Stopping and disabling services"
	sudo systemctl disable --now bluealsa-aplay.service bluealsa.service \
		bt-agent.service bluetooth-sink-setup.service 2>/dev/null || true

	say "Removing configuration"
	sudo rm -rf /etc/systemd/system/bluealsa.service.d \
		/etc/systemd/system/bluealsa-aplay.service.d \
		/etc/systemd/system/bluetooth.service.d/override.conf \
		/etc/systemd/system/bt-agent.service \
		/etc/systemd/system/bluetooth-sink-setup.service
	sudo rm -f /etc/asound.conf
	# Back to the distribution bluetoothd.
	sudo rm -f /usr/local/libexec/bluetooth/bluetoothd
	sudo systemctl daemon-reload
	sudo systemctl restart bluetooth || true

	say "Removing libldacBT_dec"
	sudo make -C "$HERE" uninstall || true

	say "Re-enabling PulseAudio"
	systemctl --user unmask pulseaudio.service pulseaudio.socket 2>/dev/null || true

	echo
	echo "Done.  BlueALSA itself is left installed; remove it with"
	echo "  sudo make -C $BLUEZALSA_SRC uninstall"
	exit 0
fi

# --- dependencies -----------------------------------------------------------
say "Installing build and runtime dependencies"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
	build-essential g++ pkg-config autoconf automake libtool git \
	libasound2-dev libbluetooth-dev libdbus-1-dev libglib2.0-dev libsbc-dev \
	libldacbt-enc-dev libldacbt-abr-dev libfdk-aac-dev python3-docutils \
	bluez bluez-tools alsa-utils \
	libudev-dev libical-dev libreadline-dev curl xz-utils

# --- the decoder ------------------------------------------------------------
# BlueALSA's A2DP Sink LDAC path is compiled only when pkg-config finds
# ldacBT-dec.  Sony never released an LDAC decoder, so this builds one from
# libldacdec behind Sony's API.  See src/ldacBT_dec.c.
say "Building libldacBT_dec"
[[ -d "$HERE/build/libldacdec" ]] || git clone --depth 1 "$LDACDEC_REPO" "$HERE/build/libldacdec"
make -C "$HERE" -j"$(nproc)"

say "Self-testing the decoder"
# Refuses to go further if the decoder cannot reproduce real LDAC frames: it
# round-trips a tone through Sony's encoder at every LDAC sample rate.
make -C "$HERE" test

if [[ $MODE == build ]]; then
	echo
	echo "Build and self-test passed.  Nothing was installed."
	exit 0
fi

say "Installing libldacBT_dec"
sudo make -C "$HERE" install
pkg-config --exists 'ldacBT-dec >= 2.0.0' || die "ldacBT-dec.pc did not install correctly"

# --- BlueALSA ---------------------------------------------------------------
say "Building BlueALSA"
[[ -d "$BLUEZALSA_SRC" ]] || git clone --depth 1 "$BLUEZALSA_REPO" "$BLUEZALSA_SRC"
cd "$BLUEZALSA_SRC"
[[ -x ./configure ]] || autoreconf --install

# CPPFLAGS, not just the .pc file: ldacBT-abr.pc and ldacBT-enc.pc both put
# -I/usr/include/ldac on the command line ahead of ldacBT-dec.pc's Cflags, so
# the encoder-only ldacBT.h would otherwise win and hide the decode prototypes.
# automake emits $(CPPFLAGS) before the per-target CFLAGS that carry pkg-config
# flags, so this reliably takes precedence.  See src/include/ldacBT.h.
./configure --prefix="$PREFIX" --sysconfdir=/etc \
	--enable-ldac --enable-aac --enable-systemd --enable-manpages \
	--with-systemdsystemunitdir=/etc/systemd/system \
	CPPFLAGS="-I$DEC_INCLUDEDIR"

grep -q '^#define HAVE_LDAC_DECODE 1' config.h || \
	die "BlueALSA did not pick up the LDAC decoder; without it the A2DP Sink
       will only ever offer SBC and AAC.  Check 'pkg-config --modversion ldacBT-dec'."

make -j"$(nproc)"
sudo make install
sudo ldconfig
cd "$HERE"

# --- BlueZ ------------------------------------------------------------------
# Without this LDAC is negotiated but never streams: BlueZ advertises the 672
# byte L2CAP default for AVDTP, and Sony's encoder refuses to start below 679,
# so the *sender* silently fails while the transport still looks active.
# patches/bluez-a2dp-imtu.patch has the details.
say "Building BlueZ with the AVDTP MTU fix"
BLUEZ_VERSION="$(bluetoothctl --version | awk '{print $2}')"
[[ -n $BLUEZ_VERSION ]] || die "couldn't determine the installed BlueZ version"
echo "matching the installed BlueZ $BLUEZ_VERSION"

BLUEZ_DIR="$BLUEZ_SRC/bluez-$BLUEZ_VERSION"
if [[ ! -d $BLUEZ_DIR ]]; then
	mkdir -p "$BLUEZ_SRC"
	curl -fsSL "$BLUEZ_TARBALL_URL/bluez-$BLUEZ_VERSION.tar.xz" \
		-o "$BLUEZ_SRC/bluez-$BLUEZ_VERSION.tar.xz" ||
		die "couldn't download BlueZ $BLUEZ_VERSION source"
	tar xf "$BLUEZ_SRC/bluez-$BLUEZ_VERSION.tar.xz" -C "$BLUEZ_SRC"
	patch -d "$BLUEZ_DIR" -p1 < "$HERE/patches/bluez-a2dp-imtu.patch" ||
		die "patches/bluez-a2dp-imtu.patch does not apply to BlueZ $BLUEZ_VERSION;
       check whether upstream now sets BT_IO_OPT_IMTU in profiles/audio/a2dp.c"
fi

cd "$BLUEZ_DIR"
# Only bluetoothd is wanted, so everything else is switched off to keep the
# build short. It installs alongside the packaged binary, never over it.
[[ -f config.status ]] || ./configure --prefix=/usr/local \
	--libexecdir=/usr/local/libexec --sysconfdir=/etc --localstatedir=/var \
	--disable-manpages --disable-systemd --disable-obex --disable-cups \
	--disable-monitor --disable-client --disable-tools --disable-testing
make -j"$(nproc)" src/builtin.h        # generated; the bluetoothd rule needs it
make -j"$(nproc)" src/bluetoothd
sudo install -d /usr/local/libexec/bluetooth
sudo install -m 0755 src/bluetoothd /usr/local/libexec/bluetooth/bluetoothd
cd "$HERE"

# --- sound output -----------------------------------------------------------
say "Configuring ALSA output at 24-bit/96 kHz"
# `aplay -l` prints the card id before the brackets: "card 1: U192k [UMC404HD ...]"
aplay -l | grep -qE "^card [0-9]+: $CARD \[" || \
	die "sound card '$CARD' not found; check 'aplay -l'"
sudo install -m 0644 "$HERE/config/asound.conf" /etc/asound.conf

# PulseAudio registers its own A2DP endpoints with BlueZ and would compete with
# BlueALSA for them, and would also hold the sound card.  This box is a headless
# appliance, so it is masked rather than reconfigured.
say "Disabling PulseAudio"
systemctl --user stop pulseaudio.service pulseaudio.socket 2>/dev/null || true
systemctl --user mask pulseaudio.service pulseaudio.socket 2>/dev/null || true

# --- Bluetooth --------------------------------------------------------------
say "Configuring BlueZ"
# Class of device: Audio+Rendering service, Audio/Video major, HiFi Audio minor.
# Senders use this to decide what icon to show and, on some stacks, whether to
# offer a device an audio profile at all.
set_bluez_opt() {
	local key=$1 val=$2 f=/etc/bluetooth/main.conf
	if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$f"; then
		sudo sed -i -E "0,/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*/s//${key} = ${val}/" "$f"
	else
		sudo sed -i "0,/^\[General\]/s//[General]\n${key} = ${val}/" "$f"
	fi
}
set_bluez_opt Class 0x240414
set_bluez_opt DiscoverableTimeout 0
set_bluez_opt PairableTimeout 0

say "Installing services"
sudo install -d /etc/systemd/system/bluealsa.service.d \
	/etc/systemd/system/bluealsa-aplay.service.d \
	/etc/systemd/system/bluetooth.service.d
sudo install -m 0644 "$HERE/config/bluealsa.service.d-override.conf" \
	/etc/systemd/system/bluealsa.service.d/override.conf
sudo install -m 0644 "$HERE/config/bluealsa-aplay.service.d-override.conf" \
	/etc/systemd/system/bluealsa-aplay.service.d/override.conf
sudo install -m 0644 "$HERE/config/bluetooth.service.d-override.conf" \
	/etc/systemd/system/bluetooth.service.d/override.conf
sudo install -m 0644 "$HERE/config/bt-agent.service" \
	"$HERE/config/bluetooth-sink-setup.service" /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl restart bluetooth.service
sudo systemctl enable --now bluetooth-sink-setup.service bt-agent.service \
	bluealsa.service bluealsa-aplay.service
sudo systemctl restart bluealsa.service bluealsa-aplay.service

# --- verify -----------------------------------------------------------------
say "Verifying"
sleep 2
fail=0
for u in bluetooth bluealsa bluealsa-aplay bt-agent; do
	if systemctl is-active --quiet "$u"; then
		printf '  %-22s active\n' "$u"
	else
		printf '  %-22s NOT ACTIVE\n' "$u"; fail=1
	fi
done

"$HERE/tools/ldac-status.sh" || true

[[ $fail -eq 0 ]] || die "some services did not start; see 'journalctl -u <name> -b'"

cat <<EOF

Ready.  Pair from the sending device — this box is discoverable as
"$(hostname)".  Then check what it negotiated with:

    tools/ldac-status.sh
EOF
