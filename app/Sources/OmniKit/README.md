# OmniKit

Native USB HID backend for the SteelSeries Arctis Nova Pro Omni GameHub (`1038:2290`, interface 3). It replaces HeadsetControl for the Omni. The protocol comes from `protocol/protocol-notes.md`. The byte encodings match `tools/probe.py`.

## Layers

```
OmniDevice (actor)      typed state, setters, refresh, events → AsyncStream<OmniState>
   │
OmniChannel (actor)     one transfer at a time, ≥ 50 ms apart, 500 ms before save
   │
OmniOutputReport /      the only byte buffers a transport accepts; built only from
OmniFeatureReport       OmniSetting / OmniQuery / EQ types, checked by OmniSafety
   │
OmniTransport           IOKitOmniTransport (IOHIDManager) or SimulatedOmniTransport
```

- **`OmniDevice`** is what the UI uses. It watches hot-plug and waits 5 s after the hub enumerates (as GG does). Then it runs `refresh()`, which reads status, preset names, audio settings, the three EQs, OLED settings, firmware and serial. After that it follows hub events on usage page 0xFF00, with a status poll as a fallback. Setters are fire-and-forget, like GG's: local state updates after the send, and the next event or poll confirms the change. Every value lives in `OmniState` (`readouts`, `settings`, `equalizers`, `info`, `connection`).
- **`OmniChannel`** serialises every transfer (output report, GET_FEATURE, SET_FEATURE) and keeps them at least 50 ms apart. Save-to-flash (`01 09`) waits `saveDelay` after the last write. That delay defaults to 500 ms and never drops below 50 ms. Neither spacing can be switched off.
- **Transports** only move bytes. `IOKitOmniTransport` matches vendor `0x1038`, product `0x2290`, and only the vendor usage pages 0xFFC0 and 0xFF00. It sends output reports as control SET_REPORT and uses the element tree to tell event reports from replies. `SimulatedOmniTransport` is a stateful fake hub. It builds replies byte by byte from the notes, applies writes, emits events and records every packet. It has a demo mode, which the app uses when `HUSHDECK_SIMULATED_OMNI=1` (see `OmniTransportFactory.makeDefault()`).

## Safety model

All of this is enforced below the UI, and there is no override API.

1. **DO NOT SEND.** `OmniSafety` blocks opcodes `0x01` (reset/bootloader), `0x02` (firmware update) and `0xFD` (factory reset). It also blocks the conservative ranges `0x00–0x08` and `0xF0–0xFF`, exactly as `probe.py` does. A golden test checks all 256 opcodes against probe.py's own verdicts.
2. **Allowlist.** An output report's opcode must be one of the typed settings, queries or save. A feature write must be one of `0x1B`, `0x1D` or `0x1F`. Nothing else can be built, because there is no raw-bytes API.
3. **Typed, range-checked values.** `OmniSetting` uses enums wherever the wire takes a code, so invalid values can't be expressed. Integer values are checked against the ranges in protocol-notes §3.4 when the packet is built. EQ bands, gains, preset indices and names are checked as well.
4. **Experimental EQ writes.** `OmniFeatureReport` can only be created while `OmniWritePolicy.experimentalEQWrites` is on. The policy defaults to off so a caller has to opt in; the layout itself is confirmed on hardware (protocol-notes §3.7), and the app turns it on. EQ reads are always allowed.
5. **Defence in depth.** Both transports call `OmniSafety.validateOutput` or `validateFeatureWrite` again immediately before the bytes leave. The refused PIDs (`0x2291`, `0x2296`, `0x2297`) are never matched or opened.
6. **Refused before the wire.** Invalid input throws before the channel lock is taken. Tests prove that no packet reaches the simulated transport in that case.

## Permissions

The vendor usage pages don't need Input Monitoring, because TCC only gates keyboard-like devices. A non-sandboxed app needs no entitlements. A sandboxed build would need `com.apple.security.device.usb`.

## Adding a command

1. Confirm it in `protocol-notes.md` and add it to `probe.py`'s allowlist first, so there is a reference encoding.
2. Add a case to `OmniSetting`, with a typed value, in `OmniCommands.swift`. Add its `feature`, `opcode`, `validate()` range and `arguments`.
3. Add the opcode to `OmniSafety.settingOpcodes`. The `allowlistIsExactlyTheTypedCommands` test fails until steps 2 and 3 agree.
4. Add a matching `OmniFeature` case with read and write confidence and a `wireReference`. Then add a field to `OmniSettings`, including `apply(_:)` and `asSettings`.
5. Decode it:
   - in the relevant reply (`OmniReplies.swift`) and `OmniState.apply`;
   - in `OmniSetting(echo:)` if the hub echoes it;
   - in `SimulatedGameHub` (reply bytes and `applySettingWrite`).
6. Add a typed setter to `OmniDevice`.
7. Regenerate the golden fixture with `tools/.venv/bin/python tools/omnikit_golden.py`, after adding the case there. Then map the probe feature name in `GoldenPacketTests.map`.

Never add a command that is on the DO NOT SEND list. The block list and the allowlist live only in `OmniSafety`.
