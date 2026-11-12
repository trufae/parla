#!/usr/bin/env python3
"""Real pointer/wheel regression test with an isolated offline conversation.

    python3 tests/conversation_scroll_test.py builddir/core-compat-test [bubbles|irc|workspace]

Requires gtk4-broadwayd and websocket-client; no real accounts are opened.
"""
import os
from pathlib import Path
import select
import shlex
import socket
import subprocess
import sys
import tempfile
import time

import websocket
from touch_scroll_test import Broadway


def main():
    style = sys.argv[2] if len(sys.argv) > 2 else 'bubbles'
    assert style in ('bubbles', 'irc', 'workspace')
    with tempfile.TemporaryDirectory(prefix='parla-scroll-') as folder:
        root = Path(folder)
        core = root / 'core'
        core.write_text('#!/bin/sh\nexec ' + shlex.join([
            sys.executable, str(Path(__file__).with_name('search_ui_test.py').resolve()),
            '--fake-scroll-core']) + '\n')
        core.chmod(0o700)
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
                    time.sleep(.02)
            assert connection is not None
            client = Broadway(connection)
            client.send(12, 1100, 800, 1)
            env = dict(os.environ, GDK_BACKEND='broadway', BROADWAY_DISPLAY=display,
                       GTK_A11Y=os.environ.get('GTK_A11Y', 'none'), PARLA_RPC_SERVER=str(core),
                       PARLA_SCROLL_STYLE=style)
            for name in ('CONFIG', 'DATA', 'CACHE', 'STATE'):
                env[f'XDG_{name}_HOME'] = str(root / name.lower())
            app = subprocess.Popen([str(Path(sys.argv[1]).resolve()), '--conversation-scroll-ui'],
                                   env=env, stdout=subprocess.PIPE)
            deadline = time.monotonic() + 90
            pending = ''
            while app.poll() is None:
                assert time.monotonic() < deadline, 'Conversation scroll test timed out'
                if select.select([app.stdout], [], [], 0)[0]:
                    pending += os.read(app.stdout.fileno(), 65536).decode()
                    while '\n' in pending:
                        line, pending = pending.split('\n', 1)
                        if line.startswith('INPUT '):
                            _, kind, x, y = line.split()
                            client.input(kind, int(x), int(y))
                        else:
                            print(line, flush=True)
                try:
                    client.receive(connection.recv())
                except websocket.WebSocketTimeoutException:
                    pass
            print(pending + app.stdout.read().decode(), end='')
            assert app.returncode == 0, f'Fixture exited with {app.returncode}'
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
