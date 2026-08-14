# Bluetooth LDAC receiver for the Radxa Cubie A7S

Turns the board into an A2DP **sink** that accepts LDAC, applies FIR room
correction, and plays the result out of a USB audio interface at
**24-bit / 96 kHz**. It is also a **USB DAC**: a computer or phone on the USB-C2 port sees a
24-bit/96 kHz sound card and gets the same correction — and a phone charges
while it plays.

Verified on a Radxa Cubie A7S (Allwinner A733, Debian 11 bullseye, aarch64,
BlueZ 5.55, AIC8800D80 Bluetooth) with a Behringer UMC404HD, receiving from a
PipeWire 1.6.2 sender.

```
sender ──LDAC/A2DP──▶ bluealsad ──▶ libldacBT_dec ──▶ ALSA "dsp96" ─┐
                      (A2DP sink)   (libldacdec)      alsa_cdsp     │
                                                                    ├─▶ CamillaDSP ──▶ UMC404HD
computer ──USB──────▶ f_uac2 gadget ──▶ ALSA "hw:UAC2Gadget" ───────┘   convolution    24-bit/96 kHz
                      (UAC2 sink)
```

The two inputs are **alternatives**, not a mix — CamillaDSP opens the interface
exclusively, so one player owns it at a time and the panel switches between
them.

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
| `/etc/systemd/system/ldac-single-link.service` | holds the box to one device |
| `/etc/systemd/system/ldac-audio-watchdog.service` | recovers a wedged player |
| `/usr/local/sbin/ldac-usb-gadget` | builds the UAC2 gadget in configfs |
| `/usr/local/sbin/ldac-usb-dac` | feeds USB audio through the same correction |
| `/etc/systemd/system/ldac-usb-gadget.service` | binds the gadget at boot |
| `/etc/systemd/system/ldac-usb-dac.service` | the USB player, started on demand |
| `/usr/local/sbin/ldac-usb-charge` | swaps the power role so a phone charges |
| `/etc/systemd/system/ldac-usb-charge.service` | watches the port and re-requests it |
| `/boot/dtbo/cubie-a7s-usbc2-device-charge.dtbo` | makes USB-C2 a device port (needs a reboot) |
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
* `ldac96` — a `plug` in front of it routing L/R to outputs 1+2 and again to 3+4

The rate is pinned rather than followed from the stream, so the interface always
runs at 24-bit/96 kHz. LDAC at 96 kHz therefore passes through untouched; a 44.1
or 48 kHz stream is resampled up to it.

### Output map

| Outputs | Carries | Level |
| --- | --- | --- |
| 1–2 | the stream **with** room correction — the speakers | the panel's slider |
| 3–4 | the same stream **uncorrected**, for an external recorder | fixed at 0 dB |

Outputs 3–4 are a flat tap deliberately taken ahead of the correction filter:
the filter is tuned to one room and one pair of speakers, so baking it into a
recording would be wrong. Both pairs come off the same converter at
24-bit/96 kHz.

The two pairs are **not time-aligned**. The correction is linear phase with its
peak ~45.5 ms in, so outputs 1–2 lag 3–4 by that much. That is invisible to a
separate recording; to line them up for an A/B, add a 45.5 ms `Delay` filter on
channels 2 and 3 in `config/camilladsp-roomcorr.yaml`.

**Volume.** The interface exposes a 128-step attenuator with a dB scale
(`UMC404HD 192k Output`, 0 dB at 100%) — and it turns out to have an
*independent* attenuator per output. The panel's slider and mute therefore drive
outputs 1–2 only, and `ldac-ctl` re-pins 3–4 to 0 dB after every change and at
boot, because `alsa-restore` writes all four from its saved state. A recorder
feed that moved with the listening volume would be useless.

Two things still reach the tap, and neither can be fixed from the mixer:

* In the default volume mode (`software`, panel owns the interface) the
  connected device's own volume is applied **digitally**, upstream of
  everything, so the tap follows the phone's volume slider. Keep the phone at
  maximum for a full-scale recording.
* In `mixer` mode (device owns the interface) BlueALSA writes all four channels
  of the element on every remote volume change, so the pin only holds until the
  device next moves its volume. Use the panel as the volume source if the tap
  matters.

For output that ignores the remote entirely, switch to `--volume=none` in
`config/bluealsa-aplay.service.d-override.conf`.

## Room correction

`Test900.wav` holds one impulse response per channel — 32768 taps at 96 kHz
(341 ms), float32. CamillaDSP widens the stereo stream to the card's four
channels *first*, then convolves outputs 1 and 2 with their own response and
leaves 3 and 4 alone. That order is what makes the uncorrected recorder tap
possible: correcting first would leave nothing clean to copy.

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

`http://<box>:8080/` — room correction on/off, the interface's output level,
Bluetooth discoverable on/off, and the paired clients (connect, disconnect,
trust, remove), with the live codec, sample rate and output format. It polls
every 5 seconds and stops while the tab is hidden.

**Output level.** The slider drives the UMC404HD's own attenuator, and it is
calibrated **in dB, not percent**, because that control is 128 steps of exactly
1 dB from 0 down to −127 dB: a percentage slider would put half its travel below
−63 dB, which is silence. It runs 0 to −80 dB, with mute as a separate button.

**Who owns that level** is a switch — *Let the connected device set this* —
because there is a real trade-off either way. It flips `bluealsa-aplay` between
`--volume=software` and `--volume=mixer` and restarts it.

| | the slider owns it (default) | the device owns it |
| --- | --- | --- |
| interface level | set here, stays put | follows the device's volume |
| device's volume | applied digitally, before the DSP | drives the interface directly |
| scaling the samples | yes, on the sender's volume | none anywhere in the path |
| the catch | a digital gain stage, however small | the device overwrites the slider |

Leave it off and the two controls never fight, which is what makes the slider
usable: in mixer mode the daemon rewrites that mixer on every remote volume
change, so the slider snaps back under your finger while a device is connected.
Turn it on if you want the phone's volume keys to work the way they would on a
Bluetooth speaker, with nothing touching the audio on the way through — verified
end to end, a device volume of 127/96/64/40 lands on 0/−4/−10/−17 dB at the
interface.

For output that is bit-perfect all the way to the converter either way, leave
the sender at 100% and set the level with the slider.

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
sudo ldac-ctl volume set -18             # output level, in dB
sudo ldac-ctl volume mute on
sudo ldac-ctl volume source device       # hand the level to the connected device
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
| `POST /api/volume` | `{"db": -18}`, `{"muted": true\|false}` or `{"source": "panel"\|"device"}` |
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

## USB DAC input

The board also presents itself to a computer as a USB Audio Class 2 sound card,
stereo **S32_LE at 96 kHz** — the same format the rest of the chain uses, so
nothing converts on the way in. Audio the host sends goes through the same
`Test900.wav` correction, the same 2→4 mixer and the same uncorrected recorder
tap on outputs 3–4 as Bluetooth does.

### The USB-C2 socket needs a device-tree overlay

Out of the box the USB 3 / DisplayPort socket is **host-only**, and the only
device controller is `4100000.udc-controller` — a USB 2.0 `sunxi_usb_udc` behind
`10.usbc0`, which is the *other* socket, the one that takes power. Plug a
computer into USB-C2 without the overlay and nothing enumerates in either
direction: the DWC3 comes up as a host, its `usb_role` switch exposes no `role`
attribute for userspace (the driver leaves `allow_userspace_control` off), and a
Type-C data-role swap is accepted and then renegotiated straight back to host,
because the partner keeps presenting Rd and the board wins the role toss.

`config/cubie-a7s-usbc2-device.dts` fixes that. **Both** of its fragments are
needed:

| Node | Set to | Why |
| --- | --- | --- |
| `husb311@4e/connector` | `power-role = "sink"`, `data-role = "device"` | The Type-C port controller decides roles before the USB controller ever sees them. Setting DWC3 alone does nothing — the connector still hands it the host role. |
| `xhci2-controller@6a00000` | `dr_mode = "peripheral"` | Makes DWC3 register a UDC instead of an xHCI root hub. |

```sh
dtc -q -@ -I dts -O dtb -o cubie-a7s-usbc2-device.dtbo config/cubie-a7s-usbc2-device.dts
sudo install -m644 cubie-a7s-usbc2-device.dtbo /boot/dtbo/
sudo u-boot-update      # writes the fdtoverlays line into extlinux.conf
sudo reboot
```

A file in `/boot/dtbo/` is enabled unless it ends in `.disabled`; `u-boot-update`
scans that directory and rewrites `extlinux.conf`, which warns against hand
editing. `install.sh` does all of this and tells you a reboot is needed. After
it, `/sys/class/udc/` has **two** entries and the gadget binds to
`6a00000.xhci2-controller`.

```sh
cat /sys/class/udc/6a00000.xhci2-controller/state   # "configured" = host present
```

A dual-role variant (`power-role = "dual"`, `try-power-role = "sink"`,
`source-pdos = <0x22019032>`) also works and keeps PD power-role swapping, so
the port can still charge a phone — but it leaves the data role negotiable, and
negotiating is exactly what fails.

### Direction is easy to get backwards

`f_uac2`'s `p_` and `c_` attributes are named from the **gadget's** point of
view, not the host's. `p_chmask` gives the gadget a playback stream on the IN
endpoint, which makes it a *microphone* to the host. A DAC is the other one:
`c_chmask` gives it a capture stream fed by the OUT endpoint, the host sees a
*speaker*, and the board gets an ALSA **capture** device (`hw:UAC2Gadget,0`).
Setting the wrong one produces a gadget that enumerates perfectly and can never
play anything.

### Asynchronous, when the controller allows it

`ldac-usb-gadget` asks for `c_sync=async` and settles for `adaptive` if the bind
is refused, because which one is available depends on the controller it lands
on. Async needs a feedback IN endpoint beside the isochronous OUT one:

* **DWC3** (USB-C2, with the overlay) has it. The gadget reports its real
  consumption and the host follows — and that loop is closed through us, since
  we drain at the interface's rate. This is what an asynchronous USB DAC does in
  hardware, and it is what the board negotiates now.
* **`sunxi_usb_udc`** (the power socket) has not a single endpoint to spare —
  `f_uac2` fails its bind with `afunc_bind:1171 Error!` and `-ENODEV`, and also
  refuses both directions at once, failing at `:1182`.

**Drift is corrected without resampling.** `u_audio` gives the gadget capture
device a `Capture Pitch 1000000` ALSA control (numid 1, range 750000–1005000),
and CamillaDSP drives it when `enable_rate_adjust` is on — it watches its own
buffer level and asks the *host* to send slightly faster or slower, which is
what the feedback endpoint is for. Nothing is resampled: the correction happens
at the source. CamillaDSP confirms it at startup with `Capture device supports
rate adjust`, and you can watch it work:

```sh
amixer -c UAC2Gadget cget numid=1      # 1000000 = exactly nominal
```

`ldac-usb-dac` probes for that control and picks one of three modes, rather than
assuming: **pitch** (the above), **none** (async but no pitch control — the
hardware loop is the only one, and a second would fight it), or **resample**
(adaptive and no pitch control — an `AsyncSinc` resampler absorbs the drift
here, the only case where anything is resampled).

The gadget's capture buffer is fixed at **8192 frames with a 512 frame period**
regardless of controller (u_audio's constraint; `prealloc_max` is 64 KB and
writing it changes nothing), so the USB path uses `chunksize: 2048` rather than
the Bluetooth path's 4096, with `target_level: 4096` so the first seconds of a
stream have something to absorb the host's feedback loop settling.

Two settings exist because the gadget's buffer is small and the deadline is
tight: `queuelimit: 4` (CamillaDSP's default; `1` is the lowest latency but
leaves the playback thread nothing to fall back on when it is late), and
`LimitRTPRIO=99` on the unit. CamillaDSP asks for `SCHED_FIFO` on its
processing, capture and playback threads through rtkit and **settles for
`SCHED_OTHER` without warning** when the limit forbids it — `Nice=-10` is not a
substitute, since it only biases the fair scheduler. Confirm with
`camilladsp … -l debug`, which prints `… thread has real-time priority`; note
that CamillaDSP drops the threads back to normal while the capture is stalled,
so checking `chrt` on an idle player is misleading.

Measured: a 90 s stream from a PipeWire host runs with **no underruns at all**
once settled, CamillaDSP at ~10% of one core. Starting a stream after silence
costs one "Prepare playback after buffer underrun".

### One filter, two inputs

`sbin/ldac-usb-dac` does **not** carry its own copy of the filters. It takes
everything from `filters:` onwards out of the installed
`/etc/camilladsp/roomcorr.yaml` and puts a USB `devices:` block in front — the
same trick `tools/verify-convolution.sh` uses. Both inputs therefore get
provably the same correction, and there is one file to edit.

With correction switched off it plays into the `ldac96` ALSA device instead,
whose ttable already widens stereo to four outputs, so the bypassed path needs
no mixer and no filters of its own. The panel's single correction toggle means
the same thing on either input.

### Charging the phone while it plays

A phone acting as USB host is normally also the power source, so it feeds the
board and its own battery drains. Reversing that means becoming a power
**source** while staying a data **device** — two independent USB-C roles that
can only be decoupled through a Power Delivery `PR_SWAP`.

`config/cubie-a7s-usbc2-device-charge.dts` is the overlay that allows it, and is
what `install.sh` enables by default (`USBC2_OVERLAY=device` selects the strict
one instead; only one may be enabled). The difference that matters:

| | strict `-device` | `-device-charge` |
| --- | --- | --- |
| `power-role` | `sink` | `dual` — so a PR_SWAP is legal at all |
| `try-power-role` | — | `sink` — still *attach* as a sink |
| `source-pdos` | — | 5 V @ 500 mA |

Attaching as a sink and swapping afterwards is deliberate: the source is the
DFP, so attaching as a source would make the board the USB *host* and the audio
would never start. With the strict overlay the connector is a fixed sink and
writing to `power_role` returns `EIO`.

`ldac-usb-charge` watches the port and requests the swap once a partner is
attached, there is a PD contract, and the board is the data device. It checks
afterwards that the data role survived and the gadget is still `configured`, and
puts the power role back if either broke — a link that charges but plays nothing
is not the trade wanted. The port returns to sink on every unplug (that is the
point of `try-power-role`), so the swap is re-requested on each attach; a partner
that refuses is asked five times and then left alone until the cable is pulled.

Switch it with the panel, or:

```sh
sudo ldac-ctl usb-charge on     # or: off
sudo ldac-usb-charge status     # roles, PD state, and what is being supplied
```

**It only works if the phone speaks PD.** A plain 5 V OTG source offers no
contract to swap inside. Curiously, this phone reported `supports_usb_power_
delivery: no` under the strict overlay and `yes` under the charging one — the
board has to be PD-capable itself before the negotiation happens at all.

**Current is deliberately low: 5 V @ 500 mA (2.5 W), trickle charging.**
Everything the board hands out comes from its own supply on the other USB-C
socket. Raising it means editing `source-pdos` (the .dts lists the values for
900 mA through 3 A), rebuilding and rebooting — the PDO lives in the device tree
and this kernel has no `/sys/class/usb_power_delivery` to change it at runtime.
Check what the board's own supply can spare first.

### Switching inputs

```sh
sudo ldac-ctl source usb          # or: bluetooth
```

The panel has the same control. Switching stops the other player first —
CamillaDSP opens the interface exclusively, and starting the incoming player
before the outgoing one lets go gives "Device or resource busy" and, with
`Restart=always`, a restart loop. `LDAC_SOURCE` persists, and
`bluetooth-sink-setup.service` re-applies it at boot because `bluealsa-aplay`
is enabled and would otherwise grab the card first.

`ldac-usb-dac` waits for the controller to report `configured` before starting
CamillaDSP, so selecting USB with no computer attached leaves the interface
free rather than holding it against a stream that will never arrive. The
playback watchdog also stands down while USB is selected — with
`bluealsa-aplay` deliberately stopped, a phone keeping its A2DP transport open
looks exactly like the stall it recovers from, and "recovering" would start a
fight over the card.

## One device at a time

The receiver takes a single connection. While a device is connected the adapter
is neither connectable nor discoverable, so nothing else can attach; both are
restored within about two seconds of it disconnecting. If a second device does
get in during that gap, it is disconnected.

This is `ldac-single-link.service`, a small loop in `ldac-ctl`. It has to work
that way because BlueZ has no maximum-connections setting and a paired device
will reconnect whenever it likes, so the only lever is to stop advertising and
stop accepting connections while the box is in use. Stopping the service
deliberately reopens the adapter, so the box is never left unreachable because
the watcher went away.

The panel's **Discoverable** switch shows the setting you chose, not the
momentary radio state — otherwise it would appear to switch itself off every
time someone connected. While a device is connected it reads "held off".

To allow several devices to connect again:

```sh
sudo systemctl disable --now ldac-single-link
```

Note that only one can actually *play*: CamillaDSP opens the sound card
exclusively, so a second stream fails to open it and stays silent. Mixing them
through an ALSA `dmix` was tried and reverted — see the git history.

**A trap worth knowing if you script anything with `btmgmt`.** It is built on
BlueZ's `bt_shell`, and with its stdin on `/dev/null` it prints **nothing** and
still exits 0 — which is exactly what systemd hands a service. Every `btmgmt`
call made from a unit therefore came back blank, and code that read the result
as "the adapter has no flags set" silently did nothing at all. `ldac-ctl` gives
every child an empty pipe instead, which `bt_shell` is happy with. This also
fixes `bluetooth-sink-setup.service`, whose `btmgmt` calls had the same problem.

## "Connected, but no sound"

There is one failure mode that leaves everything looking healthy and plays
nothing, and it does not recover on its own. `ldac-audio-watchdog.service`
exists for it.

What it looks like: the phone or PC is connected, the A2DP transport reports
`running`, the panel shows the right codec and rate, every service is active —
and silence. Underneath, the sound card is sitting in `PREPARED` or `XRUN` with
its playback position frozen, `bluealsa-aplay` has stopped reading, and
BlueALSA's decoder is logging `Dropping PCM frames: PCM overrun` over and over
because nothing is draining it. The wedged player ignores SIGTERM, so even a
restart stalls until systemd's stop timeout expires.

How it starts: heavy jitter from the source makes `bluealsa-aplay` drain and
reopen the output; it comes back with the card open but never writes a frame.

Two things address it:

* `TimeoutStopSec=10` on the player, so a restart can never take the default
  90 seconds when it is refusing to die.
* The watchdog, which looks every 5 seconds for the exact signature — a stream
  running while the card's position does not move — and after three consecutive
  strikes (~15 s) SIGKILLs and restarts the player. Measured recovery from a
  deliberately frozen player: **~20 s**, after which the card is `RUNNING` and
  advancing at 96 kHz again.

This is recovery, not a cure: where `bluealsa-aplay` actually wedges is not
pinned down, and `extra_samples` was ruled out (teardown is ~25 ms either way).
Disable it with `sudo systemctl disable --now ldac-audio-watchdog` if you would
rather see the failure than have it papered over.

**If it keeps happening, look at the sender's LDAC bitrate.** LDAC's 990 kbps
mode ("best quality" / "Optimize for sound quality") is right at the edge of
what a single Bluetooth link carries, and it is the jitter that starts all of
this. On Android, Developer options → Bluetooth audio quality → prefer
"Optimize for connection quality" or a fixed rate of 660 kbps or below. Turning
room correction off in the panel is also a valid answer: the direct path has
fewer moving parts and no CamillaDSP restart to race.

## Bandwidth, and why 990 kbps is marginal

Measured on a live link with a phone at LDAC's top rate, from the HCI byte and
packet counters:

| | |
| --- | --- |
| throughput | 1012–1023 kbps |
| packet rate | 186–187 packets/s |
| mean ACL payload | **679 bytes** |

Those three numbers explain the whole situation.

LDAC at 96 kHz packs 256 samples per frame, so it produces a fixed **375
frames/s** regardless of bitrate, and the phone puts **2 frames in every
packet** — 187 packets/s, exactly what is measured. 679 bytes is precisely the
maximum payload of a **2-DH5** packet, so the sender is sizing packets to fill
one and no more.

A 2-DH5 is a 5-slot transmission, plus one slot for the acknowledgement: 6 ×
625 µs = 3.75 ms per packet. At 187 packets/s that is **703 ms of every second,
or about 70% of the air**. Which is why it works but has little margin — the
remaining 30% is all that retransmissions and any other 2.4 GHz activity have to
share.

**This cannot be improved from the receiver.** The packet rate is set by LDAC's
frame rate, not by anything here, and the sender will not exceed 679 bytes even
though we advertise a 1024-byte AVDTP MTU — that ceiling is its own controller's,
so raising ours further buys nothing.

What *did* help was giving the radio back the airtime it was leaking:

* **Sniff mode is now off.** It was permitted on the A2DP link (`RSWITCH SNIFF`).
  Sniff lets the controller park the link into a duty cycle to save power; at 70%
  utilisation there is no airtime to give away, and entering or leaving sniff
  mid-stream bunches packets up and is heard as a stutter. `ldac-ctl` clears it
  from the default policy at boot and from each link as it connects. The box is
  mains powered, so the power saving buys nothing.
* **Wi-Fi is off.** The AIC8800D80 is a combo Wi-Fi/Bluetooth part sharing one
  radio, and `wlan0` was up and unassociated — which still scans periodically,
  stealing airtime from a link that has none spare. The board is on Ethernet:

  ```sh
  sudo nmcli radio wifi off     # persists in NetworkManager's state
  ```

  Re-enable with `on` if you need Wi-Fi; expect 990 kbps to suffer for it.

After both: **3 minutes at 990 kbps with one glitch event.** Good, but 70% is
70%. If it stutters where you actually use it — further from the phone, or with
other 2.4 GHz traffic around — drop the sender to ABR ("Optimize for connection
quality") or a fixed 660 kbps. The audible difference is very small; the
reliability difference is not.

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
give back a bare impulse — one sample, nothing else, which is a far stronger
statement than "not silent": any filtering leaking onto the recorder tap would
show up as a tail. It cannot pass while the live pipeline differs. Expect:

```
channel 0: 32768 taps compared, worst error 4.66e-10 ... -> ok
channel 1: 32768 taps compared, worst error 4.66e-10 ... -> ok
channel 2: uncorrected tap, impulse 0.5000 at sample 0, rest 0 -> ok
channel 3: uncorrected tap, impulse 0.5000 at sample 0, rest 0 -> ok
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
