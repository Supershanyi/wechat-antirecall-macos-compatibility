#!/bin/bash
# All writable fixtures live in a freshly created temporary directory.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PYTHON=$(command -v python3) || { printf '%s\n' '需要 Python 3。' >&2; exit 1; }
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wechat-readonly-tests.XXXXXXXX")
TEMP_ROOT=$(cd "$TEMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TEMP_ROOT"' EXIT
export PYTHONDONTWRITEBYTECODE=1
source "$ROOT/scripts/check_environment.sh"
APP="$TEMP_ROOT/fixture with spaces.app"
mkdir -p "$APP/Contents/MacOS/XPlayer.app" "$APP/Contents/MacOS/WeChatAppEx.app"
"$PYTHON" - "$APP/Contents/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier': 'com.tencent.xinWeChat',
                  'CFBundleShortVersionString': '4.1.15',
                  'CFBundleVersion': '270102'}, stream)
PY

run_uname() {
    case "$*" in
        -s) printf '%s\n' "${MOCK_PLATFORM:-Darwin}" ;;
        -m) printf '%s\n' "${MOCK_ARCH:-arm64}" ;;
        *) return 90 ;;
    esac
}
run_sw_vers() { [ "$*" = '-productVersion' ] || return 90; printf '%s\n' "${MOCK_OS:-15.0}"; }
tool_available() { [ "${MOCK_MISSING_TOOL:-0}" = 0 ]; }
run_plistbuddy() {
    [ "$#" -eq 3 ] && [ "$1" = '-c' ] && [ "$3" = "$APP/Contents/Info.plist" ] || return 90
    printf 'plist:%s\n' "$2" >> "$TEMP_ROOT/calls"
    case "$2" in
        'Print :CFBundleIdentifier') printf '%s\n' "${MOCK_ID:-com.tencent.xinWeChat}" ;;
        'Print :CFBundleShortVersionString') printf '%s\n' "${MOCK_VERSION:-4.1.15}" ;;
        'Print :CFBundleVersion')
            [ "${MOCK_BUILD_FAIL:-0}" = 0 ] || return 1
            printf '%s\n' '270102'
            ;;
        *) return 90 ;;
    esac
}
run_codesign() {
    local target
    for target in "$@"; do :; done
    case "$target" in
        "$APP"|"$APP/Contents/MacOS/XPlayer.app"|"$APP/Contents/MacOS/WeChatAppEx.app") ;;
        *) return 90 ;;
    esac
    printf 'codesign:%s\n' "$*" >> "$TEMP_ROOT/calls"
    if [ "$#" -eq 3 ] && [ "$1" = '--display' ] && [ "$2" = '--verbose=4' ]; then
        printf '%s\n' "${MOCK_DETAILS:-TeamIdentifier=AAAAAAAAAA}" >&2
        printf '%s\n' 'PRIVATE_DIAGNOSTIC_SENTINEL' >&2
        return "${MOCK_DISPLAY_EXIT:-0}"
    fi
    if [ "$#" -eq 5 ] && [ "$1" = '--verify' ] && [ "$2" = '--deep' ] && [ "$3" = '--strict' ] && [ "$4" = '--all-architectures' ]; then
        printf '%s\n' 'PRIVATE_DIAGNOSTIC_SENTINEL' >&2
        if [ "${MOCK_NESTED_FAIL:-0}" = 1 ] && [ "$target" != "$APP" ]; then return 1; fi
        return "${MOCK_VERIFY_EXIT:-0}"
    fi
    return 90
}

invoke() {
    local expected="$1"
    shift
    : > "$TEMP_ROOT/calls"
    RESULT=0
    main "$@" > "$TEMP_ROOT/output" 2>&1 || RESULT=$?
    [ "$RESULT" -eq "$expected" ] || { printf '错误：期望退出码 %s，实际 %s\n' "$expected" "$RESULT"; return 1; }
    if /usr/bin/grep -Fq "$TEMP_ROOT" "$TEMP_ROOT/output" || /usr/bin/grep -q 'PRIVATE_.*SENTINEL' "$TEMP_ROOT/output"; then
        printf '%s\n' '错误：输出包含私密哨兵或临时路径。'; return 1
    fi
}
contains() { /usr/bin/grep -Fq "$1" "$TEMP_ROOT/output"; }
no_calls() { [ ! -s "$TEMP_ROOT/calls" ]; }
case_help() { invoke 0 --help; no_calls; }
case_help_extra() { invoke 2 --help extra; no_calls; }
case_unknown() { invoke 2 --private=PRIVATE_ARGUMENT_SENTINEL; no_calls; }
case_missing_arg() { invoke 2 --app; no_calls; }
case_empty_arg() { invoke 2 --app ''; no_calls; }
case_duplicate() { invoke 2 --app "$APP" --app "$APP"; no_calls; }
case_relative() { invoke 2 --app relative.app; no_calls; }
case_suffix() { invoke 2 --app /Applications/WeChat; no_calls; }
case_control() { invoke 2 --app $'/invalid\npath.app'; no_calls; }
case_traversal() { invoke 2 --app "$TEMP_ROOT/../fixture.app"; no_calls; }
case_non_mac() { MOCK_PLATFORM=Linux; invoke 3 --app "$APP"; no_calls; }
case_missing_tool() { MOCK_MISSING_TOOL=1; invoke 3 --app "$APP"; no_calls; }
case_missing_app() { invoke 3 --app "$TEMP_ROOT/missing.app"; no_calls; }
case_missing_plist() { mkdir "$TEMP_ROOT/empty.app"; invoke 3 --app "$TEMP_ROOT/empty.app"; no_calls; }
case_app_link() { ln -s "$APP" "$TEMP_ROOT/link.app"; invoke 2 --app "$TEMP_ROOT/link.app"; no_calls; }
case_parent_link() { ln -s "$TEMP_ROOT" "$TEMP_ROOT/alias"; invoke 2 --app "$TEMP_ROOT/alias/fixture with spaces.app"; no_calls; }
case_plist_link() {
    mkdir -p "$TEMP_ROOT/plist-link.app/Contents"
    ln -s "$APP/Contents/Info.plist" "$TEMP_ROOT/plist-link.app/Contents/Info.plist"
    invoke 3 --app "$TEMP_ROOT/plist-link.app"; no_calls
}
case_wrong_id() { MOCK_ID=PRIVATE_ID_SENTINEL; invoke 3 --app "$APP"; }
case_ok() {
    invoke 0 --app "$APP"
    contains '270102'
    [ "$(/usr/bin/grep -c '^plist:' "$TEMP_ROOT/calls")" -eq 3 ]
    [ "$(/usr/bin/grep -c '^codesign:--display --verbose=4 ' "$TEMP_ROOT/calls")" -eq 3 ]
    [ "$(/usr/bin/grep -c '^codesign:--verify --deep --strict --all-architectures ' "$TEMP_ROOT/calls")" -eq 3 ]
}
case_x86() { MOCK_ARCH=x86_64; invoke 0 --app "$APP"; contains x86_64; }
case_bad_arch() { MOCK_ARCH=PRIVATE_ARCH_SENTINEL; invoke 1 --app "$APP"; contains '架构未知'; }
case_bad_os() { MOCK_OS=PRIVATE_OS_SENTINEL; invoke 1 --app "$APP"; }
case_bad_version() { MOCK_VERSION=PRIVATE_VERSION_SENTINEL; invoke 1 --app "$APP"; }
case_long_version() { MOCK_VERSION=123456789012345678901234567890123456; invoke 1 --app "$APP"; }
case_missing_build() { MOCK_BUILD_FAIL=1; invoke 1 --app "$APP"; }
case_adhoc() { MOCK_DETAILS=$'Signature=adhoc\nTeamIdentifier=not set'; invoke 1 --app "$APP"; contains 'Ad Hoc'; }
case_missing_team() { MOCK_DETAILS=TeamIdentifier=none; invoke 1 --app "$APP"; }
case_display_failure() { MOCK_DISPLAY_EXIT=1; invoke 1 --app "$APP"; contains '无法读取签名'; }
case_verify_failure() { MOCK_VERIFY_EXIT=1; invoke 1 --app "$APP"; contains '静态签名验证失败'; }
case_nested_failure() { MOCK_NESTED_FAIL=1; invoke 1 --app "$APP"; contains 'XPlayer.app：静态签名验证失败'; }
case_component_missing() {
    rmdir "$APP/Contents/MacOS/XPlayer.app"
    invoke 1 --app "$APP"
    contains '标准位置缺失'
    mkdir "$APP/Contents/MacOS/XPlayer.app"
}
case_component_link() {
    rmdir "$APP/Contents/MacOS/XPlayer.app"
    ln -s "$APP/Contents/MacOS/WeChatAppEx.app" "$APP/Contents/MacOS/XPlayer.app"
    invoke 1 --app "$APP"
    contains '标准位置缺失'
    rm "$APP/Contents/MacOS/XPlayer.app"
    mkdir "$APP/Contents/MacOS/XPlayer.app"
}

COUNT=0
for test_name in help help_extra unknown missing_arg empty_arg duplicate relative suffix control traversal non_mac missing_tool missing_app missing_plist app_link parent_link plist_link wrong_id ok x86 bad_arch bad_os bad_version long_version missing_build adhoc missing_team display_failure verify_failure nested_failure component_missing component_link; do
    # Running each case as a standalone subshell keeps errexit effective.
    ( "case_$test_name" )
    COUNT=$((COUNT + 1))
    printf 'PASS %s\n' "$test_name"
done

# Integration: real system tools, an unsigned synthetic bundle, hostile PATH,
# and before/after content + metadata checks. Never inspect the installed app.
"$PYTHON" - "$ROOT/scripts/check_environment.sh" "$TEMP_ROOT" <<'PY'
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys

script, root = Path(sys.argv[1]), Path(sys.argv[2])
app = root / 'literal $(touch NEVER_CREATED).app'
(app / 'Contents').mkdir(parents=True)
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleIdentifier': 'com.tencent.xinWeChat',
                  'CFBundleShortVersionString': '4.1.15',
                  'CFBundleVersion': '270102'}, stream)

def snapshot():
    items = {}
    for path in [app, *sorted(app.rglob('*'))]:
        stat = path.lstat()
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        if hasattr(os, 'listxattr'):
            attrs = {name: os.getxattr(path, name) for name in os.listxattr(path)}
        elif platform.system() == 'Darwin':
            attrs = subprocess.run(['/usr/bin/xattr', '-lx', str(path)],
                check=True, capture_output=True).stdout
        else:
            raise RuntimeError('No extended-attribute reader available')
        items[str(path.relative_to(app))] = (stat.st_mode, stat.st_size,
            stat.st_mtime_ns, stat.st_ctime_ns, stat.st_uid, stat.st_gid, digest, attrs)
    return items

before = snapshot()
poison = root / 'poison-bin'
poison.mkdir()
for name in ('uname', 'sw_vers', 'codesign', 'PlistBuddy'):
    path = poison / name
    path.write_text('#!/bin/sh\nprintf PATH_INJECTION_SENTINEL\nexit 0\n')
    path.chmod(0o755)
env = dict(os.environ, PATH=str(poison))
result = subprocess.run(['/bin/bash', str(script), '--app', str(app)],
    env=env, cwd=root, text=True, capture_output=True)
expected = 1 if platform.system() == 'Darwin' else 3
assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
assert snapshot() == before, 'Synthetic application changed'
assert str(root) not in result.stdout + result.stderr, 'Private path disclosed'
assert 'PATH_INJECTION_SENTINEL' not in result.stdout + result.stderr
assert not (root / 'NEVER_CREATED').exists(), 'Shell argument executed'
print('PASS real_tools_fixture_unchanged_and_path_isolation')
PY
COUNT=$((COUNT + 1))
printf '环境检查测试通过：%s 项。\n' "$COUNT"
