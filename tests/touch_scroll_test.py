#!/usr/bin/env python3
"""Feed real touch and mouse events to GTK via Broadway, without a browser.

Requires gtk4-broadwayd and python3-websocket. Run with GTK_A11Y=none or
GTK_A11Y=test; Broadway does not expose the platform AT-SPI backend.
"""
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import time

import websocket


class Broadway:
    def __init__(self, connection):
        self.connection = connection
        self.serial = 0
        self.surfaces = {}
        self.sequence = 0

    def send(self, opcode, *args):
        values = [opcode, self.serial, int(time.monotonic() * 1000) & 0x7fffffff, *args]
        self.connection.send_binary(struct.pack('>' + 'i' * len(values), *values))

    def receive(self, packet):
        if not isinstance(packet, bytes):
            return
        offset = 0

        def read(fmt):
            nonlocal offset
            values = struct.unpack_from('<' + fmt, packet, offset)
            offset += struct.calcsize('<' + fmt)
            return values[0] if len(values) == 1 else values

        while offset < len(packet):
            opcode, self.serial = read('BI')
            if opcode == 2:  # New surface; acknowledge its geometry.
                sid, x, y, width, height = read('HhhHH')
                self.surfaces[sid] = [x, y, width, height]
                self.send(11, sid, x, y, width, height)
            elif opcode in (3, 4, 5, 6, 7, 12):  # Visibility, stacking, keyboard.
                read('H')
            elif opcode == 8:  # Move/resize.
                sid, flags = read('HB')
                if flags & 1:
                    self.surfaces[sid][:2] = read('hh')
                if flags & 2:
                    self.surfaces[sid][2:] = read('HH')
                self.send(11, sid, *self.surfaces[sid])
            elif opcode == 9:  # Transient parent.
                read('HH')
            elif opcode == 13:  # Texture upload.
                read('I')
                size = read('I')
                offset += size
            elif opcode == 14:  # Texture release.
                read('I')
            elif opcode == 15:  # Render nodes; no rasterization needed.
                read('H')
                size = read('I')
                offset += size * 4
            elif opcode == 16:  # Frame acknowledgement.
                sid, tag = read('HI')
                self.send(14, sid, tag)
            elif opcode == 0:  # Grab pointer.
                read('HB')
                self.send(9)
            elif opcode == 1:  # Ungrab pointer.
                self.send(10)
            else:
                raise AssertionError(f'Unexpected Broadway opcode {opcode}')

    def input(self, kind, x, y):
        sid = next(iter(self.surfaces))
        self.sequence += 1
        self.send(0, sid, sid, x, y, x, y, 0, 0)  # Pointer enter.

        def touch(phase, tx, ty):
            self.send(5, phase, sid, self.sequence, 1, tx, ty, tx, ty, 0)

        if kind == 'mouse-drag':
            self.send(3, sid, sid, x, y, x, y, 0, 1)
            for step in range(1, 11):
                time.sleep(.015)
                self.send(2, sid, sid, x + step * 7, y, x + step * 7, y, 256)
            self.send(4, sid, sid, x + 70, y, x + 70, y, 256, 1)
            return
        touch(0, x, y)
        if kind == 'touch-drag':
            # Cross a glyph boundary before crossing GTK's drag threshold.
            time.sleep(.02)
            touch(1, x + 4, y + 5)
            for step in range(1, 11):
                time.sleep(.015)
                touch(1, x + 4, y + step * 8)
            x, y = x + 4, y + 80
        elif kind == 'hold':
            time.sleep(.45)
        else:
            assert kind == 'tap'
            time.sleep(.04)
        touch(2, x, y)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    display = ':' + str(os.getpid())
    server = subprocess.Popen(['gtk4-broadwayd', '--address=127.0.0.1',
                               f'--port={port}', display], stdout=subprocess.DEVNULL)
    app = connection = None
    try:
        for _ in range(100):
            try:
                connection = websocket.create_connection(
                    f'ws://127.0.0.1:{port}/socket', subprotocols=['broadway'], timeout=.02)
                break
            except (OSError, websocket.WebSocketException):
                if server.poll() is not None:
                    raise RuntimeError('Broadway server exited')
                time.sleep(.02)
        assert connection is not None, 'Broadway server did not start'
        client = Broadway(connection)
        client.send(12, 800, 600, 1)
        env = dict(os.environ, GDK_BACKEND='broadway', BROADWAY_DISPLAY=display)
        app = subprocess.Popen([binary, '--touch-scroll-ui'], env=env,
                               stdout=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 45
        inputs = 0
        while app.poll() is None:
            if time.monotonic() > deadline:
                raise TimeoutError('Touch scrolling fixture timed out')
            if select.select([app.stdout], [], [], 0)[0]:
                line = app.stdout.readline()
                if line.startswith('INPUT '):
                    _, kind, x, y = line.split()
                    client.input(kind, int(x), int(y))
                    inputs += 1
                else:
                    print(line, end='', flush=True)
            try:
                client.receive(connection.recv())
            except websocket.WebSocketTimeoutException:
                pass
        print(app.stdout.read(), end='')
        assert app.returncode == 0, f'Fixture exited with {app.returncode}'
        assert inputs == 15, f'Expected 15 input scenarios, ran {inputs}'
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            app.wait(timeout=5)
        if connection is not None:
            connection.close()
        server.terminate()
        server.wait(timeout=5)


if __name__ == '__main__':
    main()
