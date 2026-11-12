#!/usr/bin/env python3
"""Sidebar menu, focus and list-update regression with an offline account.

    python3 tests/sidebar_scroll_test.py builddir/core-compat-test [full|compact]

Requires gtk4-broadwayd and websocket-client; no real accounts are opened.
"""
import json
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
sys.dont_write_bytecode = True
from touch_scroll_test import Broadway


def fake_core():
    chats = list(range(10, 90))
    archived = set()
    pinned = set()
    revision = 0
    unread = set()
    for line in sys.stdin:
        request = json.loads(line)
        with open(os.environ['PARLA_TEST_RPC_LOG'], 'a') as log:
            log.write(line)
        method, params = request['method'], request['params']
        result = None
        if method == 'get_next_event':
            continue
        if method == 'get_system_info':
            result = {}
        elif method == 'get_all_accounts':
            result = [{'id': 1}]
        elif method == 'is_configured':
            result = True
        elif method == 'get_chatlist_entries':
            result = [i for i in chats if (i in archived) == (params[1] == 1)]
        elif method == 'get_chatlist_items_by_entries':
            result = {str(i): dict(id=i, name=f'Chat {i}', chatType='Single',
                      isPinned=i in pinned, isArchived=i in archived,
                      isMuted=True, summaryText2=f'A message {revision}',
                      freshMessageCounter=int(i in unread)) for i in params[1]}
        elif method == 'get_full_chat_by_id':
            result = dict(id=params[1], name=f'Chat {params[1]}', chatType='Single', contactIds=[])
        elif method == 'get_messages':
            result = {}
        elif method in ('get_fresh_msgs', 'list_transports', 'get_pinned_messages', 'get_message_ids'):
            result = []
        elif method == 'get_connectivity':
            result = 1000
        elif method == 'get_config':
            result = 'Sidebar profile' if params[1] == 'displayname' else None
        elif method == 'delete_chat':
            chats.remove(params[1])
        elif method == 'set_chat_visibility':
            cid, visibility = params[1:]
            if visibility == 'Pinned':
                pinned.add(cid)
                chats.remove(cid)
                chats.insert(0, cid)
            elif visibility == 'Archived':
                archived.add(cid)
            else:
                archived.discard(cid)
                pinned.discard(cid)
        elif method == 'test_prepend':
            chats.insert(0, 100)
        elif method == 'test_refresh':
            revision += 1
        elif method == 'test_move':
            chats.remove(params[0])
            chats.insert(0, params[0])
        elif method == 'markfresh_chat':
            unread.add(params[1])
        elif method not in ('get_blob_dir', 'select_account', 'start_io_for_all_accounts',
                            'batch_set_config', 'get_draft', 'misc_set_draft', 'marknoticed_chat',
                            'markseen_msgs', 'get_first_unread_message_of_chat'):
            raise AssertionError(f'Unexpected RPC: {method}')
        print(json.dumps(dict(jsonrpc='2.0', id=request['id'], result=result)), flush=True)


def sidebar_input(client, kind, x, y):
    if kind != 'right-click':
        client.input(kind, x, y)
        return
    sid = max(client.surfaces, key=lambda s: client.surfaces[s][2] * client.surfaces[s][3])
    client.send(0, sid, sid, x, y, x, y, 0, 0)
    client.send(3, sid, sid, x, y, x, y, 0, 3)
    client.send(4, sid, sid, x, y, x, y, 1024, 3)


def main():
    mode = sys.argv[2] if len(sys.argv) > 2 else 'full'
    assert mode in ('full', 'compact')
    with tempfile.TemporaryDirectory(prefix='parla-sidebar-scroll-') as folder:
        root = Path(folder)
        core = root / 'core'
        core.write_text('#!/bin/sh\nexec ' + shlex.join([
            sys.executable, str(Path(__file__).resolve()),
            '--fake-core']) + '\n')
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
                       PARLA_TEST_SIDEBAR_MODE=mode,
                       PARLA_TEST_RPC_LOG=str(root / 'rpc.log'))
            for name in ('CONFIG', 'DATA', 'CACHE', 'STATE'):
                env[f'XDG_{name}_HOME'] = str(root / name.lower())
            app = subprocess.Popen([str(Path(sys.argv[1]).resolve()), '--sidebar-scroll-ui'],
                                   env=env, stdout=subprocess.PIPE)
            deadline = time.monotonic() + 90
            pending = ''
            while app.poll() is None:
                assert time.monotonic() < deadline, 'Sidebar scroll test timed out'
                if select.select([app.stdout], [], [], 0)[0]:
                    pending += os.read(app.stdout.fileno(), 65536).decode()
                    while '\n' in pending:
                        line, pending = pending.split('\n', 1)
                        if line.startswith('INPUT '):
                            _, kind, x, y = line.split()
                            sidebar_input(client, kind, int(x), int(y))
                        elif line.startswith('KEY '):
                            _, key, modifiers = line.split()
                            client.send(7, int(key), int(modifiers))
                            client.send(8, int(key), int(modifiers))
                        else:
                            print(line, flush=True)
                try:
                    client.receive(connection.recv())
                except websocket.WebSocketTimeoutException:
                    pass
            print(pending + app.stdout.read().decode(), end='')
            if app.returncode != 0:
                print('Last RPC requests:\n' + '\n'.join((root / 'rpc.log').read_text().splitlines()[-15:]))
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
    if sys.argv[1:] == ['--fake-core']:
        fake_core()
    else:
        main()
