#!/usr/bin/env python3
"""
omnikit_golden.py - generate OmniKit's packet-level golden fixtures from probe.py.

Every case runs `probe.py` as a subprocess in DRY-RUN mode (no --really, so nothing
is ever transmitted and no device is opened) and records what probe.py prints:

  * "packet"   : probe.py built a 64-byte output report. We store the full hex.
  * "rejected" : probe.py refused the value (range / enum / timer-table check).
  * "blocked"  : probe.py's DO-NOT-SEND check refused the opcode.

The Swift tests (app/Tests/OmniKitTests/GoldenPacketTests.swift) then assert that
OmniKit produces byte-identical packets, rejects the same values and blocks the
same opcodes.

Usage:
  tools/.venv/bin/python tools/omnikit_golden.py            # rewrite the fixture
  tools/.venv/bin/python tools/omnikit_golden.py --check    # exit 1 if it changed
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "probe.py")
OUT = os.path.join(HERE, "..", "app", "Tests", "OmniKitTests", "Fixtures", "probe-golden.json")

TX_RE = re.compile(r"DRY-RUN TX \[[^\]]*\] output report: ([0-9A-F ]+?)\s+\((?:\+(\d+) zero bytes, )?total (\d+)\)"
                   r"|DRY-RUN TX \[[^\]]*\] output report: ([0-9A-F ]+?)\s+\((\d+) bytes\)")


def run_probe(argv: list[str]) -> dict:
    env = dict(os.environ, PROBE_NO_REEXEC="1")
    proc = subprocess.run([sys.executable, PROBE, *argv], capture_output=True, text=True, env=env)
    out = proc.stdout + proc.stderr
    m = TX_RE.search(out)
    if proc.returncode == 0 and m:
        if m.group(1) is not None:
            shown = bytes.fromhex(m.group(1).replace(" ", ""))
            total = int(m.group(3))
        else:
            shown = bytes.fromhex(m.group(4).replace(" ", ""))
            total = int(m.group(5))
        full = shown + bytes(total - len(shown))
        return {"result": "packet", "hex": full.hex().upper()}
    if "BLOCKED:" in out:
        return {"result": "blocked", "message": out.strip().splitlines()[-1]}
    if proc.returncode != 0:
        return {"result": "rejected", "message": out.strip().splitlines()[-1] if out.strip() else ""}
    raise SystemExit(f"unexpected probe.py output for {argv!r}:\n{out}")


def cases() -> list[dict]:
    c: list[dict] = []

    def send(feature: str, value: str):
        c.append({"id": f"send {feature} {value}", "kind": "send", "feature": feature, "value": value,
                  "argv": ["send", feature, value]})

    def rng(feature, lo, hi):
        for v in range(lo - 1, hi + 2):
            if v >= 0:
                send(feature, str(v))

    rng("sidetone", 0, 10)
    rng("mic-volume", 1, 10)
    rng("noise-reduction", 0, 3)
    rng("mic-led", 0, 10)
    rng("anc-mode", 0, 2)
    for name in ("off", "transparency", "anc"):
        send("anc-mode", name)
    rng("anc-level", 1, 3)
    rng("transparency-level", 1, 10)
    for m in (0, 1, 2, 5, 10, 15, 30, 45, 60, 90):
        send("auto-off", str(m))
        send("screensaver-timer", str(m))
    rng("volume-limiter", 0, 1)
    rng("line-out", 1, 2)
    for name in ("speakers", "streaming"):
        send("line-out", name)
    for mix in ("100,100,100", "0,0,0", "100,80,60", "55,5,95", "101,0,0", "0,101,0", "0,0,101"):
        send("stream-mix", mix)
    rng("oled-brightness", 1, 10)
    rng("screensaver-mode", 0, 1)
    for name in ("off", "dim"):
        send("screensaver-mode", name)
    rng("home-view", 0, 1)
    for name in ("detailed", "simple"):
        send("home-view", name)
    rng("home-option", 0, 2)
    for name in ("stereo", "preset", "meters"):
        send("home-option", name)
    rng("bt-power-default", 0, 1)
    rng("bt-call", 0, 2)
    for name in ("nothing", "lower", "mute"):
        send("bt-call", name)
    send("save", "1")

    # Read queries (probe's READS table), built through `raw` in dry-run mode.
    reads = {"status": [0xB0], "firmware": [0x10], "ux": [0x80], "serial": [0x12], "audio": [0x20],
             "eq-24g": [0x1A], "eq-bt": [0x1E], "eq-mic": [0x1C]}
    for name, body in reads.items():
        c.append({"id": f"read {name}", "kind": "read", "read": name,
                  "argv": ["raw", "01", *[f"{b:02X}" for b in body], "--force"]})
    for slot in range(4):
        c.append({"id": f"read eq-name {slot}", "kind": "read", "read": "eq-name", "slot": slot,
                  "argv": ["raw", "01", "18", f"{slot:02X}", "--force"]})

    # The DO-NOT-SEND check, for every possible opcode.
    for op in range(256):
        c.append({"id": f"opcode {op:02X}", "kind": "opcode", "opcode": op,
                  "argv": ["raw", "01", f"{op:02X}", "--force"]})
    return c


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the fixture is out of date")
    args = ap.parse_args()

    results = []
    for case in cases():
        results.append({**case, **run_probe(case["argv"])})

    doc = {
        "generator": "tools/omnikit_golden.py",
        "source": "tools/probe.py (dry run: no --really, nothing transmitted)",
        "cases": results,
    }
    text = json.dumps(doc, indent=1) + "\n"
    if args.check:
        with open(OUT) as f:
            if f.read() != text:
                print("probe-golden.json is out of date; rerun tools/omnikit_golden.py", file=sys.stderr)
                return 1
        print(f"ok: {len(results)} cases match")
        return 0
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write(text)
    counts: dict[str, int] = {}
    for r in results:
        counts[r["result"]] = counts.get(r["result"], 0) + 1
    print(f"wrote {os.path.relpath(OUT)}: {len(results)} cases {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
