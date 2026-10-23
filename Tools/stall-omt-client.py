#!/usr/bin/env python3
"""Subscribe to an isolated OMT stress source without draining its TCP sockets.

This bounded fault injector tests whether a slow client disrupts healthy clients
or grows the publisher's queues. It does not touch the receiver app or source
settings. Run only against an explicitly selected, isolated test source.
"""
import argparse
import array
import fcntl
import json
import math
import socket
import struct
import termios
import time
from urllib.parse import urlsplit


def metadata_frame(command):
    payload = command.encode('utf-8')
    return struct.pack('<BBQHI', 1, 1, 0, 0, len(payload)) + payload


def connect_client(host, port):
    last_error = None
    for family, kind, protocol, _, endpoint in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM):
        client = socket.socket(family, kind, protocol)
        try:
            # Request the limit before TCP negotiates window scaling. The OS
            # can still choose a larger buffer; report the actual value.
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            client.settimeout(5)
            client.connect(endpoint)
            return client
        except OSError as error:
            last_error = error
            client.close()
    raise last_error or OSError('No TCP address resolved for the explicit source')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, help='Explicit omt://HOST:PORT of an isolated stress source')
    parser.add_argument('--seconds', type=float, default=30, help='Hold time, 1–120 seconds')
    parser.add_argument('--roles', nargs='+', choices=('video', 'audio'), default=['video', 'audio'])
    args = parser.parse_args()
    try:
        address = urlsplit(args.source)
        valid = (address.scheme == 'omt' and address.hostname and address.port
                 and not address.username and not address.password
                 and address.path in ('', '/') and not address.query and not address.fragment)
    except ValueError:
        valid = False
    if not valid:
        parser.error('--source must be an explicit omt://HOST:PORT')
    if not math.isfinite(args.seconds) or not 1 <= args.seconds <= 120:
        parser.error('--seconds must be finite and between 1 and 120')
    sockets = []
    started = time.monotonic()
    try:
        for role in dict.fromkeys(args.roles):
            client = connect_client(address.hostname, address.port)
            sockets.append((role, client))
            commands = (['<OMTSettings Preview="false" />', '<OMTSettings Quality="Medium" />',
                         '<OMTSubscribe Video="true" />'] if role == 'video'
                        else ['<OMTSubscribe Audio="true" />'])
            client.sendall(b''.join(metadata_frame(command) for command in commands))
            print(json.dumps({'event': 'subscribed-without-draining', 'role': role,
                              'receiveBufferBytes': client.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF),
                              'holdSeconds': args.seconds}), flush=True)
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            time.sleep(min(0.2, max(0, deadline - time.monotonic())))
        observed = []
        for role, client in sockets:
            client.settimeout(1)
            # MSG_PEEK proves data reached the blocked receive buffer without
            # draining queued media during the stress interval.
            header = client.recv(16, socket.MSG_PEEK)
            pending = array.array('i', [0])
            fcntl.ioctl(client.fileno(), termios.FIONREAD, pending, True)
            report = {'event': 'blocked-buffer-observed', 'role': role,
                      'peekedBytes': len(header), 'queuedBytes': pending[0],
                      'receiveBufferBytes': client.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF),
                      'elapsedSeconds': time.monotonic() - started}
            if len(header) == 16:
                version, kind, _, _, length = struct.unpack('<BBQHI', header)
                report.update(version=version, frameType=kind, declaredBodyBytes=length)
            observed.append(len(header) > 0)
            print(json.dumps(report), flush=True)
        return 0 if all(observed) else 1
    except (OSError, KeyboardInterrupt) as error:
        print(json.dumps({'event': 'ended', 'reason': str(error),
                          'elapsedSeconds': time.monotonic() - started}), flush=True)
        return 1
    finally:
        for _, client in sockets:
            client.close()
        print(json.dumps({'event': 'our-clients-closed', 'elapsedSeconds': time.monotonic() - started}), flush=True)


if __name__ == '__main__':
    raise SystemExit(main())
