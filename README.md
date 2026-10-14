# macOS 微信兼容性只读检查与通用排查流程

> 社区经验整理 · 非官方项目 · **只读检查，不提供一键修复或防撤回补丁**
>
> 历史案例：macOS / Apple Silicon / 微信 4.1.15（Build 270102）。该案例来自原始说明，本次开发未复现其功能；其他版本必须重新核验，不得复用补丁地址或二进制字节。

## 快速开始：只读环境检查

在仓库根目录运行；无需管理员权限，无需退出或启动微信：

```bash
bash scripts/check_environment.sh
bash scripts/check_environment.sh --help
# 可选：检查自己持有且来源可信的应用包，使用规范的绝对路径
bash scripts/check_environment.sh --app '/path/to/your/verified/WeChat.app'
```

脚本读取 macOS 版本、当前进程架构、微信版本/Build，以及主应用、已知播放器和扩展组件的签名状态。不会写入微信、聊天数据或系统安全设置，也不会启动应用、重签名、打补丁、联网或保存日志。输出不包含应用路径、账号、Team ID 值和原始工具错误。

要求 macOS 自带 Bash 3.2、`uname`、`sw_vers`、`PlistBuddy`、`codesign`。退出码：`0` 静态检查完成且无上述警告；`1` 签名、版本或组件存在警告；`2` 参数错误；`3` 系统不支持、应用缺失或无法检查。Team ID 存在不证明官方身份；已知组件路径在其他版本可能变化。架构是当前进程视角，不能据此判断硬件型号或应用所有支持的架构。

检查不需要聊天数据。请只对可信应用包运行，不以本脚本检查恶意构造的包。对于 Ad Hoc 签名，脚本会给出警告；即使退出码为 0，也未验证防撤回、视频、登录、账号安全或任何版本的功能兼容性。

## 仓库结构与验证

- `scripts/check_environment.sh`：只读环境检查。
- `scripts/audit_public_files.py`：公开文本白名单、常见敏感信息及 Git 暂存区检查。
- `tests/`：隔离的合成夹具测试；仅向临时目录写入，不测试实际微信。
- `docs/READ_ONLY_REVIEW.md`：逐项命令和只读边界审查。
- `docs/VALIDATION_REPORT.zh-CN.md`：中文验证结果，不含私人运行日志。
- `SECURITY.md`、`.gitignore`、`PUBLISH_CHECKLIST.txt`：反馈、隐私和发布约束。

开发验证另外需要 Python 3.9+ 和 Git，无第三方 Python 依赖：

```bash
bash -n scripts/check_environment.sh tests/test_check_environment.sh
bash tests/test_check_environment.sh
python3 -B tests/test_audit_public_files.py
python3 -B scripts/audit_public_files.py
# 完成 git add 后，再验证实际暂存内容
python3 -B scripts/audit_public_files.py --staged
```

扫描器拒绝白名单以外的文件，包括被 `.gitignore` 忽略的私密文件；请不要在公开目录保存私有证据。扫描与人工审阅必须同时通过。未选择开源许可证，公开可见不等于授予任意使用或再分发许可。

## 目标与边界

在已有、合法取得的微信安装包和防撤回方案基础上，排查“防撤回可用，但视频无法播放 / 应用闪退 / 录屏授权反复弹窗”等兼容问题。优先保护本地聊天数据、官方签名组件与回退能力。

本文不提供修改后的微信安装包、腾讯专有二进制、可直接应用的补丁字节或绕过系统保护的脚本；不保证适用于其他设备、构建号或未来版本。修改客户端可能违反软件服务条款，亦可能影响安全性与自动更新，请自行评估。

## 原理概览

在原始说明记录的一个案例中，整包递归 Ad Hoc 重签名后，微信虽可运行，但视频组件出现异常。替代思路是：仅修改经版本核验的必要核心文件，对确需变更的主程序和核心库单独签名，尽可能保留 `XPlayer.app`、`WeChatAppEx.app`、`libwxld.dylib`、`WCDYWrapper.framework` 等组件的原始签名及资源。

**注意：** 主程序使用 Ad Hoc 签名后，其 Team ID 与官方程序不同。即使 `codesign --verify` 通过，也不代表容器权限、Gatekeeper、TCC、视频或登录一定正常。为兼容不同 Team ID 而增加 `com.apple.security.cs.disable-library-validation` 属于安全权限放宽，需要单独审查风险；它不等于恢复官方身份。

## 0. 准备

- 确认 Mac 型号、macOS 版本、微信显示版本及 **Build**。
- 获取可信的官方微信安装包，核验安装包来源和官方签名；不要从陌生渠道下载已修改的 `.app`。
- 完全退出微信；不要在聊天数据库正在写入时制作静态副本。
- 保留官方程序原件、隔离的候选程序、独立聊天数据备份和操作日志。不要在原版上直接试验。
- 备份应覆盖实际使用的 `~/Library/Containers/` 和 `~/Library/Group Containers/` 下相关微信数据，具体名称以本机为准；不要凭目录名称推断全部聊天数据位置。

## 1. 只读检查版本与签名

```bash
APP='/Applications/WeChat.app'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"
/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1 | /usr/bin/grep -E 'Identifier=|TeamIdentifier=|Authority=|Signature='
/usr/bin/codesign --verify --deep --strict --all-architectures "$APP"
echo "codesign_exit=$?"
```

`codesign_exit=0` 只说明签名验证通过，不是功能验收。

## 2. 备份及验证

1. 退出微信，确认相关进程停止。
2. 使用系统备份工具或保留元数据的复制方式制作**独立**副本；备份路径应在被备份目录之外。
3. 记录复制时间、文件数量、文件大小、错误日志；检查可读取性。
4. 内容校验应**不跟随符号链接**，逐文件比较路径、类型、大小、哈希以及链接目标；必要时另核验 ACL、扩展属性、权限。
5. `Data/Desktop` 等可能是指向用户目录的符号链接；不要使用会跟随链接的递归遍历导致循环引用。
6. 未进行恢复演练的备份只能称“内容核验通过”，不能称“已证明可完整恢复”。

## 3. 候选程序构建：原则而非通用补丁

1. 在独立目录复制**官方且经过验证**的同一 Build 程序。
2. 根据该 Build 的专门分析，限定最小修改范围；不能将某个 Build 的地址、指令字节照搬到新版本。
3. 不要使用 `codesign --deep --force --sign -` 对整个应用及所有嵌套组件一键递归重签。
4. 只对确实发生修改、确实需要签名的对象采取明确的签名策略；对视频组件保留官方签名，并比较签名前后 CDHash 与 Team ID。
5. 对主程序的 entitlements 差异逐项审查；不得把权限放宽当成“无风险修复”。
6. 构建后检查完整文件清单：除预先批准的文件和签名资源外，不应有意外变更。

**此步骤不能仅凭本文自动执行。** 必须先获得对应版本的独立补丁分析、原始文件哈希、修改清单和审计结果。

## 4. 候选程序静态验收（只读）

把 `CANDIDATE` 改成你**自己已制作并审计过**的候选 `.app` 路径：

```bash
CANDIDATE='/path/to/your/verified/WeChat.app'
[ -d "$CANDIDATE" ] || { echo 'STOP: candidate missing'; exit 1; }
/usr/bin/codesign --verify --deep --strict --all-architectures --verbose=2 "$CANDIDATE"
echo "candidate_codesign_exit=$?"
/usr/bin/codesign -dv --verbose=4 "$CANDIDATE/Contents/MacOS/XPlayer.app" 2>&1 | /usr/bin/grep -E 'TeamIdentifier=|Authority=|CDHash='
/usr/bin/codesign -dv --verbose=4 "$CANDIDATE/Contents/MacOS/WeChatAppEx.app" 2>&1 | /usr/bin/grep -E 'TeamIdentifier=|Authority=|CDHash='
```

如路径不存在、签名验证失败、官方组件身份改变或文件差异超出预期，**停止**，不要部署。注意：不同版本的内部路径可能改变。

## 5. 部署与功能验收

在确认独立数据备份、原版程序备份、候选静态验收通过后，才考虑**可回退部署**。建议先隔离测试；不要直接覆盖唯一可用原版，也不要在异常时点“初始化/清空/修复聊天数据”。

按顺序检查：微信能否启动；历史聊天能否读取；用另一账号发送并撤回测试文字，原消息是否保留；聊天视频、朋友圈视频、视频号是否播放；截图/录屏是否正常。每项记录 PASS / FAIL / NOT TESTED。视频能播放不代表全部媒体场景都通过；短期通过不代表长期稳定。

## 6. 录屏权限弹窗

若应用反复提示“录屏权限未开启”，先通过 **系统设置 → 隐私与安全性 → 录屏与系统录音** 为当前微信授权，并按提示重启应用。

本项目只读脚本不会调整或重置授权，也不提供权限重置自动化。若仍有异常，请核对应用来源、签名与系统提供的说明；不要修改 TCC 数据库或关闭 SIP。本次开发和验证没有操作这些设置。

## 7. 回退与异常处理

- 启动闪退：停止测试，保留崩溃日志；核对主程序与嵌套组件签名。
- 聊天记录为空：立即停止，不初始化、不清理、不覆盖数据；先检查沙盒授权及原版回退条件。
- 视频不能播：重点检查播放器/扩展组件签名与 Team ID，避免再次整包递归重签。
- 防撤回失效：先核对 Build 是否变化；不要盲目重复打补丁。
- 录屏授权循环：先按第 6 节处理，不要动 SIP。

回退前先确认微信已退出、原版程序备份真实存在且签名有效。回退应用本身不保证恢复因签名身份改变造成的容器授权状态。不要直接覆盖唯一备份。

## 8. 一个案例的验证范围

原始说明记载的某次本地测试中：微信 4.1.15 / Build 270102 的候选程序通过静态签名检查；当时用户确认应用能启动、历史聊天可见、文字消息撤回后仍保留、视频能播放，并通过重置/重新授权解决录屏权限提示。本次只读脚本开发没有独立复现这些功能。

这只是**单机单版本的结果**，并非跨机器成功率、长期稳定性或未来版本兼容性保证。

## 9. 公开发布前自查

- [ ] 删除用户名、真实家目录、邮箱、账号、设备标识、截图中的联系人/聊天内容。
- [ ] 删除聊天数据库、登录态、Cookie、密钥、令牌、崩溃报告中的个人标识。
- [ ] 不上传官方 `.app` / `.dmg`、修改后的二进制、完整个人备份或未经审查的运行日志。
- [ ] 不上传可用于重放本机授权的配置文件、entitlements 原件或含敏感路径的 JSON。
- [ ] 仅发布自行撰写的说明、已脱敏的命令示例和必要的审计方法。
- [ ] 对版本适用范围、签名身份变化、安全风险、回退限制做醒目说明。

## 免责声明

本文为技术排查经验，不隶属于微信、腾讯或相关插件项目。第三方客户端修改存在账号、数据、安全及服务条款风险。使用者自行决定是否操作并承担相应风险。
