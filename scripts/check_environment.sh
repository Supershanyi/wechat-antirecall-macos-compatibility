#!/bin/bash
# macOS Bash 3.2 compatible. Only fixed, read-only system command modes are used.
# Sourcing defines functions for tests; it does not start a check.

run_uname() { /usr/bin/uname "$@"; }
run_sw_vers() { /usr/bin/sw_vers "$@"; }
run_plistbuddy() { /usr/libexec/PlistBuddy "$@"; }
run_codesign() { /usr/bin/codesign "$@"; }
tool_available() { [ -x "$1" ]; }

usage() {
    printf '%s\n' \
        '用法：bash scripts/check_environment.sh [--app /absolute/path/WeChat.app]' \
        '默认应用：/Applications/WeChat.app；--help 显示帮助。' \
        '只读取系统版本、指定应用的版本和签名；不启动微信、不访问聊天目录。' \
        '不写报告文件，不签名、不打补丁、不修改权限或系统安全设置。' \
        '退出码：0=静态检查完成；1=存在警告；2=参数错误；3=无法检查。'
}

warn() {
    CHECK_WARNINGS=1
    printf 'WARN %s\n' "$1"
}

# Reject aliases and traversal in the paths that this script explicitly reads.
# Internal framework links are handled by codesign, not walked by this script.
plain_path() {
    local rest="$1" part current=''
    case "$rest" in /*) ;; *) return 1 ;; esac
    rest=${rest#/}
    while [ -n "$rest" ]; do
        part=${rest%%/*}
        case "$part" in ''|.|..) return 1 ;; esac
        current="$current/$part"
        [ ! -L "$current" ] || return 1
        if [ "$rest" = "$part" ]; then break; fi
        rest=${rest#*/}
    done
}

numeric_version() {
    [ "${#1}" -le 32 ] && [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

check_signature() {
    local label="$1" target="$2" details line has_team=0 adhoc=0
    if details=$(run_codesign --display --verbose=4 "$target" 2>&1); then
        # Never forward raw diagnostics, certificate names, paths or identifiers.
        while IFS= read -r line; do
            case "$line" in
                Signature=adhoc) adhoc=1 ;;
                TeamIdentifier=*)
                    if [[ "${line#TeamIdentifier=}" =~ ^[A-Z0-9]{10}$ ]]; then
                        has_team=1
                    fi
                    ;;
            esac
        done <<< "$details"
        if [ "$adhoc" -eq 1 ]; then
            warn "$label：Ad Hoc 签名，无法据此确认官方身份。"
        elif [ "$has_team" -eq 1 ]; then
            printf 'INFO %s：存在 Team ID（未验证是否属于官方）。\n' "$label"
        else
            warn "$label：未获得有效 Team ID。"
        fi
    else
        warn "$label：无法读取签名。"
    fi
    if run_codesign --verify --deep --strict --all-architectures "$target" >/dev/null 2>&1; then
        printf 'PASS %s：静态签名验证通过。\n' "$label"
    else
        warn "$label：静态签名验证失败。"
    fi
}

main() {
    local app='/Applications/WeChat.app' app_seen=0 arg platform architecture version
    local plist identifier value key component target
    export LC_ALL=C
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    CHECK_WARNINGS=0
    if [ "$#" -eq 1 ] && [ "$1" = '--help' ]; then usage; return 0; fi
    while [ "$#" -gt 0 ]; do
        arg=$1
        case "$arg" in
            --app)
                if [ "$app_seen" -eq 1 ] || [ "$#" -lt 2 ] || [ -z "$2" ]; then
                    printf '%s\n' 'ERROR --app 需要唯一的绝对应用路径。' >&2
                    return 2
                fi
                app=$2; app_seen=1; shift 2
                ;;
            *) printf '%s\n' 'ERROR 参数无效；请使用 --help。' >&2; return 2 ;;
        esac
    done
    case "$app" in /*.app) ;; *) printf '%s\n' 'ERROR 路径必须是绝对 .app 路径。' >&2; return 2 ;; esac
    if [[ "$app" =~ [[:cntrl:]] ]] || ! plain_path "$app"; then
        printf '%s\n' 'ERROR 路径含控制字符、符号链接或非规范路径段。' >&2
        return 2
    fi
    platform=$(run_uname -s 2>/dev/null) || platform=''
    if [ "$platform" != Darwin ]; then
        printf '%s\n' 'ERROR 仅支持 macOS；未执行应用检查。' >&2
        return 3
    fi
    for target in /usr/bin/sw_vers /usr/libexec/PlistBuddy /usr/bin/codesign; do
        if ! tool_available "$target"; then
            printf '%s\n' 'ERROR 缺少必要的 macOS 系统工具。' >&2
            return 3
        fi
    done
    plist="$app/Contents/Info.plist"
    if [ ! -d "$app" ] || [ ! -f "$plist" ] || [ ! -r "$plist" ] || ! plain_path "$plist"; then
        printf '%s\n' 'ERROR 应用或 Info.plist 不存在、不可读或路径含符号链接。' >&2
        return 3
    fi
    identifier=$(run_plistbuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null) || identifier=''
    if [ "$identifier" != com.tencent.xinWeChat ]; then
        printf '%s\n' 'ERROR Bundle ID 不是预期的微信标识；停止检查。' >&2
        return 3
    fi
    printf '%s\n' '微信环境只读检查（不输出应用路径、账号及原始诊断）'
    version=$(run_sw_vers -productVersion 2>/dev/null) || version=''
    if numeric_version "$version"; then printf 'INFO macOS：%s\n' "$version"; else warn 'macOS 版本不可用。'; fi
    architecture=$(run_uname -m 2>/dev/null) || architecture=''
    case "$architecture" in
        arm64|x86_64) printf 'INFO 当前进程架构：%s\n' "$architecture" ;;
        *) warn '当前进程架构未知。' ;;
    esac
    for key in CFBundleShortVersionString CFBundleVersion; do
        value=$(run_plistbuddy -c "Print :$key" "$plist" 2>/dev/null) || value=''
        if numeric_version "$value"; then printf 'INFO %s：%s\n' "$key" "$value"; else warn "$key：缺失或格式异常，值已隐藏。"; fi
    done
    check_signature '主应用' "$app"
    for component in XPlayer.app WeChatAppEx.app; do
        target="$app/Contents/MacOS/$component"
        if [ -d "$target" ] && plain_path "$target"; then
            check_signature "$component" "$target"
        else
            warn "$component：标准位置缺失或路径含符号链接；此版本布局可能不同。"
        fi
    done
    printf '%s\n' '说明：未测试登录、聊天、视频或防撤回；签名通过不等于官方身份或功能兼容。'
    return "$CHECK_WARNINGS"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
