#!/usr/bin/env python3
"""Fail closed on unexpected publish files and common private material."""
import argparse
from pathlib import Path
import re
import stat
import subprocess
import sys

ALLOWED = frozenset({
    '.gitignore', 'README.md', 'PUBLISH_CHECKLIST.txt', 'SECURITY.md',
    'scripts/check_environment.sh', 'scripts/audit_public_files.py',
    'tests/test_check_environment.sh', 'tests/test_audit_public_files.py',
    'docs/READ_ONLY_REVIEW.md', 'docs/VALIDATION_REPORT.zh-CN.md',
})
DIRECTORIES = frozenset({'scripts', 'tests', 'docs'})
MAX_SIZE = 256 * 1024
PATTERNS = (
    ('私人主目录', re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+|[A-Za-z]:\\Users\\[^\s\\]+')),
    ('访问令牌', re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})\b')),
    ('云访问密钥', re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('私钥', re.compile(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----')),
    ('认证头', re.compile(r'(?i)\b(?:authorization\s*:\s*(?:bearer|basic)\s+)[A-Za-z0-9+/_.=-]{8,}')),
    ('凭据赋值', re.compile(r'''(?i)\b(?:password|passwd|api_key|access_token|refresh_token|client_secret)\s*[:=]\s*["']?[A-Za-z0-9_+/=-]{8,}''')),
    ('设备或账号标识', re.compile(r'\b(?:wxid_[a-zA-Z0-9]{6,}|[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\b')),
    ('邮箱地址', re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b')),
)


def inspect_content(name, data):
    if len(data) > MAX_SIZE:
        return [f'{name}：超过文本大小限制']
    try:
        content = data.decode('utf-8')
    except UnicodeDecodeError:
        return [f'{name}：不是 UTF-8 文本']
    if any(ord(char) < 32 and char not in '\n\r\t' for char in content):
        return [f'{name}：含二进制或控制字符']
    issues = []
    for label, pattern in PATTERNS:
        for match in pattern.finditer(content):
            # The repository owner is an explicitly public identity.
            if label == '邮箱地址' and match.group() == 'Supershanyi@users.noreply.github.com':
                continue
            issues.append(f'{name}：疑似{label}（内容不回显）')
            break
    return issues


def audit_tree(root):
    issues, found = [], set()

    def walk(directory, prefix=''):
        for path in sorted(directory.iterdir()):
            relative = prefix + path.name
            mode = path.lstat().st_mode
            if relative == '.git':
                if not stat.S_ISDIR(mode):
                    issues.append('Git 元数据位置不是普通目录')
                continue
            if stat.S_ISDIR(mode):
                if relative not in DIRECTORIES:
                    issues.append('发现未批准目录（名称不回显）')
                else:
                    walk(path, relative + '/')
            elif relative not in ALLOWED:
                issues.append('发现未批准文件（名称不回显）')
            elif not stat.S_ISREG(mode):
                issues.append(f'{relative}：不是普通文件，拒绝链接或特殊文件')
            else:
                found.add(relative)
                if path.stat().st_size > MAX_SIZE:
                    issues.append(f'{relative}：超过文本大小限制')
                else:
                    issues.extend(inspect_content(relative, path.read_bytes()))

    walk(root)
    for missing in sorted(ALLOWED - found):
        issues.append(f'{missing}：缺少批准文件')
    return issues


def audit_index(root):
    """Scan actual staged blobs, including staged content unlike the worktree."""
    def git(*args):
        return subprocess.run(['git', '-C', str(root), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

    issues, found = [], set()
    for entry in git('ls-files', '--stage', '-z').split(b'\0'):
        if not entry:
            continue
        metadata, raw_name = entry.split(b'\t', 1)
        mode, _object_id, stage = metadata.split()
        name = raw_name.decode('utf-8')
        if name not in ALLOWED:
            issues.append('暂存区含未批准文件（名称不回显）')
            continue
        found.add(name)
        if mode not in (b'100644', b'100755') or stage != b'0':
            issues.append(f'{name}：暂存对象不是普通文件或有冲突')
            continue
        data = git('show', ':' + name)
        issues.extend(inspect_content(name, data))
        path = root / name
        if not path.is_file() or path.is_symlink() or path.read_bytes() != data:
            issues.append(f'{name}：暂存内容与已审查工作区不一致')
    for missing in sorted(ALLOWED - found):
        issues.append(f'{missing}：未暂存')
    return issues


def main():
    parser = argparse.ArgumentParser(description='公开文件与暂存区隐私扫描（仅报告，不上传）。')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--staged', action='store_true')
    args = parser.parse_args()
    try:
        issues = audit_tree(args.root)
        if args.staged:
            issues.extend(audit_index(args.root))
    except (OSError, ValueError, subprocess.CalledProcessError):
        print('FAIL 无法完成扫描；不回显可能含私人路径的错误。', file=sys.stderr)
        return 2
    for issue in issues:
        print('FAIL ' + issue)
    if issues:
        print(f'脱敏检查未通过：{len(issues)} 项；禁止发布。')
        return 1
    scope = '工作区和 Git 暂存区' if args.staged else '工作区'
    print(f'脱敏检查通过：{scope}的 {len(ALLOWED)} 个白名单文本文件；仍需人工审阅。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
