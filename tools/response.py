#!/usr/bin/env python3
"""Frequency response of what sits between the norns and the scope.

norns plays a sine at each frequency, the scope measures. With --in and --out the gain
is out / in (the filter's response); with --out only, the output level is listed.

  response.py --norns 192.168.1.50 --scope 192.168.1.60 --out 2 --in 1 \\
      --from 100 --to 5000 --points 20 --level -30

The output is switched on at the start and always off again at the end. Set the
scope's vertical scale and timebase first (this tool does not touch them), and put a
few periods of the lowest frequency on the screen.
"""
import argparse
import importlib.util
import math
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--norns", default=os.environ.get("PULSE_HOST"))
    ap.add_argument("--scope", default=os.environ.get("SCOPE_HOST"))
    ap.add_argument("--out", type=int, required=True, help="scope channel after the filter")
    ap.add_argument("--in", dest="inp", type=int, help="scope channel before the filter")
    ap.add_argument("--from", dest="lo", type=float, default=100)
    ap.add_argument("--to", dest="hi", type=float, default=5000)
    ap.add_argument("--points", type=int, default=15)
    ap.add_argument("--level", type=float, default=-30, help="dBFS (default -30)")
    ap.add_argument("--settle", type=float, default=1.5, help="seconds before each reading")
    ap.add_argument("--csv", help="also write the table to this file")
    a = ap.parse_args()
    if not a.norns or not a.scope:
        ap.error("--norns and --scope (or $PULSE_HOST / $SCOPE_HOST) are needed")

    ctl = load("pulse_ctl")
    try:
        sc = load("scope").Scope(a.scope)
    except OSError as e:
        print("cannot reach the scope at %s: %s" % (a.scope, e), file=sys.stderr)
        return 1
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def send(path, *args):
        sock.sendto(ctl.encode(path, list(args)), (a.norns, ctl.NORNS_PORT))

    freqs = [a.lo * (a.hi / a.lo) ** (i / max(a.points - 1, 1)) for i in range(a.points)]
    rows = []
    try:
        send("/pulse/wave", "sine")
        send("/pulse/tone2", 0)
        send("/pulse/sweep", "off")
        send("/pulse/level", float(a.level))
        send("/pulse/hz", float(freqs[0]))
        send("/pulse/on", 1)
        print("scope: %s" % sc.idn)
        info = {}
        for ch in filter(None, (a.inp, a.out)):
            info[ch] = sc.channel_info(ch)
            print("CH%d: %s" % (ch, info[ch]))
            if info[ch] and not info[ch]["on"]:
                print("  warning: CH%d is not displayed" % ch)
        print("the probe switch (1x / 10x) must match the scope's probe ratio above")
        print("%9s %10s %10s %10s" % ("Hz", "out Vpp", "in Vpp", "gain dB"))
        for f in freqs:
            send("/pulse/hz", float(round(f, 1)))
            time.sleep(a.settle)
            vout = sc.measure("vpp", a.out)
            vin = sc.measure("vpp", a.inp) if a.inp else None
            gain = (20 * math.log10(vout / vin)
                    if vout and vin and vin > 0 else None)
            rows.append((f, vout, vin, gain))
            for ch, v in ((a.out, vout), (a.inp, vin)):
                i = info.get(ch)
                if v is None:
                    print("  CH%s: no reading (signal missing or out of the screen)" % ch)
                elif i and v > 7.5 * i["scale"]:
                    print("  CH%s: %.3f Vpp is clipped on %g V/div, don't trust it" % (ch, v, i["scale"]))
                elif i and v < 0.8 * i["scale"]:
                    print("  CH%s: %.3f Vpp is under 1 division (%g V/div): coarse reading" % (ch, v, i["scale"]))
            fmt = lambda v, p: "-" if v is None else p % v
            print("%9.1f %10s %10s %10s" % (f, fmt(vout, "%.4f"), fmt(vin, "%.4f"),
                                            fmt(gain, "%+.2f")))
    finally:
        send("/pulse/on", 0)
        sc.close()

    if a.csv:
        with open(a.csv, "w") as fh:
            fh.write("hz,out_vpp,in_vpp,gain_db\n")
            for r in rows:
                fh.write(",".join("" if v is None else repr(v) for v in r) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
