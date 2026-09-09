#!/usr/bin/env python3
"""Synthetic progress emitter for ticket 12.

Throwaway. Stands in for omafiled so the QML side can be measured without the
engine existing yet. Emits newline-delimited JSON at a fixed rate and reports
what it actually managed to send, so the client's numbers can be checked
against the server's rather than trusted on their own.

  ./emit.py <socket-path> <events-per-second> [seconds]
"""
import json, os, socket, sys, time

path = sys.argv[1]
rate = float(sys.argv[2])
secs = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0

try:
    os.unlink(path)
except FileNotFoundError:
    pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(1)
print(f"listening on {path}, {rate:g} events/s for {secs:g}s", flush=True)

conn, _ = srv.accept()
print("client connected", flush=True)

interval = 1.0 / rate
sent = 0
blocked = 0
start = time.monotonic()
next_at = start
try:
    while time.monotonic() - start < secs:
        now = time.monotonic()
        if now < next_at:
            time.sleep(min(next_at - now, 0.002))
            continue
        msg = {
            "t": "progress",
            "job": "j1",
            "file": f"GH0104{sent % 90:02d}.MP4",
            "done": (sent % 1000) / 1000.0,
            "rate": 41_000_000,
            "seq": sent,
        }
        line = (json.dumps(msg) + "\n").encode()
        try:
            conn.sendall(line)
        except BlockingIOError:
            blocked += 1
        except BrokenPipeError:
            print("client went away", flush=True)
            break
        sent += 1
        next_at += interval
finally:
    elapsed = time.monotonic() - start
    print(f"SERVER sent={sent} in {elapsed:.2f}s = {sent/elapsed:.0f}/s blocked={blocked}", flush=True)
    try:
        conn.close()
    finally:
        srv.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
