#!/usr/bin/env python3
"""Control the signal script on a norns over the network (OSC over UDP, no dependencies).

The norns address: -H <host> as the first arguments, else $SIGNAL_HOST, else norns.local.
Without -H the first word below is the command, not the host.

  signal_ctl.py -H 192.168.1.50 on
  signal_ctl.py norns.local on
  signal_ctl.py norns.local hz 1750
  signal_ctl.py norns.local level -20
  signal_ctl.py norns.local wave square
  signal_ctl.py norns.local sweep up 300 3000 5
  signal_ctl.py norns.local burst 500
  signal_ctl.py norns.local get          # prints the state
  signal_ctl.py norns.local raw /signal/hz2 f 2200

Several commands in one go: separate them with a lone "+":
  signal_ctl.py norns.local wave sine + hz 1000 + level -20 + on
"""
import os
import socket
import struct
import sys

NORNS_PORT = 10111
REPLY_PORT = 9000
STATE_FIELDS = ["on", "wave", "hz", "level", "tone2", "hz2",
                "sweep", "from", "to", "time", "burst_ms", "retrig"]


def pad(b):
    return b + b"\0" * (4 - len(b) % 4)


def encode(path, args):
    tags, data = ",", b""
    for a in args:
        if isinstance(a, int):
            tags += "i"
            data += struct.pack(">i", a)
        elif isinstance(a, float):
            tags += "f"
            data += struct.pack(">f", a)
        else:
            tags += "s"
            data += pad(str(a).encode())
    return pad(path.encode()) + pad(tags.encode()) + data


def decode(packet):
    def string(i):
        end = packet.index(b"\0", i)
        return packet[i:end].decode(), (end + 4) & ~3

    path, i = string(0)
    tags, i = string(i)
    out = []
    for t in tags[1:]:
        if t == "i":
            out.append(struct.unpack(">i", packet[i:i + 4])[0])
            i += 4
        elif t == "f":
            out.append(struct.unpack(">f", packet[i:i + 4])[0])
            i += 4
        elif t == "s":
            s, i = string(i)
            out.append(s)
    return path, out


def number(s):
    try:
        return int(s)
    except ValueError:
        try:
            return float(s)
        except ValueError:
            return s


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 1
    if argv[0] == "-H" and len(argv) >= 3:
        host, rest = argv[1], argv[2:]
    elif os.environ.get("SIGNAL_HOST"):
        host, rest = os.environ["SIGNAL_HOST"], argv
    else:
        host, rest = argv[0], argv[1:]

    commands, cur = [], []
    for w in rest:
        if w == "+":
            commands.append(cur)
            cur = []
        else:
            cur.append(w)
    commands.append(cur)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for cmd in commands:
        if not cmd:
            continue
        name, args = cmd[0], [number(a) for a in cmd[1:]]
        if name == "raw":
            path = cmd[1]
            tags = cmd[2] if len(cmd) > 2 else ""
            vals = []
            for t, v in zip(tags, cmd[3:]):
                vals.append(int(v) if t == "i" else float(v) if t == "f" else v)
            packet = encode(path, vals)
        else:
            packet = encode("/signal/" + name, args)
        if name == "get":
            sock.bind(("", REPLY_PORT))
            sock.settimeout(2)
        try:
            sock.sendto(packet, (host, NORNS_PORT))
        except OSError as e:
            print("cannot reach %s: %s" % (host, e), file=sys.stderr)
            return 1
        if name == "get":
            try:
                data, _ = sock.recvfrom(2048)
            except socket.timeout:
                print("no answer (is signal running? is port %d free?)" % REPLY_PORT,
                      file=sys.stderr)
                return 1
            _, vals = decode(data)
            for k, v in zip(STATE_FIELDS, vals):
                print("%-9s %s" % (k, round(v, 3) if isinstance(v, float) else v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
