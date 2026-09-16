import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import check_spec_drift as checker


class SpecDriftTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / 'spec/upstream').mkdir(parents=True)
        self.snapshot = root / 'spec/upstream/eip-8141.md'
        self.snapshot.write_bytes(b'baseline\n')
        (root / 'spec/sources.json').write_text(json.dumps({
            'revision': 'a' * 40,
            'forkcast_revision': 'c' * 40,
            'eips': [{'eip': 8141, 'sha256': hashlib.sha256(b'baseline\n').hexdigest()}],
        }))
        self.root = root
        (root / 'spec/upstream/forkcast').mkdir()
        self.inclusion_data = {
            'id': 8141,
            'forkRelationships': [{'forkName': 'Hegota', 'statusHistory': [
                {'status': 'Scheduled', 'call': 'acde/244', 'date': '2026-08-27'},
            ]}],
        }
        raw = json.dumps(self.inclusion_data).encode()
        (root / 'spec/upstream/forkcast/eip-8141.json').write_bytes(raw)
        (root / 'spec/inclusion.json').write_text(json.dumps({
            'revision': 'c' * 40,
            'proposals': [{
                'eip': 8141, 'fork': 'Hegota', 'status': 'Scheduled',
                'call': 'acde/244', 'date': '2026-08-27',
                'sha256': hashlib.sha256(raw).hexdigest(),
            }],
        }))
        patcher = patch.object(checker, 'ROOT', root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_check(self, args, current=b'baseline\n', inclusion_data=None):
        calls = []

        def fetch(url):
            calls.append(url)
            if '/commits/master' in url:
                return json.dumps({'sha': 'b' * 40}).encode()
            if '/commits/main' in url:
                return json.dumps({'sha': 'd' * 40}).encode()
            if '/forkcast/' in url:
                return json.dumps(inclusion_data or self.inclusion_data).encode()
            return current

        with patch.object(checker, 'fetch', side_effect=fetch), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = checker.main(args)
        return status, calls

    def test_offline_checks_integrity_without_network(self):
        self.assertEqual(self.run_check(['--offline']), (0, []))
        self.snapshot.write_bytes(b'tampered')
        self.assertEqual(self.run_check(['--offline']), (2, []))

    def test_uses_one_resolved_revision_for_comparison(self):
        status, calls = self.run_check([])
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 4)
        self.assertIn('/' + 'b' * 40 + '/EIPS/eip-8141.md', calls[1])
        self.assertIn('/' + 'd' * 40 + '/src/data/eips/8141.json', calls[3])

    def test_drift_is_reported(self):
        self.assertEqual(self.run_check(['--diff', '8141'], b'changed\n')[0], 1)

    def test_untracked_proposal_fails_without_network(self):
        self.assertEqual(self.run_check(['7819']), (2, []))

    def test_missing_dependency_fails_without_network(self):
        data = b'---\neip: 8141\nrequires: 2929, 8037\n---\n'
        self.snapshot.write_bytes(data)
        manifest_path = self.root / 'spec/sources.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['eips'][0]['sha256'] = hashlib.sha256(data).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        self.assertEqual(self.run_check([]), (2, []))

    def test_requirements_ignore_prose(self):
        self.assertEqual(checker.requirements(b'---\neip: 1\nrequires: 2, 155\n---\nrequires: 999'), {2, 155})

    def test_inclusion_drift_is_reported(self):
        changed = json.loads(json.dumps(self.inclusion_data))
        changed['forkRelationships'][0]['statusHistory'].append({
            'status': 'Declined', 'call': 'acde/246', 'date': '2026-09-24',
        })
        self.assertEqual(self.run_check([], inclusion_data=changed)[0], 1)

    def test_inclusion_description_edits_are_not_status_drift(self):
        changed = dict(self.inclusion_data, description='Updated explanation')
        self.assertEqual(self.run_check([], inclusion_data=changed)[0], 0)

    def test_inclusion_snapshot_corruption_fails_offline(self):
        (self.root / 'spec/upstream/forkcast/eip-8141.json').write_bytes(b'{}')
        self.assertEqual(self.run_check(['--offline']), (2, []))

    def test_inclusion_record_must_match_evidence(self):
        path = self.root / 'spec/inclusion.json'
        document = json.loads(path.read_text())
        document['proposals'][0]['status'] = 'Declined'
        path.write_text(json.dumps(document))
        self.assertEqual(self.run_check(['--offline']), (2, []))

    def test_missing_upstream_fork_is_an_error(self):
        self.assertEqual(self.run_check([], inclusion_data={'id': 8141, 'forkRelationships': []})[0], 2)

    def test_canonical_copy_must_match_snapshot(self):
        (self.root / 'spec/EIP8141.md').write_bytes(b'stale')
        self.assertEqual(self.run_check(['--offline']), (2, []))


if __name__ == '__main__':
    unittest.main()
