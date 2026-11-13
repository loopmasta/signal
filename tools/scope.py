#!/usr/bin/env python3
"""Read an oscilloscope over the network (SCPI over a raw TCP socket, no dependencies).

The scope address: -H <host>, else $SCOPE_HOST. Port 5555 (Rigol, Siglent), -p to change.

  scope.py -H 192.168.1.60 idn
  scope.py -H ... idn                       # also shows each channel's probe ratio and V/div
  scope.py -H ... measure 2                 # Vpp, Vrms, frequency of channel 2
  scope.py -H ... scpi ":TIMebase:MAIN:SCALe?"   # any command (a "?" waits for the answer)

Dialects (picked from *IDN?): RIGOL, SIGLENT, KEYSIGHT / AGILENT; anything else is
tried as Rigol. Written from the manuals, not yet tried on a real scope.
"""
import os
import socket
import sys
import time


class Scope:
    def __init__(self, host, port=5555, timeout=5):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.idn = self.query("*IDN?")
        up = self.idn.upper()
        self.dialect = ("siglent" if "SIGLENT" in up else
                        "keysight" if ("KEYSIGHT" in up or "AGILENT" in up) else
                        "rigol")

    def write(self, cmd):
        self.sock.sendall(cmd.encode() + b"\n")

    def query(self, cmd):
        self.write(cmd)
        data = b""
        while not data.endswith(b"\n"):
            chunk = self.sock.recv(65536)
            if not chunk:
                break
            data += chunk
        return data.decode(errors="replace").strip()

    def measure(self, item, ch):
        """item: vpp, vrms or freq; ch: 1..4. Returns a float, or None when the scope has no value."""
        if self.dialect == "siglent":
            key = {"vpp": "PKPK", "vrms": "RMS", "freq": "FREQ"}[item]
            ans = self.query("C%d:PAVA? %s" % (ch, key))      # "C1:PAVA PKPK,1.2E+00V"
            val = ans.split(",")[-1] if "," in ans else ans
            val = val.rstrip("VHzs ")
        elif self.dialect == "keysight":
            key = {"vpp": "VPP", "vrms": "VRMS", "freq": "FREQuency"}[item]
            val = self.query(":MEASure:%s? CHANnel%d" % (key, ch))
        else:
            key = {"vpp": "VPP", "vrms": "VRMS", "freq": "FREQ"}[item]
            val = self.query(":MEASure:ITEM? %s,CHAN%d" % (key, ch))
        try:
            v = float(val)
        except ValueError:
            return None
        return None if abs(v) > 9e36 else v           # 9.9E37: no valid measurement

    def channel_info(self, ch):
        """Rigol DS1000Z: probe ratio, volts per division and whether the channel is shown
        (read only). Returns None on other scopes."""
        if self.dialect != "rigol":
            return None
        try:
            return {"probe": float(self.query(":CHANnel%d:PROBe?" % ch)),
                    "scale": float(self.query(":CHANnel%d:SCALe?" % ch)),
                    "on": self.query(":CHANnel%d:DISPlay?" % ch) in ("1", "ON")}
        except ValueError:
            return None

    def close(self):
        self.sock.close()


def main():
    argv = sys.argv[1:]
    host, port = os.environ.get("SCOPE_HOST"), 5555
    while argv and argv[0] in ("-H", "-p") and len(argv) >= 2:
        if argv[0] == "-H":
            host = argv[1]
        else:
            port = int(argv[1])
        argv = argv[2:]
    if not argv or argv[0] in ("-h", "--help") or not host:
        print(__doc__)
        return 0 if argv else 1
    try:
        s = Scope(host, port)
    except OSError as e:
        print("cannot reach the scope at %s:%d: %s" % (host, port, e), file=sys.stderr)
        return 1
    try:
        cmd = argv[0]
        if cmd == "idn":
            print(s.idn, "->", s.dialect)
            for ch in (1, 2):
                print("CH%d" % ch, s.channel_info(ch))
        elif cmd == "measure":
            ch = int(argv[1]) if len(argv) > 1 else 1
            print("channel", ch, s.channel_info(ch))
            for item in ("vpp", "vrms", "freq"):
                print("%-5s %s" % (item, s.measure(item, ch)))
        elif cmd == "scpi":
            c = " ".join(argv[1:])
            if "?" in c:
                print(s.query(c))
            else:
                s.write(c)
        else:
            print(__doc__)
            return 1
    finally:
        s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
