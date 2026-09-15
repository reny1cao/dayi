#!/usr/bin/env python3
"""Prepare a preview release bundle; never publish or claim notarization automatically."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, capture_output=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', default='v0.2.4-preview.1')
    args = parser.parse_args()
    match = re.fullmatch(r'v(\d+\.\d+\.\d+)-preview\.(\d+)', args.tag)
    if not match:
        parser.error('This preparation script accepts preview tags only, e.g. v0.2.4-preview.1')
    run('git', 'diff', '--quiet')
    run('git', 'diff', '--cached', '--quiet')
    app = ROOT / 'outputs/Dayi.app'
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info['CFBundleShortVersionString'] != match[1]:
        raise SystemExit('Tag version does not match the packaged app')
    run('codesign', '--verify', '--strict', str(app))
    signing = run('codesign', '-dv', '--verbose=4', str(app)).stderr
    if 'Authority=Developer ID Application:' not in signing or 'runtime' not in signing:
        raise SystemExit('Release preview requires Developer ID and hardened runtime; ad-hoc CI bundles are not release assets')
    if not (app / 'Contents/Resources/Dayi.icns').is_file():
        raise SystemExit('Packaged app icon is missing')
    arch = run('lipo', '-archs', str(app / 'Contents/MacOS/TextPolishApp')).stdout.strip()
    if arch != 'arm64':
        raise SystemExit('This preview is currently validated for arm64 only')
    # The packaging receipt binds this signed bundle to its source commit.
    receipt = json.loads((app / 'Contents/Resources/build-receipt.json').read_text())
    commit = run('git', 'rev-parse', 'HEAD').stdout.strip()
    if receipt['commit'] != commit or receipt['tracked_changes']:
        raise SystemExit('Bundle was not built from the current clean commit; package it again')
    out = ROOT / 'outputs/releases' / args.tag
    out.mkdir(parents=True, exist_ok=True)
    archive = out / f'Dayi-{args.tag[1:]}-macos-arm64.zip'
    if archive.exists():
        raise SystemExit(f'Release archive already exists: {archive}. Use a new preview number.')
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
    ticket = subprocess.run(['xcrun', 'stapler', 'validate', str(app)], capture_output=True).returncode == 0
    manifest = {
        'tag': args.tag, 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
        'commit': commit, 'architecture': arch, 'minimum_macos_declared': info['LSMinimumSystemVersion'],
        'developer_id_signed': True, 'stapled_notarization_ticket': ticket,
        # License adopted and brand assets cleared by the owner on 2026-09-15; notarization is the remaining gate.
        'public_release_ready': ticket,
        'blockers': [] if ticket else ['Apple notarization and stapling incomplete'],
        'swift': run('swift', '--version').stdout.strip(),
        'artifact': archive.name,
    }
    manifest_path = out / 'release.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    checksums = out / 'SHA256SUMS.txt'
    checksums.write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
                                for p in (archive, manifest_path)))
    print(out)


if __name__ == '__main__':
    main()
