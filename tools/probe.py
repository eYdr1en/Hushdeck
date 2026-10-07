#!/usr/bin/env python3
"""
probe.py - careful HID probe for the SteelSeries Arctis Nova Pro Omni GameHub.

Protocol reference: ../protocol/protocol-notes.md

USAGE
  python3 tools/probe.py --help
  python3 tools/probe.py list                      # all 0x1038 HID entries
  python3 tools/probe.py read status               # battery, charging, link, ANC...
  python3 tools/probe.py read firmware|ux|serial
  python3 tools/probe.py read audio|eq-24g|eq-bt|eq-mic     # feature-report reads
  python3 tools/probe.py read eq-name 0..3
  python3 tools/probe.py listen [--seconds 30]     # print unsolicited events
  python3 tools/probe.py send sidetone 5           # DRY RUN: prints packet only
  python3 tools/probe.py send sidetone 5 --really  # actually sends
  python3 tools/probe.py send --list               # allowlisted settings
  python3 tools/probe.py raw 01 38 01 05 --force --really    # exploratory

SAFETY MODEL
  * Only PID 0x2290 (GameHub, normal mode), usage page 0xFFC0 (commands) or
    0xFF00 (events, read-only) is ever opened. Bootloader PIDs 0x2291/0x2297
    and the headset PID 0x2296 are refused outright.
  * Writes are dry-run unless --really is given. Every packet is hex-dumped.
  * `send` only accepts features from the ALLOWLIST table below, with range
    checks. --force relaxes range checks and unlocks `raw`, but NEVER the
    DO-NOT-SEND list (reset/bootloader 0x01, DFU 0x02, factory reset 0xFD,
    conservative ranges 0x00-0x08 and 0xF0-0xFF). The block is enforced in the
    single low-level write function, so nothing can bypass it.
  * No feature-report writes exist in this tool (the firmware updater uses
    feature reports). Feature reports are only ever *read*.
  * Read-only queries (`read`) are sent without --really; they are fixed
    packets from the READS table and pass the same block check.

Requires: pip install -r tools/requirements.txt  (cython `hidapi`, imports as `hid`).
"""

from __future__ import annotations

import argparse
import sys
import time

VID = 0x1038
PID_HUB = 0x2290
PID_REFUSED = {
    0x2291: "Omni GameHub BOOTLOADER",
    0x2296: "Omni headset (USB: firmware-only functions)",
    0x2297: "Omni headset BOOTLOADER",
}
KNOWN_PIDS = {
    0x2290: "Arctis Nova Pro Omni GameHub",
    **PID_REFUSED,
    0x12E0: "Arctis Nova Pro Wireless base",
    0x12E5: "Arctis Nova Pro Wireless X base",
    0x2244: "Arctis Nova Elite base",
    0x2249: "Arctis Nova Elite headset",
}
USAGE_PAGE_CMD = 0xFFC0
USAGE_PAGE_EVT = 0xFF00
HID_INTERFACE = 3
REPORT_ID = 0x01
PACKET_LEN = 64
FEATURE_LEN = 1036
INTER_COMMAND_DELAY = 0.05  # GG uses 50 ms on this device

# --------------------------------------------------------------------------
# DO NOT SEND. Checked on every outgoing packet, --force cannot override.
# --------------------------------------------------------------------------
BLOCKED_OPCODES = {
    0x01: "reset MCU / reboot into bootloader",
    0x02: "firmware-update (Fizz) sequence",
    0xFD: "restore factory defaults",
}
BLOCKED_RANGES = [(0x00, 0x08), (0xF0, 0xFF)]  # conservative
ALLOWED_IN_BLOCKED_RANGE = set()  # nothing; 0x09 (save) is outside the range


class Blocked(Exception):
    pass


def check_not_blocked(packet: bytes) -> None:
    if len(packet) < 2:
        raise Blocked("packet too short")
    if packet[0] != REPORT_ID:
        raise Blocked(f"report id 0x{packet[0]:02X} refused (only 0x{REPORT_ID:02X} allowed)")
    op = packet[1]
    if op in BLOCKED_OPCODES:
        raise Blocked(f"opcode 0x{op:02X} is DO-NOT-SEND ({BLOCKED_OPCODES[op]})")
    for lo, hi in BLOCKED_RANGES:
        if lo <= op <= hi and op not in ALLOWED_IN_BLOCKED_RANGE:
            raise Blocked(f"opcode 0x{op:02X} is in the blocked range 0x{lo:02X}-0x{hi:02X}")


# --------------------------------------------------------------------------
# Encoders
# --------------------------------------------------------------------------
TIMER_MIN_TO_CODE = {0: 0, 1: 1, 5: 2, 10: 3, 15: 4, 30: 5, 60: 6}
TIMER_CODE_TO_MIN = {v: k for k, v in TIMER_MIN_TO_CODE.items()}


def parse_int(s: str) -> int:
    return int(s, 0)


def enum(mapping: dict[str, int]):
    def parse(s: str) -> int:
        key = s.lower()
        if key in mapping:
            return mapping[key]
        v = parse_int(s)
        if v not in mapping.values():
            raise ValueError(f"expected one of {sorted(mapping)} or {sorted(mapping.values())}")
        return v
    return parse


def rng(lo: int, hi: int):
    def check(v: int, force: bool) -> None:
        if not (lo <= v <= hi) and not force:
            raise ValueError(f"value {v} outside {lo}..{hi} (use --force to override)")
        if not (0 <= v <= 0xFF):
            raise ValueError("value must fit in one byte")
    return check


class Setting:
    def __init__(self, name, opcode, help, parse=parse_int, check=None, encode=None):
        self.name, self.opcode, self.help = name, opcode, help
        self.parse, self.check = parse, check
        self.encode = encode or (lambda v: [v])

    def build(self, raw: str, force: bool) -> bytes:
        v = self.parse(raw)
        if self.check:
            self.check(v, force)
        args = self.encode(v)
        return make_packet(self.opcode, args)


def _sidetone(v):   # 0 = off (keep a valid level), 1..10 = on at level
    return [0, 1] if v == 0 else [1, v]


def _noise_red(v):  # UI 0..3 -> [enabled, level]
    return [0, 1] if v == 0 else [1, v]


def _timer(v):
    return [TIMER_MIN_TO_CODE[v]]


def _check_timer(v, force):
    if v not in TIMER_MIN_TO_CODE:
        raise ValueError(f"minutes must be one of {sorted(TIMER_MIN_TO_CODE)}")


def _parse_mix(s: str):
    parts = [int(p) for p in s.split(",")]
    if len(parts) != 3:
        raise ValueError("stream-mix wants main,aux,mic e.g. 100,80,100")
    return parts


def _check_mix(v, force):
    for p in v:
        if not (0 <= p <= 100):
            raise ValueError("each stream-mix level must be 0..100")


def _mix(v):
    main, aux, mic = v
    return [main, main, aux, mic]  # GG sends main twice


# Allowlist. Every opcode here is from protocol-notes.md section 3.4.
ALLOWLIST = {s.name: s for s in [
    Setting("sidetone", 0x38, "boom-mic sidetone 0=off, 1..10", check=rng(0, 10), encode=_sidetone),
    Setting("mic-volume", 0x37, "mic volume 1..10", check=rng(1, 10)),
    Setting("noise-reduction", 0x3C, "mic noise reduction 0=off,1=low,2=med,3=high",
            check=rng(0, 3), encode=_noise_red),
    Setting("mic-led", 0xBF, "muted-mic LED brightness 0..10", check=rng(0, 10)),
    Setting("anc-mode", 0xBD, "off|transparency|anc (0|1|2)",
            parse=enum({"off": 0, "transparency": 1, "anc": 2}), check=rng(0, 2)),
    Setting("anc-level", 0xB8, "ANC strength 1..3", check=rng(1, 3)),
    Setting("transparency-level", 0xB9, "transparency 1..10", check=rng(1, 10)),
    Setting("auto-off", 0xC1, "minutes: 0(never),1,5,10,15,30,60", check=_check_timer, encode=_timer),
    Setting("volume-limiter", 0x27, "0=off 1=on", check=rng(0, 1)),
    Setting("line-out", 0x43, "speakers|streaming (1|2)",
            parse=enum({"speakers": 1, "streaming": 2}), check=rng(1, 2)),
    Setting("stream-mix", 0x47, "main,aux,mic each 0..100", parse=_parse_mix, check=_check_mix, encode=_mix),
    Setting("oled-brightness", 0x85, "1..10", check=rng(1, 10)),
    Setting("screensaver-timer", 0x83, "minutes: 0,1,5,10,15,30,60", check=_check_timer, encode=_timer),
    Setting("screensaver-mode", 0x88, "off|dim (0|1)", parse=enum({"off": 0, "dim": 1}), check=rng(0, 1)),
    Setting("home-view", 0x89, "detailed|simple (0|1)", parse=enum({"detailed": 0, "simple": 1}), check=rng(0, 1)),
    Setting("home-option", 0x8A, "stereo|preset|meters (0|1|2)",
            parse=enum({"stereo": 0, "preset": 1, "meters": 2}), check=rng(0, 2)),
    Setting("bt-power-default", 0xB2, "0|1", check=rng(0, 1)),
    Setting("bt-call", 0xB3, "nothing|lower|mute (0|1|2)",
            parse=enum({"nothing": 0, "lower": 1, "mute": 2}), check=rng(0, 2)),
    Setting("save", 0x09, "persist settings to flash (value ignored, use 1)",
            check=rng(0, 255), encode=lambda v: []),
]}

# Read-only queries: name -> (opcode, kind, decoder)
#   kind "input"   : 64-byte output query, reply is a 64-byte input report
#   kind "feature" : 64-byte output query, reply read via GET_FEATURE (1036)


def make_packet(opcode: int, args) -> bytes:
    pkt = bytes([REPORT_ID, opcode, *args])
    if len(pkt) > PACKET_LEN:
        raise ValueError("packet too long")
    return pkt + bytes(PACKET_LEN - len(pkt))


def hexdump(b: bytes, trim=True) -> str:
    if trim:
        end = len(b)
        while end > 2 and b[end - 1] == 0:
            end -= 1
        shown = b[:end]
        suffix = f"  (+{len(b) - end} zero bytes, total {len(b)})" if end < len(b) else f"  ({len(b)} bytes)"
    else:
        shown, suffix = b, f"  ({len(b)} bytes)"
    return " ".join(f"{x:02X}" for x in shown) + suffix


# ---------------------------- decoders ------------------------------------
LINK = {1: "unpaired, not searching", 2: "unpaired, pairing", 4: "paired, disconnected", 8: "paired, CONNECTED"}
CHARGE = {1: "unknown / headset not connected", 2: "cable charging", 4: "plugged in, not charging (full)",
          8: "discharging (on battery)"}
BTMODE = {1: "off", 2: "pairing", 4: "link mode"}
BTLINK = {1: "ready", 2: "lost", 4: "busy", 8: "error"}
ANCMODE = {0: "off", 1: "transparency", 2: "ANC"}


def dec_status(r: bytes) -> list[str]:
    g = lambda i: r[i] if len(r) > i else None
    return [
        f"headset battery     : {g(6)} %",
        f"charging status     : {g(15)} = {CHARGE.get(g(15), '?')}",
        f"2.4G link           : {g(14)} = {LINK.get(g(14), '?')}",
        f"charger battery (?) : {g(7)} %",
        f"ANC/transp. mode    : {g(10)} = {ANCMODE.get(g(10), '?')}",
        f"ANC level           : {g(16)}",
        f"transparency level  : {g(8)}",
        f"mic muted           : {g(9)}",
        f"muted-mic LED       : {g(11)}",
        f"auto-off            : code {g(12)} = {TIMER_CODE_TO_MIN.get(g(12), '?')} min",
        f"wireless mode       : {g(13)} (0 speed, 1 range)",
        f"BT mode / link      : {BTMODE.get(g(4), g(4))} / {BTLINK.get(g(5), g(5))}",
        f"BT power default    : {g(2)}   BT call: {g(3)}",
    ]


def _ascii(b: bytes) -> str:
    return b.split(b"\x00")[0].decode("ascii", "replace")


def dec_firmware(r: bytes) -> list[str]:
    names = ["hub MCU-1", "hub MCU-2", "hub DSP", "headset MCU", "headset BT"]
    return [f"{n:12}: {_ascii(r[2 + 12 * i: 14 + 12 * i])!r}" for i, n in enumerate(names)]


def dec_ux(r: bytes) -> list[str]:
    return [
        f"screensaver timer : code {r[2]} = {TIMER_CODE_TO_MIN.get(r[2], '?')} min",
        f"OLED brightness   : {r[3]}",
        f"home view         : {r[5]} (0 detailed, 1 simple)",
        f"colour spin       : {r[9]}",
        f"screensaver mode  : {r[10]} (0 off, 1 dim)",
        f"home option       : {r[11]} (0 stereo, 1 preset, 2 meters)",
    ]


def dec_serial(r: bytes) -> list[str]:
    return [f"unique id: {_ascii(r[2:21])!r}"]


def _i8(x):
    return x - 256 if x > 127 else x


def _bands(r: bytes, off: int) -> list[str]:
    out = []
    for i in range(10):
        b = r[off + 6 * i: off + 6 * i + 6]
        if len(b) < 6:
            break
        f = b[0] | b[1] << 8
        q = (b[4] | b[5] << 8) / 1000
        out.append(f"  band {i + 1:2}: {f:5} Hz{' (off)' if f > 20000 else ''} type {b[2]} "
                   f"gain {_i8(b[3]) / 10:+.1f} dB Q {q:.3f}")
    return out


def dec_audio(r: bytes) -> list[str]:
    o = 2  # assumes r[0] = report id, r[1] = 0x20 (see open question 1)
    lines = [f"echo byte: 0x{r[1]:02X} (expect 0x20; if not, offsets are shifted)"]
    base = o + 140
    names = ["audio input", "hub volume", "volume limiter", "surround", "mic volume", "sidetone level",
             "line-out mode", "2.4G preset", "mic preset", "BT preset", "chatmix game", "chatmix chat"]
    for i, n in enumerate(names):
        lines.append(f"{n:15}: {r[base + i]}")
    lines += [f"stream main/aux/mic: {r[base + 14]}/{r[base + 16]}/{r[base + 17]}",
              f"mic NR enabled/level: {r[base + 23]}/{r[base + 24]}",
              f"sidetone on: {r[base + 28]}",
              "BT gains : " + " ".join(f"{_i8(x) / 10:+.1f}" for x in r[o + 120:o + 130]),
              "mic gains: " + " ".join(f"{_i8(x) / 10:+.1f}" for x in r[o + 130:o + 140]),
              "active 2.4G parametric EQ:"] + _bands(r, o + 60)
    return lines


def _eq_head(r: bytes) -> list[str]:
    return [f"echo 0x{r[1]:02X}, selected preset {r[2]}, short {_ascii(r[3:9])!r}, name {_ascii(r[9:70])!r}"]


def dec_eq24(r):
    return _eq_head(r) + _bands(r, 70)


def dec_eq_graphic(r):
    return _eq_head(r) + ["gains: " + " ".join(f"{_i8(x) / 10:+.1f}" for x in r[70:80])]


def dec_eq_name(r):
    return [f"echo 0x{r[1]:02X}, slot {r[2]}, class {r[3]}, short {_ascii(r[4:10])!r}, name {_ascii(r[10:71])!r}"]


READS = {
    "status": (0xB0, "input", dec_status, "battery / charging / link / ANC state"),
    "firmware": (0x10, "input", dec_firmware, "firmware version strings"),
    "ux": (0x80, "input", dec_ux, "OLED / UX settings"),
    "serial": (0x12, "input", dec_serial, "unique id"),
    "audio": (0x20, "feature", dec_audio, "full audio settings (feature report)"),
    "eq-24g": (0x1A, "feature", dec_eq24, "2.4G parametric EQ (feature report)"),
    "eq-bt": (0x1E, "feature", dec_eq_graphic, "Bluetooth 10-band EQ (feature report)"),
    "eq-mic": (0x1C, "feature", dec_eq_graphic, "mic 10-band EQ (feature report)"),
    "eq-name": (0x18, "feature", dec_eq_name, "preset name, arg slot 0..3"),
}

EVENT_NAMES = {0xB5: "connection", 0xB7: "battery", 0xBB: "mic mute", 0x45: "chatmix dial", 0x25: "hub volume",
               0x23: "audio input", 0x38: "sidetone", 0x37: "mic volume", 0x27: "volume limiter",
               0xBF: "mic LED", 0xB8: "ANC level", 0xB9: "transparency", 0xBD: "ANC mode",
               0x3C: "noise reduction", 0xC1: "auto-off", 0x43: "line-out", 0x47: "stream mix",
               0x85: "OLED brightness", 0x83: "screensaver timer", 0x88: "screensaver mode",
               0x89: "home view", 0x8A: "home option", 0xB2: "BT power default", 0xB3: "BT call",
               0x1B: "2.4G EQ changed", 0x1D: "mic EQ changed", 0x1F: "BT EQ changed"}


# ---------------------------- hid plumbing --------------------------------
def import_hid():
    try:
        import hid  # cython-hidapi ("hidapi" on PyPI)
        return hid
    except ImportError:
        # Convenience: if the bundled venv exists, re-run ourselves inside it.
        import os
        venv_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".venv", "bin", "python")
        venv_dir = os.path.dirname(os.path.dirname(venv_py))
        if os.path.exists(venv_py) and os.path.realpath(sys.prefix) != os.path.realpath(venv_dir) \
                and not os.environ.get("PROBE_NO_REEXEC"):
            os.environ["PROBE_NO_REEXEC"] = "1"
            os.execv(venv_py, [venv_py, os.path.abspath(__file__), *sys.argv[1:]])
        sys.exit("error: python hid bindings missing. Run:\n"
                 "  python3 -m venv tools/.venv && tools/.venv/bin/pip install -r tools/requirements.txt\n"
                 "  tools/.venv/bin/python tools/probe.py ...")


def enumerate_steelseries(hid):
    return hid.enumerate(VID, 0)


def pick(hid, usage_page: int, path: str | None):
    cands = []
    for d in enumerate_steelseries(hid):
        pid = d["product_id"]
        if pid in PID_REFUSED:
            continue
        if pid != PID_HUB:
            continue
        if path and d["path"].decode(errors="replace") != path:
            continue
        up = d.get("usage_page") or 0
        if up == usage_page or (up == 0 and d.get("interface_number") == HID_INTERFACE
                                and usage_page == USAGE_PAGE_CMD):
            cands.append(d)
    refused = [d for d in enumerate_steelseries(hid) if d["product_id"] in PID_REFUSED]
    for d in refused:
        print(f"note: ignoring PID 0x{d['product_id']:04X} ({PID_REFUSED[d['product_id']]}) - never opened",
              file=sys.stderr)
    if not cands:
        sys.exit(f"error: no Omni GameHub (1038:{PID_HUB:04X}) collection with usage page "
                 f"0x{usage_page:04X} found. Try `probe.py list`.")
    return cands[0]


class Hub:
    def __init__(self, hid, info):
        self.info = info
        self.dev = hid.device()
        self.dev.open_path(info["path"])
        self.dev.set_nonblocking(False)

    def close(self):
        self.dev.close()

    # The ONLY write path in this tool.
    def write_output(self, pkt: bytes, really: bool, label: str) -> bool:
        check_not_blocked(pkt)
        print(f"{'TX' if really else 'DRY-RUN TX'} [{label}] output report: {hexdump(pkt)}")
        if not really:
            return False
        n = self.dev.write(list(pkt))
        if n < 0:
            raise OSError(f"hid write failed: {self.dev.error()}")
        time.sleep(INTER_COMMAND_DELAY)
        return True

    def read_input(self, expect_op: int, timeout_s=1.0) -> bytes | None:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            data = self.dev.read(PACKET_LEN * 2, int(max(1, (deadline - time.time()) * 1000)))
            if not data:
                continue
            b = bytes(data)
            print(f"RX input report: {hexdump(b)}")
            if len(b) > 1 and b[0] == REPORT_ID and b[1] == expect_op:
                return b
        return None

    def read_feature(self, opcode: int) -> bytes:
        data = self.dev.get_feature_report(REPORT_ID, FEATURE_LEN + 4)
        b = bytes(data)
        print(f"RX feature report: {hexdump(b)}")
        # On macOS the reply omits the report ID and starts with the opcode echo (confirmed on
        # hardware). Re-insert it so the decoders' offsets (report ID at byte 0) hold either way.
        if not (len(b) > 1 and b[0] == REPORT_ID and b[1] == opcode) and b[:1] == bytes([opcode]):
            b = bytes([REPORT_ID]) + b
        return b


# ---------------------------- commands ------------------------------------
def cmd_list(args):
    hid = import_hid()
    devs = enumerate_steelseries(hid)
    if not devs:
        print("No SteelSeries (VID 0x1038) HID devices found.")
        return 0
    print(f"{'PID':6} {'if':>3} {'upage':6} {'usage':6} {'role':34} product / path")
    for d in sorted(devs, key=lambda d: (d["product_id"], d.get("interface_number", -1), d.get("usage_page", 0))):
        pid, up, us = d["product_id"], d.get("usage_page", 0), d.get("usage", 0)
        role = KNOWN_PIDS.get(pid, "")
        if pid == PID_HUB:
            role += {USAGE_PAGE_CMD: " [COMMANDS]", USAGE_PAGE_EVT: " [EVENTS]"}.get(up, "")
        if pid in PID_REFUSED:
            role += " !! REFUSED"
        print(f"0x{pid:04X} {d.get('interface_number', -1):>3} 0x{up:04X} 0x{us:04X} {role:34} "
              f"{d.get('product_string') or ''} | {d['path'].decode(errors='replace')}")
    return 0


def cmd_read(args):
    if args.what not in READS:
        sys.exit(f"error: unknown read '{args.what}'. Choose from: {', '.join(READS)}")
    op, kind, dec, _ = READS[args.what]
    qargs = []
    if args.what == "eq-name":
        if args.arg is None or not (0 <= parse_int(args.arg) <= 3):
            sys.exit("error: eq-name needs a slot 0..3 (0 2.4G custom, 1 BT custom, 2 2.4G game, 3 mic custom)")
        qargs = [parse_int(args.arg)]
    pkt = make_packet(op, qargs)
    hid = import_hid()
    hub = Hub(hid, pick(hid, USAGE_PAGE_CMD, args.path))
    try:
        hub.write_output(pkt, really=True, label=f"read {args.what}")
        reply = hub.read_input(op) if kind == "input" else hub.read_feature(op)
        if not reply:
            print("no matching reply (timeout)")
            return 1
        for line in dec(reply):
            print("  " + line)
    finally:
        hub.close()
    return 0


def cmd_send(args):
    if args.list or not args.feature:
        print("Allowlisted settings (see protocol-notes.md section 3.4):")
        for s in ALLOWLIST.values():
            print(f"  {s.name:20} op 0x{s.opcode:02X}  {s.help}")
        return 0
    s = ALLOWLIST.get(args.feature)
    if not s:
        sys.exit(f"error: '{args.feature}' is not in the allowlist. Refusing. (`send --list`)")
    if args.value is None:
        sys.exit("error: value required")
    try:
        pkt = s.build(args.value, args.force)
    except ValueError as e:
        sys.exit(f"error: {e}")
    return _transmit(pkt, args, label=f"send {s.name}")


def cmd_raw(args):
    if not args.force:
        sys.exit("error: raw packets need --force (and --really to transmit). DO-NOT-SEND stays blocked.")
    try:
        body = [parse_int(x if x.lower().startswith("0x") else "0x" + x) for x in args.bytes]
    except ValueError:
        sys.exit("error: raw bytes must be hex, e.g. `raw 01 38 01 05`")
    if not body or body[0] != REPORT_ID:
        sys.exit(f"error: first byte must be the report id 0x{REPORT_ID:02X}")
    pkt = make_packet(body[1] if len(body) > 1 else 0, body[2:])
    return _transmit(pkt, args, label="raw")


def _transmit(pkt: bytes, args, label: str):
    try:
        check_not_blocked(pkt)
    except Blocked as e:
        sys.exit(f"BLOCKED: {e}")
    if not args.really:
        print(f"DRY-RUN TX [{label}] output report: {hexdump(pkt)}")
        print("(dry run - add --really to send)")
        return 0
    hid = import_hid()
    hub = Hub(hid, pick(hid, USAGE_PAGE_CMD, args.path))
    try:
        hub.write_output(pkt, really=True, label=label)
    finally:
        hub.close()
    return 0


def cmd_listen(args):
    hid = import_hid()
    info = pick(hid, USAGE_PAGE_EVT, args.path)
    dev = hid.device()
    dev.open_path(info["path"])  # read-only use: this function never writes
    print(f"listening on events collection for {args.seconds}s ... (change something on the hub)")
    end = time.time() + args.seconds
    try:
        while time.time() < end:
            data = dev.read(PACKET_LEN * 2, 250)
            if data:
                b = bytes(data)
                name = EVENT_NAMES.get(b[1], "?") if len(b) > 1 else "?"
                print(f"EVT {name:18} {hexdump(b)}", flush=True)
    finally:
        dev.close()
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="probe.py",
        description="Careful HID probe for the Arctis Nova Pro Omni GameHub (1038:2290). "
                    "Writes are dry-run unless --really. DO-NOT-SEND opcodes are always blocked.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="reads: " + ", ".join(f"{k} ({v[3]})" for k, v in READS.items()) +
               "\nsettings: " + ", ".join(ALLOWLIST))
    p.add_argument("--path", help="exact hidapi path to use (from `list`)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="enumerate VID 0x1038 HID entries (interface, usage page)")

    r = sub.add_parser("read", help="read-only query")
    r.add_argument("what", choices=list(READS))
    r.add_argument("arg", nargs="?", help="slot for eq-name")

    s = sub.add_parser("send", help="write an allowlisted setting (dry-run unless --really)")
    s.add_argument("feature", nargs="?")
    s.add_argument("value", nargs="?")
    s.add_argument("--list", action="store_true", help="show the allowlist")
    s.add_argument("--really", action="store_true", help="actually transmit")
    s.add_argument("--force", action="store_true", help="allow out-of-range values (never DO-NOT-SEND)")

    w = sub.add_parser("raw", help="exploratory 64-byte output report; needs --force; blocked list still applies")
    w.add_argument("bytes", nargs="+", help="hex bytes starting with report id 01")
    w.add_argument("--really", action="store_true")
    w.add_argument("--force", action="store_true")

    l = sub.add_parser("listen", help="print unsolicited events from the 0xFF00 collection (read-only)")
    l.add_argument("--seconds", type=float, default=30)

    args = p.parse_args(argv)
    return {"list": cmd_list, "read": cmd_read, "send": cmd_send, "raw": cmd_raw, "listen": cmd_listen}[args.cmd](args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Blocked as e:
        sys.exit(f"BLOCKED: {e}")
