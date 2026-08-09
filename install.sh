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

# Room correction. IR is a WAV holding one impulse response per channel at the
# playback rate; see config/camilladsp-roomcorr.yaml.
IR="${IR:-$HERE/Test900.wav}"
CDSP_DIR=/etc/camilladsp
ALSA_CDSP_SRC="${ALSA_CDSP_SRC:-$HOME/alsa_cdsp}"
ALSA_CDSP_REPO="https://github.com/scripple/alsa_cdsp.git"
# v4 needs glibc 2.34; bullseye has 2.31. v3.0.1 is the newest that runs here.
CAMILLADSP_VERSION="${CAMILLADSP_VERSION:-v3.0.1}"

# Control panel.  bullseye only has Node 12, which is long out of support, so a
# current LTS is installed alongside it the same way as CamillaDSP.
NODE_VERSION="${NODE_VERSION:-v24.19.0}"
WEB_USER=ldacweb
WEB_DIR=/usr/local/share/ldac-web
DEFAULTS=/etc/default/ldac-receiver

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
		bt-agent.service bluetooth-sink-setup.service ldac-web.service \
		2>/dev/null || true

	say "Removing the control panel"
	sudo rm -rf "$WEB_DIR" /etc/sudoers.d/ldac-web /usr/local/sbin/ldac-ctl \
		"$DEFAULTS"
	id -u "$WEB_USER" >/dev/null 2>&1 && sudo userdel "$WEB_USER" || true

	say "Removing configuration"
	sudo rm -rf /etc/systemd/system/bluealsa.service.d \
		/etc/systemd/system/bluealsa-aplay.service.d \
		/etc/systemd/system/bluetooth.service.d/override.conf \
		/etc/systemd/system/bt-agent.service \
		/etc/systemd/system/bluetooth-sink-setup.service \
		/etc/systemd/system/ldac-web.service
	sudo rm -f /etc/asound.conf
	# Back to the distribution bluetoothd.
	sudo rm -f /usr/local/libexec/bluetooth/bluetoothd

	say "Removing room correction"
	sudo rm -rf "$CDSP_DIR"
	sudo rm -f /usr/local/bin/camilladsp
	[[ -d $ALSA_CDSP_SRC ]] && sudo make -C "$ALSA_CDSP_SRC" uninstall || true
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

# --- room correction --------------------------------------------------------
# snd-aloop is absent from this board's BSP kernel, so the audio does not reach
# CamillaDSP through a loopback device.  The alsa_cdsp plugin instead presents
# itself to BlueALSA as an ALSA device, starts CamillaDSP when the device is
# opened, and pipes the audio to its stdin; CamillaDSP owns the sound card from
# there.  Nothing kernel-side is involved.
say "Installing CamillaDSP $CAMILLADSP_VERSION"
if ! command -v camilladsp >/dev/null ||
		[[ $(camilladsp --version 2>/dev/null) != *"${CAMILLADSP_VERSION#v}"* ]]; then
	tmp=$(mktemp -d)
	curl -fsSL -o "$tmp/cdsp.tar.gz" \
		"https://github.com/HEnquist/camilladsp/releases/download/$CAMILLADSP_VERSION/camilladsp-linux-aarch64.tar.gz" ||
		die "couldn't download CamillaDSP $CAMILLADSP_VERSION"
	tar xzf "$tmp/cdsp.tar.gz" -C "$tmp"
	sudo install -m 0755 "$tmp/camilladsp" /usr/local/bin/camilladsp
	rm -rf "$tmp"
fi
# Newer releases are built against a glibc this distribution does not have, and
# fail at exec with "GLIBC_2.34 not found" rather than anything more helpful.
camilladsp --version >/dev/null 2>&1 ||
	die "the CamillaDSP binary will not run here; check 'camilladsp --version'
       (releases after v3.0.1 need glibc 2.34, this system has $(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$'))"

say "Building the alsa_cdsp plugin"
[[ -d $ALSA_CDSP_SRC ]] || git clone --depth 1 "$ALSA_CDSP_REPO" "$ALSA_CDSP_SRC"
make -C "$ALSA_CDSP_SRC" -j"$(nproc)"
sudo make -C "$ALSA_CDSP_SRC" install

say "Installing the room correction filter"
[[ -f $IR ]] || die "impulse response not found: $IR"
sudo install -d "$CDSP_DIR"
sudo install -m 0644 "$IR" "$CDSP_DIR/$(basename "$IR")"
sudo install -m 0644 "$HERE/config/camilladsp-roomcorr.yaml" "$CDSP_DIR/roomcorr.yaml"
camilladsp -c "$CDSP_DIR/roomcorr.yaml" >/dev/null 2>&1 ||
	die "CamillaDSP rejected $CDSP_DIR/roomcorr.yaml; run
       'camilladsp -c $CDSP_DIR/roomcorr.yaml' to see why"

# --- control panel ----------------------------------------------------------
say "Installing Node $NODE_VERSION"
if ! command -v node >/dev/null || [[ $(node --version 2>/dev/null) != "$NODE_VERSION" ]]; then
	tmp=$(mktemp -d)
	curl -fsSL -o "$tmp/node.tar.xz" \
		"https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-arm64.tar.xz" ||
		die "couldn't download Node $NODE_VERSION"
	tar xf "$tmp/node.tar.xz" -C "$tmp"
	# The panel has no dependencies and never needs npm, so only the runtime
	# is installed.
	sudo install -m 0755 "$tmp/node-$NODE_VERSION-linux-arm64/bin/node" /usr/local/bin/node
	rm -rf "$tmp"
fi
node --version >/dev/null 2>&1 || die "the Node binary will not run here"

say "Installing the control panel"
# A system account with no home and no shell: it only ever runs the panel.
id -u "$WEB_USER" >/dev/null 2>&1 ||
	sudo useradd --system --no-create-home --home-dir /nonexistent \
		--shell /usr/sbin/nologin "$WEB_USER"

# The privileged half.  Must stay root-owned and not writable by the panel's
# user, since sudo lets that user run it as root.
sudo install -m 0755 -o root -g root "$HERE/sbin/ldac-ctl" /usr/local/sbin/ldac-ctl

sudo install -d "$WEB_DIR/public"
sudo install -m 0644 "$HERE/web/server.js" "$WEB_DIR/server.js"
sudo install -m 0644 "$HERE/web/public/index.html" "$WEB_DIR/public/index.html"

# visudo -c on a copy first: a malformed sudoers file can lock the machine out
# of sudo entirely.
tmp_sudoers=$(mktemp)
cp "$HERE/config/sudoers-ldac-web" "$tmp_sudoers"
sudo visudo -cqf "$tmp_sudoers" || { rm -f "$tmp_sudoers"; die "sudoers snippet is invalid"; }
sudo install -m 0440 -o root -g root "$tmp_sudoers" /etc/sudoers.d/ldac-web
rm -f "$tmp_sudoers"

# Runtime state.  Never overwritten: it holds the choices made in the panel.
if [[ -f $DEFAULTS ]]; then
	echo "keeping existing $DEFAULTS"
else
	sudo install -m 0644 "$HERE/config/ldac-receiver.defaults" "$DEFAULTS"
fi

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
	"$HERE/config/bluetooth-sink-setup.service" \
	"$HERE/config/ldac-web.service" /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl restart bluetooth.service
sudo systemctl enable --now bluetooth-sink-setup.service bt-agent.service \
	bluealsa.service bluealsa-aplay.service ldac-web.service
sudo systemctl restart bluealsa.service bluealsa-aplay.service ldac-web.service

# --- verify -----------------------------------------------------------------
say "Verifying"
sleep 2
fail=0
for u in bluetooth bluealsa bluealsa-aplay bt-agent ldac-web; do
	if systemctl is-active --quiet "$u"; then
		printf '  %-22s active\n' "$u"
	else
		printf '  %-22s NOT ACTIVE\n' "$u"; fail=1
	fi
done

# Runs the installed config offline and checks that an impulse comes back out as
# the filter, so a silently mis-wired DSP path is caught here rather than by ear.
say "Verifying the room correction"
"$HERE/tools/verify-convolution.sh" | tail -6

"$HERE/tools/ldac-status.sh" || true

[[ $fail -eq 0 ]] || die "some services did not start; see 'journalctl -u <name> -b'"

cat <<EOF

Ready.  Pair from the sending device — this box is discoverable as
"$(hostname)".  Then check what it negotiated with:

    tools/ldac-status.sh

Control panel: http://$(hostname -I | awk '{print $1}'):8080/
  room correction on/off, discoverable on/off, and paired clients.
  It has no password; see "Control panel" in README.md if that is not what
  you want on your network.
EOF
