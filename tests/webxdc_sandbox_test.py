#!/usr/bin/env python3
"""Live sandbox tests: BUILD_DIR [--macos-bundle PATH].

Needs a Wayland compositor on Linux, a signed bundle on macOS, or the
Evergreen WebView2 runtime on Windows. Never disables an OS/engine sandbox.
The native probe replaces the helper only in a disposable macOS test bundle.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('build', type=Path)
parser.add_argument('--macos-bundle', type=Path)
args = parser.parse_args()
build = args.build.resolve()
root = Path(__file__).resolve().parent.parent
suffix = '.exe' if sys.platform == 'win32' else ''


def run(*command):
    subprocess.run([str(p) for p in command], check=True, timeout=90, cwd=root)


def binary(name):
    return build / (name + suffix)


def exercise(smoke, helper, integration, boundary, probe):
    helpers = [helper]
    if sys.platform == 'win32':
        # Both spellings are accepted by Windows and used by our callers.
        helpers = [str(helper).replace('\\', '/'), str(helper).replace('/', '\\')]
    for executable in helpers:
        for policy in ((), ('--wasm',), ('--online',)):
            run(smoke, executable, *policy)
    run(sys.executable, root / 'tests/webxdc_realtime_test.py', integration, '--ui')
    run(boundary, probe)


if sys.platform != 'darwin':
    exercise(binary('webxdc-sandbox-test'), binary('parla-webxdc'),
             binary('core-compat-test'), binary('webxdc-sandbox-boundary-test'),
             binary('webxdc-sandbox-probe'))
else:
    if not args.macos_bundle:
        parser.error('macOS requires --macos-bundle pointing to a signed Parla.app')
    with tempfile.TemporaryDirectory(prefix='parla-webxdc-test-') as temporary:
        app = Path(temporary) / 'Parla.app'
        run('ditto', args.macos_bundle.resolve(), app)
        service = app / 'Contents/XPCServices/io.github.trufae.Parla.Webxdc.xpc'
        main = app / 'Contents/MacOS/parla'

        def replace(source, destination):
            shutil.copy2(source, destination)
            frameworks = destination.parent.parent / 'Frameworks'
            libraries = subprocess.check_output(['otool', '-L', str(destination)], text=True)
            for line in libraries.splitlines()[1:]:
                library = line.strip().split(' (')[0]
                if library.startswith(('/usr/lib/', '/System/')):
                    continue
                target = frameworks / Path(library).name
                if not target.is_file():
                    raise RuntimeError(f'Missing bundled test dependency: {target}')
                run('install_name_tool', '-change', library,
                    '@loader_path/../Frameworks/' + target.name, destination)

        def install_main(name):
            replace(binary(name), main)
            run('codesign', '--force', '--sign', '-', app)

        install_main('webxdc-sandbox-test')
        for policy in ((), ('--wasm',), ('--online',)):
            run(main, binary('parla-webxdc'), *policy)
        install_main('core-compat-test')
        run(sys.executable, root / 'tests/webxdc_realtime_test.py', main, '--ui')
        replace(binary('webxdc-sandbox-probe'), service / 'Contents/MacOS/parla-webxdc')
        run('bash', root / 'scripts/macos/webxdc-sign.sh', app)
        install_main('webxdc-sandbox-boundary-test')
        run(main, binary('webxdc-sandbox-probe'))
        # A valid signature without App Sandbox entitlements must fail closed.
        run('codesign', '--force', '--sign', '-', service)
        run('codesign', '--force', '--sign', '-', app)
        run(main, binary('webxdc-sandbox-probe'), '--expect-denied')
