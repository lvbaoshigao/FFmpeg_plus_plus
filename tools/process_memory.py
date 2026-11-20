#!/usr/bin/env python3
"""Read a Linux application's RSS, PSS, swap, and high-water mark without mutation."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid', type=int, help='PID of the visible release application')
args = parser.parse_args()
if args.pid <= 0:
    parser.error('PID must be positive')
process = Path('/proc') / str(args.pid)
try:
    status = {}
    for line in (process / 'status').read_text().splitlines():
        key, separator, value = line.partition(':')
        if separator and key in {'VmRSS', 'VmHWM', 'VmSwap', 'RssAnon', 'RssFile', 'RssShmem'}:
            status[key] = int(value.split()[0]) * 1024
    for line in (process / 'smaps_rollup').read_text().splitlines():
        key, separator, value = line.partition(':')
        if separator and key == 'Pss':
            status[key] = int(value.split()[0]) * 1024
    print(json.dumps({
        'pid': args.pid,
        'binary': str((process / 'exe').resolve()),
        'bytes': status,
        'MiB': {key: round(value / (1024 * 1024), 2) for key, value in status.items()},
        'rss_under_100_MB': status.get('VmRSS', 100_000_000) < 100_000_000,
        'no_swapped_pages': status.get('VmSwap', 0) == 0,
        'interpretation': 'Measure a visible, idle release home; swap or a stale build cannot prove the current source meets the target.',
    }, indent=2))
except (FileNotFoundError, PermissionError, ProcessLookupError) as error:
    parser.exit(1, f'Could not inspect PID {args.pid}: {error}\n')
