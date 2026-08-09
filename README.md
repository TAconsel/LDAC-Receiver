# Bluetooth LDAC receiver for the Radxa Cubie A7S

Turns the board into an A2DP **sink** that accepts LDAC and plays it out of a USB
audio interface at **24-bit / 96 kHz**.

Verified on a Radxa Cubie A7S (Allwinner A733, Debian 11 bullseye, aarch64,
BlueZ 5.55, AIC8800D80 Bluetooth) with a Behringer UMC404HD, receiving from a
PipeWire 1.6.2 sender.

```
sender ──LDAC/A2DP──▶ bluealsad ──▶ libldacBT_dec ──▶ ALSA "ldac96" ──▶ UMC404HD
                      (A2DP sink)   (libldacdec)      plug + route      24-bit/96 kHz
```

## Install

```sh
./install.sh
```

Run it as your normal user, not with `sudo` — it escalates only where needed.

| Flag | Effect |
| --- | --- |
| `--build-only` | build and self-test the decoder, change nothing on the system |
| `--uninstall` | undo everything |

Then pair — see [Pairing](#pairing) — and check what was negotiated with
`tools/ldac-status.sh`.

## Why three things have to be built

**1. There is no LDAC decoder.** Sony open sourced the LDAC *encoder* only, so
distributions ship `libldacbt-enc2` and nothing for the other direction.
BlueALSA already contains a complete A2DP-sink decode thread in
`src/a2dp-ldac.c`, but it is compiled only when `configure` finds a
`ldacBT-dec` pkg-config module, which does not exist. `src/ldacBT_dec.c` here is
that missing library: Sony's two decode entry points implemented on top of
[hegdi/libldacdec](https://github.com/hegdi/libldacdec), a clean-room decoder.

**2. BlueALSA has to be rebuilt** against it, so `HAVE_LDAC_DECODE` is defined
and an LDAC **Sink** endpoint gets registered with BlueZ. Without it a sender is
only ever offered SBC and AAC.

**3. BlueZ has to be patched, or LDAC never actually streams.** BlueZ listens
for AVDTP without asking for an L2CAP incoming MTU, so it advertises the
672-byte default — and that becomes the *sender's* outgoing MTU. Sony's encoder
refuses to initialise below 679 bytes, so the sender fails with
`LDACBT_ERR_ILL_MTU_SIZE` and transmits nothing, while BlueZ still reports the
transport as `active` and the receiver logs no error at all. SBC and AAC pack
into much smaller packets and work fine at 672, which makes this look like a
codec bug rather than an MTU one. `patches/bluez-a2dp-imtu.patch` raises it to
1024; the packaged `bluetoothd` is left untouched and a systemd drop-in points
the service at the rebuilt one in `/usr/local/libexec`.

## What gets installed

| Path | What |
| --- | --- |
| `/usr/local/lib/libldacBT_dec.so.2` | the decoder, exporting exactly two symbols |
| `/usr/local/include/ldac-dec/ldacBT.h` | Sony's header plus the decode prototypes |
| `/usr/local/lib/pkgconfig/ldacBT-dec.pc` | what BlueALSA's `configure` looks for |
| `/usr/local/bin/bluealsad`, `bluealsa-aplay`, `bluealsactl` | BlueALSA |
| `/usr/local/libexec/bluetooth/bluetoothd` | BlueZ with the AVDTP MTU fix |
| `/etc/asound.conf` | the `ldac96` output PCM |
| `/etc/systemd/system/*.service.d/override.conf` | service arguments |
| `/etc/systemd/system/bt-agent.service` | headless pairing agent |
| `/etc/systemd/system/bluetooth-sink-setup.service` | discoverable + pairable at boot |

PulseAudio is masked: it registers competing A2DP endpoints with BlueZ and would
hold the sound card. This board is a headless appliance, so it is switched off
rather than reconfigured.

## The 24-bit/96 kHz output

The UMC404HD is a fixed **4-channel** device that accepts S16_LE or S32_LE at
44.1–192 kHz, and its 24-bit samples travel in 32-bit containers — so `S32_LE @
96000` *is* its 24-bit/96 kHz mode. Bluetooth delivers stereo and the card will
not open with 2 channels, so `/etc/asound.conf` defines:

* `umc404hd_96k` — the hardware, pinned to `S32_LE`, `96000`, 4 channels
* `ldac96` — a `plug` in front of it routing L/R to outputs 1 and 2

The rate is pinned rather than followed from the stream, so the interface always
runs at 24-bit/96 kHz. LDAC at 96 kHz therefore passes through untouched; a 44.1
or 48 kHz stream is resampled up to it. To feed outputs 3 and 4 with the same
pair, add to `ldac96`'s ttable:

```
ttable.0.2 1
ttable.1.3 1
```

**Volume.** The interface exposes a 128-step attenuator with a dB scale
(`UMC404HD 192k Output`, 0 dB at 100%), and `bluealsa-aplay` runs with
`--volume=mixer` so the sender's volume drives *that* instead of scaling
samples. At full volume the decoded stream reaches the converter bit-perfect.
For output that ignores the remote entirely, switch to `--volume=none` in
`config/bluealsa-aplay.service.d-override.conf`.

## Pairing

The board is permanently discoverable and pairable as `radxa-cubie-a7s`, and
`bt-agent` answers with NoInputNoOutput capability, so pairing is "just works" —
the same posture as a consumer Bluetooth speaker, and it means anyone in radio
range can pair. To require a PIN instead, see the comment in
`config/bt-agent.service`.

**Pair from the board, not from the sender.** With this AIC8800D80 adapter,
pairing initiated by the *sender* completes and reports success on both sides but
no link key is ever written — `/var/lib/bluetooth/<adapter>/<device>/info` never
appears, and the bond is silently gone moments later. Initiated from the board it
stores correctly on both ends. On the Radxa:

```sh
bluetoothctl --timeout 15 scan on
bluetoothctl pair  <SENDER-MAC>
bluetoothctl trust <SENDER-MAC>
```

Then connect from the sender as usual. Once bonded, reconnects work in either
direction. If a connection attempt returns `br-connection-busy` or
`br-connection-unknown`, wait a few seconds and retry — this adapter needs a
second attempt fairly often.

## Verifying

```sh
tools/ldac-status.sh
```

reports the services, the codecs offered to senders, the codec and rate actually
negotiated, whether the patched `bluetoothd` is in use, and the rate and format
the sound card is really running at. During an LDAC stream it should show:

```
-- codecs offered to senders
  A2DP-sink   : SBC AAC LDAC
-- connected streams
    Selected codec: LDAC
    Rate: 96000 Hz
-- AVDTP MTU fix
  patched bluetoothd in use (AVDTP IMTU 1024)
-- sound card
  card1:
    format: S32_LE
    channels: 4
    rate: 96000 (96000/1)
```

`make test` round-trips real LDAC frames from Sony's encoder through the decoder
at every LDAC sample rate and checks the recovered signal; `install.sh` refuses
to install if it fails.

A 440 Hz tone at −6 dBFS sent over the finished link decodes on the board to RMS
0.3536 and peak 0.5000 against a source of 0.3536 / 0.500, with all energy at
440 Hz.

## Notes

**Decoder handle lifetime.** `ldacBT_free_handle()` belongs to the encoder
library and is deliberately not interposed, so a decoder outlives its handle
until its table slot is reused or evicted. `src/ldacBT_dec.c` explains the
trade-off; the practical effect is bounded and invisible to BlueALSA, which
always re-initialises before decoding.

**Symbol safety.** `src/ldacBT_dec.map` keeps everything except
`ldacBT_init_handle_decode` and `ldacBT_decode` local. BlueALSA links this
library *ahead* of `libldacBT_enc`, so any shared name exported here would
override the encoder's own — including for calls made from inside it.

**Bitrate.** A PipeWire sender using LDAC's adaptive bitrate settles around
500 kbps on this link. LDAC's 990 kbps mode is close to the limit of what a
single Bluetooth link can carry and tends to stutter.

**After upgrades.** `bluetoothd` is a local build pinned to the installed BlueZ
version. If the `bluez` package is upgraded, re-run `./install.sh` so the
rebuilt binary matches; the installer reads the version from `bluetoothctl` and
will stop if the patch no longer applies.

**`btmon` does not work on this board.** The out-of-tree `aic_btusb` driver does
not feed the HCI monitor channel, so `btmon` captures nothing and `hciconfig`
byte counters stay at zero. Use `tools/ldac-status.sh` and the BlueALSA journal
instead.

## Uninstall

```sh
./install.sh --uninstall
```

Restores the packaged `bluetoothd`, unmasks PulseAudio, and removes the services
and configuration. BlueALSA itself is left installed; remove it with
`sudo make -C ~/bluez-alsa uninstall`.
