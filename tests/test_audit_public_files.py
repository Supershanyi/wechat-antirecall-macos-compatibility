#!/usr/bin/env python3
"""Regression tests for publication gates; no credentials or real user data."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'scripts/audit_public_files.py'
SPEC = importlib.util.spec_from_file_location('audit_public', SOURCE)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class PublicAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='public-audit-tests-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in AUDIT.ALLOWED:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('公开测试内容\n', encoding='utf-8')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], check=True,
                              capture_output=True)

    def prepare_index(self):
        self.git('init', '--quiet')
        self.git('add', '--', *sorted(AUDIT.ALLOWED))

    def test_clean_tree(self):
        self.assertEqual(AUDIT.audit_tree(self.root), [])

    def test_unapproved_files_including_ignored(self):
        for filename in ('private.log', '.env', 'chat.db', 'installer.dmg', 'patch.dylib'):
            with self.subTest(filename=filename):
                path = self.root / filename
                path.write_text('private')
                self.assertTrue(AUDIT.audit_tree(self.root))
                path.unlink()

    def test_missing_file(self):
        (self.root / 'SECURITY.md').unlink()
        self.assertTrue(AUDIT.audit_tree(self.root))

    def test_unapproved_directory(self):
        (self.root / 'backup.app').mkdir()
        self.assertTrue(AUDIT.audit_tree(self.root))

    def test_symlink_file(self):
        path = self.root / 'README.md'
        path.unlink()
        path.symlink_to('SECURITY.md')
        self.assertTrue(AUDIT.audit_tree(self.root))

    def test_symlink_directory(self):
        shutil.rmtree(self.root / 'docs')
        (self.root / 'docs').symlink_to(self.root / 'tests', target_is_directory=True)
        self.assertTrue(AUDIT.audit_tree(self.root))

    def test_binary_and_control_bytes(self):
        for payload in (b'\xff\xfe', b'hello\x00world', b'\x1b[31mhidden'):
            with self.subTest(payload=payload):
                self.assertTrue(AUDIT.inspect_content('README.md', payload))

    def test_oversized_file(self):
        self.assertTrue(AUDIT.inspect_content('README.md', b'a' * (AUDIT.MAX_SIZE + 1)))

    def test_sensitive_patterns_without_echo(self):
        values = [
            '/' + 'Users' + '/private_fixture',
            '/' + 'home' + '/private_fixture',
            'C:' + '\\Users' + '\\private_fixture',
            'gh' + 'p_' + 'a' * 36,
            'github_' + 'pat_' + 'a' * 40,
            's' + 'k-proj-' + 'a' * 40,
            'AK' + 'IA' + 'A' * 16,
            '-----BEGIN ' + 'PRIVATE KEY-----',
            'Authorization' + ': Bearer ' + 'a' * 32,
            'password' + '=' + 'a' * 12,
            'wx' + 'id_' + 'a' * 12,
            '-'.join(['a' * 8, 'b' * 4, 'c' * 4, 'd' * 4, 'e' * 12]),
            'private.person' + '@' + 'example.invalid',
        ]
        for value in values:
            with self.subTest(category=values.index(value)):
                issues = AUDIT.inspect_content('README.md', value.encode())
                self.assertTrue(issues)
                self.assertNotIn(value, '\n'.join(issues))

    def test_public_identity_and_generic_paths(self):
        data = ('Supershanyi@users.noreply.github.com '
                '~/Library/Containers/ /Applications/WeChat.app').encode()
        self.assertEqual(AUDIT.inspect_content('README.md', data), [])

    def test_clean_staged(self):
        self.prepare_index()
        self.assertEqual(AUDIT.audit_index(self.root), [])

    def test_staged_secret_not_hidden_by_clean_worktree(self):
        self.prepare_index()
        path = self.root / 'README.md'
        path.write_text('gh' + 'p_' + 'a' * 36)
        self.git('add', 'README.md')
        path.write_text('公开测试内容\n', encoding='utf-8')
        self.assertEqual(AUDIT.audit_tree(self.root), [])
        self.assertTrue(AUDIT.audit_index(self.root))

    def test_staged_unapproved_file(self):
        self.prepare_index()
        (self.root / 'private.log').write_text('private')
        self.git('add', 'private.log')
        self.assertTrue(AUDIT.audit_index(self.root))

    def test_staged_missing_file(self):
        self.prepare_index()
        self.git('rm', '--cached', 'SECURITY.md')
        self.assertTrue(AUDIT.audit_index(self.root))

    def test_staged_symlink(self):
        self.prepare_index()
        path = self.root / 'README.md'
        path.unlink()
        path.symlink_to('SECURITY.md')
        self.git('add', 'README.md')
        self.assertTrue(AUDIT.audit_index(self.root))

    def test_worktree_staged_mismatch(self):
        self.prepare_index()
        (self.root / 'README.md').write_text('changed')
        self.assertTrue(AUDIT.audit_index(self.root))


if __name__ == '__main__':
    unittest.main(verbosity=2)
