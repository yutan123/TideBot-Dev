#!/usr/bin/env python3
"""Pack a plugin directory into a .tideplugin ZIP for sideloading.

Usage:
  python3 tool/pack_plugin.py assets/plugins/hello
  python3 tool/pack_plugin.py assets/plugins/hello --out /tmp/hello.tideplugin

The ZIP will contain files at the root level (no extra wrapper directory).
"""
import argparse
import sys
import zipfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description='Pack a TideBot plugin directory into a ZIP.')
    parser.add_argument('dir', help='Plugin source directory containing manifest.json')
    parser.add_argument('--out', help='Output path (default: <dir>.tideplugin)')
    args = parser.parse_args()

    src = Path(args.dir).resolve()
    if not (src / 'manifest.json').exists():
        sys.exit(f'Error: {src}/manifest.json not found')

    out = Path(args.out) if args.out else src.with_suffix('.tideplugin')
    out = out.resolve()
    if out == src or src in out.parents:
        sys.exit('Error: output must be outside the plugin source directory')
    paths = sorted(src.rglob('*'))
    if any(path.is_symlink() for path in paths):
        sys.exit('Error: symbolic links are not supported')
    out.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        for path in paths:
            if path.is_file():
                arcname = path.relative_to(src).as_posix()
                zf.write(path, arcname)
                print(f'  {arcname}')

    size_kb = out.stat().st_size / 1024
    print(f'\nPacked {out} ({size_kb:.1f} KB)')


if __name__ == '__main__':
    main()
