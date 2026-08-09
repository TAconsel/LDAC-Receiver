# Bluetooth LDAC receiver for the Radxa Cubie A7S

Turns the board into an A2DP **sink** that accepts LDAC, applies FIR room
correction, and plays the result out of a USB audio interface at
**24-bit / 96 kHz**.

Verified on a Radxa Cubie A7S (Allwinner A733, Debian 11 bullseye, aarch64,
BlueZ 5.55, AIC8800D80 Bluetooth) with a Behringer UMC404HD, receiving from a
PipeWire 1.6.2 sender.

```
sender ──LDAC/A2DP──▶ bluealsad ──▶ libldacBT_dec ──▶ ALSA "dsp96" ──▶ CamillaDSP ──▶ UMC404HD
                      (A2DP sink)   (libldacdec)      alsa_cdsp        convolution    24-bit/96 kHz
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
| `/usr/local/bin/camilladsp` | CamillaDSP v3.0.1 |
| `…/alsa-lib/libasound_module_pcm_cdsp.so` | the alsa_cdsp plugin |
| `/etc/camilladsp/roomcorr.yaml`, `Test900.wav` | the DSP config and filter |
| `/etc/asound.conf` | the `ldac96` and `dsp96` output PCMs |
| `/etc/systemd/system/*.service.d/override.conf` | service arguments |
| `/etc/systemd/system/bt-agent.service` | headless pairing agent |
| `/etc/systemd/system/bluetooth-sink-setup.service` | discoverable + pairable at boot |
| `/usr/local/bin/node`, `/usr/local/share/ldac-web/` | the control panel |
| `/usr/local/sbin/ldac-ctl` | its privileged half |
| `/etc/default/ldac-receiver` | settings the panel writes |

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

## Room correction

`Test900.wav` holds one impulse response per channel — 32768 taps at 96 kHz
(341 ms), float32. CamillaDSP convolves each channel with its own response and
then widens the result to the card's four channels.

**How the audio gets there.** This board's BSP kernel has no `snd-aloop`, so the
usual ALSA-loopback route into CamillaDSP is not available. The
[alsa_cdsp](https://github.com/scripple/alsa_cdsp) plugin is used instead: it
presents itself to BlueALSA as an ALSA device (`dsp96`), starts CamillaDSP when
that device is opened, and pipes audio to its stdin. CamillaDSP owns the sound
card from there, so the 4-channel layout and the 96 kHz rate live in
`/etc/camilladsp/roomcorr.yaml` rather than in `asound.conf`. Nothing
kernel-side is involved, and CamillaDSP only runs while something is playing.

The plugin passes the stream's format, rate and channel count to CamillaDSP as
`-f/-r/-n/-e` rather than rewriting the config file, so the config can stay
read-only — which matters because the plugin runs inside `bluealsa-aplay`'s
systemd sandbox.

**Only 96 kHz.** The filter is a 96 kHz impulse response and would be wrong at
any other rate, so `dsp96` offers 96 kHz alone and a `plug` in front converts
anything else up to it. A 44.1 kHz SBC stream is resampled to 96 kHz before
correction.

**Latency and cost.** The response peaks at ~45.5 ms, so it is a linear-phase
correction and adds that much delay on top of Bluetooth's ~200 ms; fine for
music, not for lip-sync. Convolution costs about 22% of one Cortex-A55 core —
under 3% of the board.

**Headroom.** This filter's maximum gain is −0.25 dB (left) and −1.15 dB
(right), i.e. already normalised so it cannot clip, so no attenuation is
applied. **If you replace it with one that boosts anywhere, add a `Gain` filter
ahead of the convolution with a matching negative gain**, or the output will
clip. `tools/verify-convolution.sh` prints nothing about this — check the filter
itself.

**Replacing the filter.** Drop in a new WAV (one channel per output, at 96 kHz)
and re-run `./install.sh`, or point `IR=` at it:

```sh
IR=/path/to/new-correction.wav ./install.sh
```

**Bypassing it.** `ldac96` in `/etc/asound.conf` is the uncorrected path. Switch
`--pcm=dsp96` to `--pcm=ldac96` in
`/etc/systemd/system/bluealsa-aplay.service.d/override.conf` and restart the
service. The two are alternatives — CamillaDSP opens the card exclusively.

**Buffering.** `bluealsa-aplay` runs with a 500 ms buffer. The default 200 ms is
too tight once CamillaDSP is in the path: the player feeds a pipe drained in
chunks rather than a soundcard draining steadily, which produced a
drain-to-avoid-underrun every few seconds. At 500 ms a 40-second stream logs a
single priming event.

**CamillaDSP version.** Pinned to v3.0.1. Releases from v4 onwards are built
against glibc 2.34 and will not start on bullseye (glibc 2.31) — they fail at
exec with `GLIBC_2.34 not found`. `install.sh` checks this and stops with an
explanation.

## Control panel

`http://<box>:8080/` — room correction on/off, Bluetooth discoverable on/off,
and the paired clients (connect, disconnect, trust, remove), with the live codec,
sample rate and output format. It polls every 5 seconds and stops while the tab
is hidden.

**Read this before putting it on your network: there is no password by
default.** Anyone who can reach the port can unpair your devices and toggle the
audio path. That is a reasonable default for a receiver on a home LAN and a bad
one anywhere else. Two ways to tighten it:

```sh
sudo systemctl edit ldac-web        # then add one of:

[Service]
Environment=LDAC_WEB_TOKEN=some-long-random-string   # then open /?token=...

[Service]
Environment=LDAC_WEB_BIND=127.0.0.1                  # reachable only via SSH tunnel
```

The page keeps a token in `sessionStorage` and strips it from the address bar,
so it is not left in browser history.

**Privilege model.** The panel runs as `ldacweb`, an unprivileged system account
with no shell. The one privileged thing it can do is run
`/usr/local/sbin/ldac-ctl` through sudo — a root-owned script with a fixed verb
set that validates its own arguments. Requests are mapped onto that verb table
in the server as well, so a bad value is rejected before it reaches sudo, and
`execFile` is used throughout: no shell is involved anywhere between an HTTP
request and a privileged action. A Bluetooth address that is not exactly a
Bluetooth address is refused at both layers.

`ldac-ctl` is a normal command-line tool too, which is often quicker than the
browser:

```sh
sudo ldac-ctl status                     # everything, as JSON
sudo ldac-ctl convolution off            # bypass room correction
sudo ldac-ctl discoverable off           # hide the adapter
sudo ldac-ctl device remove AA:BB:CC:DD:EE:FF
```

**Settings live in `/etc/default/ldac-receiver`** and survive reboots.
`bluealsa-aplay.service` reads `LDAC_PCM` from it as an `EnvironmentFile`, which
is why switching correction on and off is a one-line rewrite plus a service
restart rather than an edit to a unit. `bluetooth-sink-setup.service` restores
`LDAC_DISCOVERABLE` at boot. Editing the file by hand works; run
`systemctl restart bluealsa-aplay` afterwards.

**Toggling correction restarts the player**, so audio stops for a moment and the
sender may need a second to resume. That is inherent — CamillaDSP owns the sound
card exclusively, so the path cannot be swapped underneath a running stream.

**API**, if you would rather script it than click:

| | |
| --- | --- |
| `GET /api/status` | everything the page shows |
| `POST /api/convolution` | `{"enabled": true\|false}` |
| `POST /api/discoverable` | `{"enabled": true\|false}` |
| `POST /api/device` | `{"action": "connect\|disconnect\|trust\|untrust\|remove", "mac": "…"}` |

**systemd sandboxing note.** `ldac-web.service` looks under-hardened on purpose.
Every seccomp-based option — `PrivateDevices`, `ProtectKernel*`, `ProtectClock`,
`RestrictAddressFamilies`, `RestrictNamespaces`, `RestrictSUIDSGID`,
`LockPersonality`, `SystemCallArchitectures` — implies `NoNewPrivileges=yes`,
which stops sudo from working at all (`effective uid is not 0`), and that
implication cannot be undone. `ProtectHostname` turned out to do the same here
despite not being documented as such. What is left is the namespace and mount
half, which is the part that matters: a read-only system, no home directories,
private `/tmp`. `ReadWritePaths=/etc/default` is the single hole, because the
mount namespace applies to the sudo'd helper too and it has to save settings.

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

```sh
tools/verify-convolution.sh
```

proves the room correction is actually applied, and applied correctly. An
impulse convolved with a filter is that filter, so it pushes a unit impulse
through the **installed** config — only the `devices:` block is swapped for file
in / file out, everything below it is taken verbatim — and compares the result
against the impulse response file tap by tap, then checks that outputs 3 and 4
stay silent. It cannot pass while the live pipeline differs. Expect:

```
channel 0: 32768 taps compared, worst error 4.66e-10 ... -> ok
channel 1: 32768 taps compared, worst error 4.66e-10 ... -> ok
convolution verified
```

(24-bit output quantises at 6e-8, so that error is three orders of magnitude
below one LSB.) `install.sh` runs this as its last step.

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
