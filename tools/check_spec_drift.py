#!/usr/bin/env python3
"""Verify snapshots and compare with one immutable upstream revision.

Exit 0: clean; 1: upstream drift; 2: invalid local data or fetch failure.
This command never changes pins or snapshots.
"""
import argparse
import concurrent.futures
import difflib
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'FrameTx-toolkit-spec-check'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def requirements(data):
    """Read only the front-matter dependency list, not incidental prose references."""
    parts = data.decode().split('---', 2)
    match = re.search(r'^requires:\s*([^\n]+)', parts[1], re.MULTILINE) if len(parts) == 3 else None
    return set(map(int, re.findall(r'\d+', match.group(1)))) if match else set()


def inclusion_record(data, fork):
    relationship = next((item for item in data['forkRelationships'] if item['forkName'] == fork), None)
    if not relationship or not relationship['statusHistory']:
        raise ValueError(f'Forkcast: missing history for {fork}')
    latest = relationship['statusHistory'][-1]
    return {key: latest.get(key) for key in ('status', 'call', 'date')}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('eips', nargs='*', type=int, help='EIP numbers (default: all tracked sources)')
    parser.add_argument('--offline', action='store_true', help='only verify snapshot integrity')
    parser.add_argument('--diff', action='store_true', help='print upstream text differences')
    args = parser.parse_args(argv)
    try:
        manifest = json.loads((ROOT / 'spec/sources.json').read_text())
        entries = {entry['eip']: entry for entry in manifest['eips']}
        if len(entries) != len(manifest['eips']):
            raise ValueError('duplicate EIP entries')
        unknown = set(args.eips) - entries.keys()
        if unknown:
            raise ValueError(f'untracked EIPs: {sorted(unknown)}')
        selected = sorted(set(args.eips) or entries)
        snapshots = {}
        for number in sorted(entries):
            data = (ROOT / f'spec/upstream/eip-{number}.md').read_bytes()
            if hashlib.sha256(data).hexdigest() != entries[number]['sha256']:
                raise ValueError(f'EIP-{number}: local snapshot does not match its checksum')
            snapshots[number] = data
            missing = requirements(data) - entries.keys()
            if missing:
                raise ValueError(f'EIP-{number}: untracked required EIPs: {sorted(missing)}')
        canonical = ROOT / 'spec/EIP8141.md'
        if canonical.exists() and canonical.read_bytes() != snapshots.get(8141):
            raise ValueError('spec/EIP8141.md differs from its upstream snapshot')

        inclusion = json.loads((ROOT / 'spec/inclusion.json').read_text())
        if inclusion['revision'] != manifest['forkcast_revision']:
            raise ValueError('Forkcast revisions in sources.json and inclusion.json differ')
        records = inclusion['proposals']
        if len({(item['eip'], item['fork']) for item in records}) != len(records):
            raise ValueError('duplicate fork inclusion records')
        for record in records:
            number = record['eip']
            raw = (ROOT / f'spec/upstream/forkcast/eip-{number}.json').read_bytes()
            if hashlib.sha256(raw).hexdigest() != record['sha256']:
                raise ValueError(f'Forkcast EIP-{number}: snapshot does not match its checksum')
            data = json.loads(raw)
            if data['id'] != number or inclusion_record(data, record['fork']) != {
                key: record[key] for key in ('status', 'call', 'date')
            }:
                raise ValueError(f'Forkcast EIP-{number}: inclusion record differs from its snapshot')
        print(f"Verified {len(snapshots)} local snapshots and their required dependencies at {manifest['revision']}.")
        print(f"Verified {len(records)} fork inclusion records at {inclusion['revision']}.")
        if args.offline:
            return 0
        revision = json.loads(fetch('https://api.github.com/repos/ethereum/EIPs/commits/master'))['sha']
        print(f'Comparing with ethereum/EIPs@{revision}.')

        def compare(number):
            url = f'https://raw.githubusercontent.com/ethereum/EIPs/{revision}/EIPS/eip-{number}.md'
            return number, fetch(url)

        drift = False
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            for number, current in pool.map(compare, selected):
                old = snapshots[number]
                if old == current:
                    print(f'EIP-{number}: unchanged')
                    continue
                drift = True
                print(f'EIP-{number}: CHANGED')
                if args.diff:
                    sys.stdout.writelines(difflib.unified_diff(
                        old.decode().splitlines(keepends=True),
                        current.decode().splitlines(keepends=True),
                        fromfile=f'pinned/eip-{number}.md', tofile=f'current/eip-{number}.md',
                    ))
        selected_records = [item for item in records if not args.eips or item['eip'] in selected]
        if selected_records:
            forkcast_revision = json.loads(fetch('https://api.github.com/repos/ethereum/forkcast/commits/main'))['sha']
            print(f'Comparing inclusion with ethereum/forkcast@{forkcast_revision}.')

            def compare_inclusion(record):
                number = record['eip']
                url = f'https://raw.githubusercontent.com/ethereum/forkcast/{forkcast_revision}/src/data/eips/{number}.json'
                current = json.loads(fetch(url))
                if current['id'] != number:
                    raise ValueError(f'Forkcast EIP-{number}: unexpected EIP id')
                return record, inclusion_record(current, record['fork'])

            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                for record, current in pool.map(compare_inclusion, selected_records):
                    old = {key: record[key] for key in ('status', 'call', 'date')}
                    if old == current:
                        print(f"EIP-{record['eip']} inclusion ({record['fork']}): unchanged ({current['status']})")
                    else:
                        drift = True
                        print(f"EIP-{record['eip']} inclusion ({record['fork']}): CHANGED {old} -> {current}")
        if drift:
            print('Review spec/README.md and VERSIONS.md before updating the pins.')
        return int(drift)
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError) as error:
        print(f'Spec check failed: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
