#!/usr/bin/env python3
"""Read-only installer verification; never installs or removes the real app."""
from pathlib import Path
import os
import json
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
if len(sys.argv) not in (2, 3):
    raise SystemExit('usage: python3 script/check_package.py path/to/installer.pkg [--local|--signed-app|--release]')
package = Path(sys.argv[1]).resolve()
mode = sys.argv[2] if len(sys.argv) == 3 else None
assert mode in (None, '--local', '--signed-app', '--release'), 'Unknown build type'
with tempfile.TemporaryDirectory(prefix='waccom-package-check-') as temporary:
    temporary = Path(temporary)
    expanded = temporary / 'expanded'
    subprocess.run(['pkgutil', '--expand-full', str(package), str(expanded)], check=True, stdout=subprocess.DEVNULL)
    distribution = ET.parse(expanded / 'Distribution').getroot()
    assert distribution.find('volume-check/allowed-os-versions/os-version').get('min') == '27.0'
    assert distribution.find('options').get('hostArchitectures') == 'arm64'
    assert distribution.find('domains').get('enable_currentUserHome') == 'false'
    assert distribution.find('.//must-close/app').get('id') == 'local.waccomDrive'
    welcome = distribution.find('welcome')
    assert welcome.get('file') == 'Welcome.rtfd' and welcome.get('mime-type') == 'text/rtfd'
    resources = expanded / 'Resources'
    document = resources / 'Welcome.rtfd'
    assert document.is_file(), 'Welcome must be a self-contained RTFD file'
    assert (resources / distribution.find('readme').get('file')).is_file()
    sources = ['cover-dev.png' if mode == '--local' else 'cover.png'] if mode else ['cover-dev.png', 'cover.png']
    matches = False
    for source in sources:
        check = subprocess.run(['swift', '-module-cache-path', str(root / 'build/module-cache'),
                                str(root / 'script/installer_welcome.swift'), str(root / 'previews' / source),
                                str(document), '--check'], capture_output=True, text=True)
        matches |= check.returncode == 0
    assert matches, 'Welcome artwork failed native decoding, crop, size, or build-type validation'

    apps = list(expanded.glob('*/Payload/Applications/WaccomDrive.app'))
    assert len(apps) == 1, 'Installer must contain exactly the expected Applications bundle'
    app = apps[0]
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'local.waccomDrive'
    assert info.get('LSUIElement') is True, 'The app must remain a status-bar utility without a Dock icon'
    embedded = app / 'Contents/Resources/Uninstall WaccomDrive.command'
    assert embedded.read_bytes() == (root / 'packaging/Uninstall WaccomDrive.command').read_bytes()
    assert os.access(embedded, os.X_OK)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    package_info = ET.parse(app.parents[2] / 'PackageInfo').getroot()
    assert package_info.get('version') == info['CFBundleShortVersionString'] == info['CFBundleVersion']
    asset_root = app / 'Contents/Resources/assets'
    catalog = json.loads((asset_root / 'tablet/models.json').read_text())
    for model in catalog['models']:
        for image in model['images'].values():
            if image is not None:
                bundled = asset_root / 'tablet' / image
                assert bundled.read_bytes() == (root / 'assets/tablet' / image).read_bytes(), image
    for directory in ('connection', 'battery'):
        for image in (root / 'assets' / directory).glob('*.svg'):
            location = image.relative_to(root)
            assert (app / 'Contents/Resources' / location).read_bytes() == image.read_bytes()
    assert package_info.get('identifier') == 'local.waccomDrive.pkg'
    assert package_info.get('relocatable') == 'false', 'Updates must not relocate into a development checkout'
    assert len(package_info.find('relocate')) == 0
    assert package_info.get('install-location') == '/'
    preinstall = root / 'packaging/scripts/preinstall'
    mock_bin = temporary / 'bin'
    mock_bin.mkdir()
    pgrep = mock_bin / 'pgrep'
    pgrep.write_text('#!/bin/sh\nexit 1\n')
    pgrep.chmod(0o755)
    env = dict(os.environ, PATH=f'{mock_bin}:/usr/bin:/bin:/usr/sbin:/sbin')
    volume = temporary / 'volume'
    target = volume / 'Applications/WaccomDrive.app'
    target.mkdir(parents=True)
    def check_guard():
        return subprocess.run(['bash', str(preinstall), 'package', '/', str(volume)], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode
    (target / 'Contents').mkdir()
    with (target / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'other.application'}, stream)
    assert check_guard() != 0, 'Must refuse to overwrite another app'
    with (target / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'local.waccomDrive'}, stream)
    assert check_guard() == 0
    target.rename(target.with_suffix('.previous'))
    target.symlink_to(target.with_suffix('.previous'))
    assert check_guard() != 0, 'Must refuse a symbolic-link destination'
    # Only the dry-run path is invoked. No sudo, login changes, or production removal.
    dry = subprocess.run(['bash', str(embedded), '--dry-run'], capture_output=True, text=True)
    assert dry.returncode == 0, dry.stderr
    assert 'preserve' in dry.stdout.lower()
    assert embedded.exists()
print('Package payload, signature, requirements, uninstall embedding, destination guards, and uninstall dry-run checks passed. No installation performed.')
