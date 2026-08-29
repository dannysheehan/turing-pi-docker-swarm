#!/usr/bin/env python3
"""Probe a UDP syslog receiver.

UDP is fire-and-forget: a wrong port produces no error anywhere, the logs
simply vanish. That is precisely how this cluster spent time forwarding to a
closed port. A connected UDP socket surfaces ICMP port-unreachable as
ECONNREFUSED on a subsequent operation, which is the only cheap way to tell
the difference between "accepting" and "silently discarding".

Exit 0 if the receiver appears to accept, 1 if it actively rejects.
"""
import socket
import sys
import time

host, port = sys.argv[1], int(sys.argv[2])
probe = b"<14>1 - - - - - - syslog receiver reachability probe\n"

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
try:
    s.connect((host, port))
    s.send(probe)
    time.sleep(1.0)
    s.send(probe)
    time.sleep(1.0)
    s.recv(1)
except ConnectionRefusedError:
    print(f"{host}:{port}/udp actively refused (ICMP port unreachable)")
    sys.exit(1)
except socket.timeout:
    print(f"{host}:{port}/udp accepting")
    sys.exit(0)
except Exception as exc:  # noqa: BLE001 - report anything else verbatim
    print(f"{host}:{port}/udp probe failed: {type(exc).__name__}: {exc}")
    sys.exit(1)
finally:
    s.close()
print(f"{host}:{port}/udp accepting")
