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
if len(sys.argv) != 2:
    raise SystemExit('usage: python3 script/check_package.py path/to/installer.pkg')
package = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='waccom-package-check-') as temporary:
    temporary = Path(temporary)
    expanded = temporary / 'expanded'
    subprocess.run(['pkgutil', '--expand-full', str(package), str(expanded)], check=True, stdout=subprocess.DEVNULL)
    distribution = ET.parse(expanded / 'Distribution').getroot()
    assert distribution.find('volume-check/allowed-os-versions/os-version').get('min') == '27.0'
    assert distribution.find('options').get('hostArchitectures') == 'arm64'
    assert distribution.find('domains').get('enable_currentUserHome') == 'false'
    assert distribution.find('.//must-close/app').get('id') == 'local.waccomDrive'
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
    for name in ('usb', 'bluetooth-on', 'bluetooth-off'):
        location = Path('assets/connection') / (name + '.svg')
        assert (app / 'Contents/Resources' / location).read_bytes() == (root / location).read_bytes()
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
