# Arctis Nova Pro Omni: USB HID protocol notes

These notes describe how a computer talks to the SteelSeries Arctis Nova Pro Omni GameHub (the dock) over USB. They exist for interoperability: so the Omni can be used on macOS and other systems without the official software. They are written from scratch. No SteelSeries code, firmware, assets or data files are included in this repository.

Everything marked **confirmed** was checked on a real Omni: the command was sent, the reply decoded, and for writes the value was read back and then restored. Things marked **unconfirmed** are implemented in OmniKit but haven't been seen working on hardware yet; OmniKit and the app flag them as such.

Tested hardware (2026-10-03, macOS 27): GameHub `1038:2290`, release 0x0128, hub MCU 1.28.0 ×2, DSP 0.33.0, headset 0.33.0.

Independent public sources that agree with these notes:
- [HeadsetControl PR #584](https://github.com/Sapd/HeadsetControl/pull/584) by marctew adds Omni battery and sidetone, tested on hub firmware 0x0132. It uses report ID 0x01, 64-byte reports, interface 3 / usage page 0xFFC0, `01 B0` status with battery at byte 6 and charging at byte 15, and sidetone `01 38 <on> <level>`.
- loteran/Arctis-Sound-Manager issue #70 has a USB descriptor dump: interface 3 has a 64-byte interrupt IN endpoint and **no OUT endpoint**, so writes go over the control pipe as SET_REPORT.

---

## 1. USB identity

| PID | Role | Notes |
|---|---|---|
| **0x2290** | GameHub (dock) | The device to talk to. Composite: USB Audio (interfaces 0–2), vendor HID (interface 3), consumer keys (interface 4) |
| 0x2291 | GameHub in **bootloader** mode | Never open it. OmniKit and the probe refuse it |
| 0x2296 | Headset over a USB cable | Firmware functions only, no settings. Refused |
| 0x2297 | Headset in **bootloader** mode | Never open it. Refused |

All settings go through the GameHub; the headset has none of its own over USB.

## 2. Transport

| Item | Value | Status |
|---|---|---|
| HID interface | **3** | confirmed |
| Command collection | usage page **0xFFC0**, usage 0x0001 | confirmed |
| Event collection | usage page **0xFF00**, usage 0x0001, also on interface 3 | confirmed |
| Report ID | **0x01** for commands and replies, **0x07** for hub events | confirmed |
| Short command | 64 bytes including the report ID: `[0x01, cmd, args…, zero-padded]`, sent as an **output report** (control SET_REPORT, since there is no OUT endpoint) | confirmed |
| Short reply | 64-byte **input report**: `[0x01, cmd echo, data…]` | confirmed |
| Long data (EQ, full audio settings) | **Feature report 0x01.** Read: send the 64-byte query, then GET_FEATURE. Write: SET_FEATURE with a 1036-byte buffer that starts with the report ID | confirmed |
| Checksums | None. No checksum, CRC or sequence counter in any settings or status packet | confirmed |
| Handshake | None. The hub answers queries as soon as it has enumerated | confirmed |

macOS specifics:
- **GET_FEATURE replies omit the report ID.** Byte 0 is the opcode echo, so feature-report offsets on macOS are one lower than the tables below (which count the report ID as byte 0). OmniKit's `alignFeature` and `probe.py` re-insert the ID so the tables apply as written.
- **GET_FEATURE replies are at least 256 bytes**; everything decoded lives in the first ~170.
- **SET_FEATURE buffers include the report ID**, unlike GET replies.

Pacing that OmniKit enforces (conservative; not required by any observed failure):
- At least **50 ms** between transfers, one at a time.
- **500 ms** after the last write before save-to-flash.
- **5 s** after the hub enumerates before the first command.

Writes are fire-and-forget: the hub sends no ACK. To confirm a write, read the matching state again (`01 B0`, `01 20` or `01 80`); the hub reflects every write immediately.

---

## 3. Commands

Bytes are hex, report ID first. `<v>` marks a value. Every short command is zero-padded to 64 bytes.

### 3.1 Status (read, confirmed)

Send `01 B0`; the hub replies with a 64-byte input report.

| Byte | Field | Encoding |
|---|---|---|
| 0 | report ID | 0x01 |
| 1 | echo | 0xB0 |
| 2 | Bluetooth on at power-on | 0 off, 1 on |
| 3 | Bluetooth call behaviour | 0 nothing, 1 lower other audio by 12 dB, 2 mute other audio |
| 4 | Bluetooth mode | 1 off, 2 pairing, 4 linked |
| 5 | Bluetooth link status (mode 4) | 1 connected, 2 lost, 4 busy, 8 error |
| **6** | **headset battery %** | 0–100 |
| 7 | spare battery % | 0–100 (the battery charging in the dock; not yet checked against a real swap) |
| 8 | transparency level | 1–10 |
| 9 | mic muted | 0/1 |
| 10 | noise control mode | 0 off, 1 transparency, 2 ANC |
| 11 | muted-mic LED brightness | 1–10 |
| 12 | auto-off timer code | see the code table in 3.4 |
| 13 | wireless mode | 0 speed, 1 range (read-only) |
| **14** | **2.4 GHz link** | 1 unpaired, 2 pairing, 4 paired but disconnected, **8 connected** |
| **15** | **charging** | 1 unknown / headset off, 2 charging by cable, 4 full, **8 on battery** |
| 16 | ANC level | 1–3 |

Only trust the battery value while byte 14 is 8 (headset connected).

### 3.2 Hub events (unsolicited)

The hub sends these on the 0xFF00 collection, report ID **0x07**, whenever something changes, including changes made on the dock itself.

| Event | Meaning | Payload | Status |
|---|---|---|---|
| `07 B7 <hs%> <spare%> <charging>` | battery change | charging uses the byte 15 codes | confirmed |
| `07 BB <v>` | mic mute toggled | 1 muted, 0 unmuted | confirmed |
| `07 BD <v>` | noise control mode changed (ANC button) | 0 off, 1 transparency, 2 ANC | confirmed |
| `07 B8 <v>` | ANC level changed | 1–3 | confirmed |
| `07 25 <v>` | hub volume (the dock's dial) | sent on every step | confirmed |
| `07 <setting opcode> …` | echo of a setting from 3.4 | same layout as the write | partly confirmed |
| `07 B5 … <link>` | connection change | byte 4 = 2.4 GHz link (byte 14 codes) | unconfirmed |
| `07 45 <game> <chat>` | ChatMix dial | 0–100 each; the dominant side reads 100 | unconfirmed, see 3.8 |
| `07 23 <v>` | audio input changed | 0–3 | unconfirmed |
| `07 1B` / `1D` / `1F` | 2.4 GHz / mic / Bluetooth EQ changed on the hub | re-read that EQ | unconfirmed |

### 3.3 Firmware and serial (read, confirmed)

| Command | Reply |
|---|---|
| `01 10` | Five 12-byte ASCII version strings from byte 2: hub MCU 1, hub MCU 2, hub DSP, headset MCU, headset Bluetooth. All zero when no headset is paired |
| `01 12` | Bytes 2–20: the 19-character ASCII serial |

### 3.4 Settings (64-byte output report, all confirmed)

Each of these was written, read back and restored on the test hub.

| Setting | Bytes | Values |
|---|---|---|
| Sidetone | `01 38 <on> <level>` | on 0/1, level 1–10. To turn it off, send on = 0 and keep the level |
| Mic volume | `01 37 <v>` | 1–10 |
| Mic noise reduction | `01 3C <on> <level>` | off = `00 01`; on = `01 <1–3>` (low / medium / high) |
| Muted-mic LED brightness | `01 BF <v>` | 0–10 |
| Noise control mode | `01 BD <v>` | 0 off, 1 transparency, 2 ANC |
| ANC level | `01 B8 <v>` | 1–3 |
| Transparency level | `01 B9 <v>` | 1–10 |
| Auto-off | `01 C1 <code>` | code: 0 never, 1 = 1 min, 2 = 5, 3 = 10, 4 = 15, 5 = 30, 6 = 60 min |
| Volume limiter | `01 27 <v>` | 0/1 |
| Line-out mode | `01 43 <v>` | 1 speakers, 2 streaming |
| Stream mix | `01 47 <main> <main> <aux> <mic>` | each 0–100; **main is sent twice** |
| OLED brightness | `01 85 <v>` | 1–10 |
| OLED screensaver timer | `01 83 <code>` | same code table as auto-off |
| OLED screensaver mode | `01 88 <v>` | 0 screen off, 1 dim |
| OLED home view | `01 89 <v>` | 0 detailed, 1 simple |
| OLED home option | `01 8A <v>` | 0 stereo, 1 preset, 2 meters |
| Bluetooth on at power-on | `01 B2 <v>` | 0/1 |
| Bluetooth call behaviour | `01 B3 <v>` | 0 nothing, 1 lower by 12 dB, 2 mute others |

Unconfirmed commands that OmniKit knows about:

| Command | Bytes | Notes |
|---|---|---|
| Save to flash | `01 09` | No argument. Makes settings survive a power cycle. Not yet sent on hardware; Hushdeck instead re-applies remembered settings when the hub reconnects |
| ChatMix on/off | `01 49 <v>` | 0/1. Should turn the dock's dial into a game/chat mixer that sends `0x45` events |
| Host mixer present | `01 8D <v>` | 0/1. Changes OLED / ChatMix behaviour |
| OLED default screen | `01 95` | Restores the hub's own screen |

### 3.5 OLED settings (read, confirmed)

Send `01 80`; 64-byte reply.

| Byte | Field |
|---|---|
| 2 | screensaver timer code (0–6) |
| 3 | OLED brightness (1–10) |
| 5 | home view (0/1) |
| 9 | colour variant (0 black, 1 white, 4 midnight blue, 5 special edition) |
| 10 | screensaver mode (0/1) |
| 11 | home option (0–2) |

### 3.6 Full audio settings (read, confirmed)

Send `01 20`, then GET_FEATURE report 0x01.

| Byte | Field |
|---|---|
| 1 | echo 0x20 |
| 2–61 | Custom 2.4 GHz parametric EQ: 10 bands × 6 bytes (3.7) |
| 62–121 | Active 2.4 GHz parametric EQ: 10 × 6 |
| 122–131 | Bluetooth EQ gains (int8, 0.1 dB) |
| 132–141 | Mic EQ gains (int8, 0.1 dB) |
| 142 | audio input (0–3) |
| 143 | hub volume (read-only) |
| 144 | volume limiter |
| 145 | surround |
| 146 | mic volume |
| 147 | sidetone level |
| 148 | line-out mode |
| 149 / 150 / 151 | selected 2.4 GHz / mic / Bluetooth EQ preset |
| 152 / 153 | ChatMix game / chat |
| 156 / 158 / 159 | stream main / aux / mic |
| 165 / 166 | mic noise reduction on / level |
| 170 | sidetone on |

### 3.7 Equalizers (confirmed)

The hub has three independent EQs: a **2.4 GHz parametric EQ** (what you hear over the wireless link), a **Bluetooth 10-band graphic EQ** and a **mic 10-band graphic EQ**.

**Parametric band, 6 bytes:**
- frequency: uint16 LE, 20–20000 Hz (20001 = band disabled);
- filter type: uint8, 1 peaking, 2 low-pass, 3 high-pass, 4 low-shelf, 5 high-shelf;
- gain: int8 = dB × 10, −12.0 to +12.0 dB;
- Q: uint16 LE = Q × 1000, 0.2–10.0.

Flat is 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k and 16k Hz, all peaking, 0 dB, Q 1.414.

**Graphic EQ:** 10 int8 gains = dB × 10, −12 to +12 dB. Bluetooth bands are 32 Hz–16 kHz like the parametric defaults; the mic bands start at 31 and 62 Hz.

**Preset slots:**
- 2.4 GHz: 0 Flat, 1 Bass Boost, 2 Focus, 3 Smiley, **4 Custom**, 5 other.
- Bluetooth: 0 Flat, 1 Bass Boost, 2 Focus, 3 Smiley, **4 Custom**.
- Mic: 0 Flat, 1 Balanced, 2 Broadcast High Pitch, 3 Broadcast Low Pitch, 4 Clarity Low Pitch, 5 Clarity High Pitch, 6 Deep Voice, 7 Less Nasal, **8 Custom**, 9 Walkie Talkie.

**Reads** (64-byte query, then GET_FEATURE):

| Query | Reply |
|---|---|
| `01 1A` (2.4 GHz) | b2 selected slot, b3–8 short name (6 ASCII), b9–69 name (61 ASCII), b70–129 10 bands × 6 |
| `01 1E` (Bluetooth) | b2 slot, b3–8 short name, b9–69 name, b70–79 10 gains |
| `01 1C` (mic) | b2 slot, b3–8 short name, b9–69 name, b70–79 10 gains |
| `01 18 <slot>` | preset name; slot 0 = 2.4 GHz custom, 1 = Bluetooth custom, 2 = 2.4 GHz other, 3 = mic custom |

**Writes** (SET_FEATURE, 1036 bytes, zero-padded). Selecting a preset and uploading bands are one operation:

| EQ | Layout |
|---|---|
| 2.4 GHz | `01 1B <slot> <short name 6> <name 61> <10 × 6-byte bands>` |
| Mic | `01 1D <slot> <short name 6> <name 61> <10 × int8 gains>` |
| Bluetooth | `01 1F <slot> <short name 6> <name 61> <10 × int8 gains>` |

**The hub only accepts band data on the Custom slot** (2.4 GHz / Bluetooth 4, mic 8). Writing a factory slot selects that preset but keeps the hub's built-in curve; the uploaded bands are ignored. So an editor has to switch to Custom as soon as the user changes a band. All three EQs were round-tripped (+2 dB at 1 kHz on Custom) and restored.

### 3.8 ChatMix

The dock's dial is a **volume knob by default**: each step sends `07 25 <volume>`, and no `0x45` events appear. The dial should only become a game/chat mixer after the host sends `01 49 01`. That hasn't been tried on hardware yet.

### 3.9 Not available over USB

- No wireless speed/range write (status byte 13 is read-only).
- No volume write (the hub volume in audio settings byte 143 is read-only).
- No RGB lighting; `0xBF` is the muted-mic LED on this device.
- No settings on the headset's own USB port.

---

## 4. Do not send

OmniKit and `tools/probe.py` refuse all of these, with or without `--force`, and anything not on the allowlist is refused anyway.

1. **Command 0x01** (reset MCU; reboots a chip, including into its bootloader).
2. **Command 0x02** (part of the firmware-update sequence).
3. **Command 0xFD** (factory reset).
4. **Any feature-report write that isn't one of the three EQ layouts above.** Firmware images are pushed through feature reports.
5. **Anything to PIDs 0x2291, 0x2296 or 0x2297.** If the hub ever shows up as 0x2291, unplug it and power-cycle it.
6. As an extra margin, raw writes in the ranges **0x00–0x08** and **0xF0–0xFF**.

Firmware-update details are deliberately not documented here.

---

## 5. Differences from the Nova Pro Wireless

The Omni is a different protocol family from the Nova Pro Wireless that HeadsetControl already supports. The opcodes mostly match, but almost everything around them differs.

| | Nova Pro Wireless | Omni |
|---|---|---|
| Report ID | 0x06 | **0x01** (events 0x07) |
| HID interface | 4, with an OUT endpoint | **3**, no OUT endpoint (SET_REPORT) |
| Sidetone | `06 39 <0–3>` | `01 38 <on> <1–10>` |
| EQ | `06 33` + 10 bytes, 0.5 dB steps | feature-report EQs (3.7) |
| Battery | byte 6, 0–8 | byte 6, **0–100 %** |
| Charging byte 15 | 1 / 2 / 8 | same, plus 4 = full |
| Auto-off | `06 C1 <code>` | `01 C1 <code>`, same codes |
| Save | `06 09` | `01 09` |
| `0xBF` | LED strength | muted-mic LED brightness |

---

## 6. Open questions

1. **ChatMix:** does `01 49 01` turn the dial into a mixer that sends `0x45`? Does `01 49 00` turn it back?
2. **Save to flash (`01 09`):** does it persist every setting, and how much delay does it need?
3. **Spare battery (status byte 7):** check it against a real battery swap.
4. **Unconfirmed events** (`0xB5`, `0x23`, `0x1B/0x1D/0x1F`): capture them.
5. **Firmware drift:** the test hub ran 1.28.0. Re-run the checks after a firmware update.
