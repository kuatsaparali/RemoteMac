#!/usr/bin/env python3
"""Build standalone, architecture-specific MacRemote release archives on macOS."""

import concurrent.futures
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parent
CACHE = ROOT / '.release-cache'
RELEASE = ROOT / 'release'
NODE_VERSION = 'v22.23.5'
TUNNEL_VERSION = '2026.11.0'
DOWNLOADS = {
    'node-arm64': (
        f'https://nodejs.org/dist/{NODE_VERSION}/node-{NODE_VERSION}-darwin-arm64.tar.gz',
        'e7131995759b61a0170b646010d2ad35a5d37b4cb0d471f3e8317eac6f742f3d',
    ),
    'node-x86_64': (
        f'https://nodejs.org/dist/{NODE_VERSION}/node-{NODE_VERSION}-darwin-x64.tar.gz',
        'c53383238206b9ae4db23c5d8a63645e2e753bec8ab51a49cc81939aa64e9422',
    ),
    'cloudflared-arm64': (
        f'https://github.com/cloudflare/cloudflared/releases/download/{TUNNEL_VERSION}/cloudflared-darwin-arm64.tgz',
        '8c2f90277ef06a6080bb40b964d33f09f1188102f8798f2e344174b6cf41accf',
    ),
    'cloudflared-x86_64': (
        f'https://github.com/cloudflare/cloudflared/releases/download/{TUNNEL_VERSION}/cloudflared-darwin-amd64.tgz',
        '8a59d51120cebbe902f0a8d6e1b7a7fd4f9a5bb4dcb3e0f05872483e75e7db6b',
    ),
}


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def download(item):
    name, (url, expected) = item
    destination = CACHE / (name + '.tar.gz')
    if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest() != expected:
        temporary = destination.with_suffix('.download')
        run('curl', '-fLSs', '--retry', '3', '--max-time', '180', url, '-o', str(temporary))
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Checksum mismatch for {name}')
        temporary.replace(destination)
    return destination


def extract(archive, member, destination):
    with tarfile.open(archive) as source:
        with source.extractfile(member) as stream:
            destination.write_bytes(stream.read())


def main():
    CACHE.mkdir(exist_ok=True)
    RELEASE.mkdir(exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        archives = dict(zip(DOWNLOADS, pool.map(download, DOWNLOADS.items())))

    tunnel_license = CACHE / 'cloudflared-LICENSE'
    run('curl', '-fLSs', '--retry', '3', '--max-time', '30',
        f'https://raw.githubusercontent.com/cloudflare/cloudflared/{TUNNEL_VERSION}/LICENSE',
        '-o', str(tunnel_license))
    run('npm', 'ci', '--omit=dev', '--no-audit', '--no-fund', cwd=ROOT.parent / 'relay')
    run(str(ROOT / 'build.sh'), '--universal')
    base_app = ROOT / 'dist/MacRemote.app'
    version = plistlib.loads((base_app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    checksums = []

    for architecture, node_arch in [('arm64', 'arm64'), ('x86_64', 'x64')]:
        staging = RELEASE / architecture
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir()
        app = staging / 'MacRemote.app'
        shutil.copytree(base_app, app, symlinks=True)
        info_path = app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        # The pinned upstream cloudflared binaries have a macOS 15 deployment target.
        info['LSMinimumSystemVersion'] = '15.0'
        info_path.write_bytes(plistlib.dumps(info))
        resources = app / 'Contents/Resources'
        helpers = app / 'Contents/Helpers'
        licenses = resources / 'Licenses'
        resources.mkdir(exist_ok=True)
        helpers.mkdir(exist_ok=True)
        licenses.mkdir(exist_ok=True)
        shutil.copytree(ROOT.parent / 'relay', resources / 'relay',
                        ignore=shutil.ignore_patterns('.DS_Store'))
        node_prefix = f'node-{NODE_VERSION}-darwin-{node_arch}'
        extract(archives['node-' + architecture], node_prefix + '/bin/node', helpers / 'node')
        extract(archives['node-' + architecture], node_prefix + '/LICENSE', licenses / 'Node.js.txt')
        extract(archives['cloudflared-' + architecture], 'cloudflared', helpers / 'cloudflared')
        shutil.copyfile(tunnel_license, licenses / 'cloudflared.txt')
        shutil.copyfile(ROOT.parent / 'relay/node_modules/ws/LICENSE', licenses / 'ws.txt')
        (resources / 'BUNDLED-VERSIONS.txt').write_text(
            f'Node.js {NODE_VERSION}\ncloudflared {TUNNEL_VERSION}\nws 8.23.0\n')

        identity = os.environ.get('MACREMOTE_SIGN_IDENTITY', '-')
        for executable in [helpers / 'node', helpers / 'cloudflared']:
            executable.chmod(0o755)
            run('codesign', '--force', '--sign', identity, str(executable))
        run('codesign', '--force', '--sign', identity, str(app))
        run('codesign', '--verify', '--deep', '--strict', str(app))
        archive = RELEASE / f'MacRemote-{version}-macOS-{architecture}.zip'
        if archive.exists():
            archive.unlink()
        run('ditto', '-c', '-k', '--keepParent', str(app), str(archive))
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        checksums.append(f'{checksum}  {archive.name}')
        print(archive, flush=True)

    (RELEASE / 'SHA256SUMS.txt').write_text('\n'.join(checksums) + '\n')


if __name__ == '__main__':
    main()
