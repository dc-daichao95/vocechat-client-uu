# VoceChat Mobile Client

VoceChat 自托管服务器的 Flutter 客户端。

本仓库面向 **Android / iOS / Windows**（构建优先级：Windows + Android 先打通；iOS 需 macOS）。
项目按独立 fork 维护，不假定与其他 VoceChat client 仓库自动同步。

## 项目状态
- 应用版本：`0.2.113+83`
- Dart SDK 约束：`>=2.17.0 <3.0.0`（本机验证基线见 `docs/DART3_BUILD_RUNBOOK.md`：Flutter 3.19.6）
- 支持平台：Android、iOS、Windows
- 实时连接：当前使用 SSE；WebSocket 路径已停用
- 维护顺序：**稳定与安全基线 → 渐进升级 → 功能开发**
- Agora：仅保留 API / model / UI 占位，Agora RTC SDK 未安装，延后评估且不进入当前主路径
- E2E 加密：仅协议契约文档（`docs/E2E_ENCRYPTION_DESIGN.md`）；**Flutter 客户端尚未实现**（Web/Server MVP 已落地）
- 状态管理：`provider` 已声明但静态未发现运行时使用；Riverpod 未安装、尚未迁移，仅作为渐进目标

## 本机构建验证（2026-07-13 / 2026-07-14）
- Android debug：`build\app\outputs\flutter-apk\app-debug.apk` — PASS
- Android release：`build\app\outputs\flutter-apk\app-release.apk` — PASS（临时测试 keystore，非生产）
- Windows release：`build\windows\x64\runner\Release\vocechat_client.exe` — PASS（需 VS「使用 C++ 的桌面开发」含 CMake）

工具链入口：`. C:\devtools\env319.ps1`（详见 runbook）。

## 文档入口
- [AGENTS.md](AGENTS.md)：仓库协作规则、变更边界和 Agent / 开发者执行约束。
- [docs/PROJECT_REPORT.md](docs/PROJECT_REPORT.md)：项目现状、架构证据、安全风险、验证边界与分阶段路线图。

开始修改前请先阅读这两份文档。README 只提供快速入口，不替代完整报告。

## 前置条件
- 与 `>=2.17.0 <3.0.0` 约束和现有依赖兼容的 Flutter / Dart 工具链
- Android SDK，以及与所选 Flutter 版本兼容的 JDK / Gradle 环境
- iOS 开发必须使用 macOS、Xcode，并按需配置 CocoaPods
- 一个可访问、版本兼容的 VoceChat server 和测试账号
- 对应环境的 Firebase mobile 配置
- release 构建所需的 Android signing 或 iOS signing 配置

Firebase 配置、签名文件、证书、token、密码及其他凭据必须按 dev / staging / production
环境独立管理。不得提交新的凭据，不得在日志、Issue、CI artifact 或文档中输出实际值。

## 恢复工具链基线
仓库未固定 Flutter 版本，不要猜测或宣称已有固定版本。可通过 Flutter archive 或 FVM
选择 bundled Dart 满足 `>=2.17.0 <3.0.0` 的 Flutter 候选，并依次运行：
```bash
flutter --version
dart --version
flutter doctor -v
```
记录实际工具链版本，先恢复 `analyze`、`test` 和 Android / iOS build 基线；基线恢复前
不要升级依赖或引入 Dart 3。当前 Windows 会话无法解析上述工具，流程仍未验证。

## Quick start
```bash
git clone https://github.com/dc-daichao95/vocechat-client-uu.git
cd vocechat-client-uu
flutter pub get
flutter run
```

运行前需要：
1. 连接或启动目标 Android / iOS 设备或模拟器。
2. 按目标环境提供 Firebase 等平台配置，但不要提交本地凭据。
3. 在应用中配置可访问的 VoceChat server。
4. 如有多个设备，使用 `flutter devices` 查看设备，再通过 `flutter run -d <device-id>` 选择。

## 预期开发工作流
以下命令均需在兼容工具链和依赖基线恢复后验证。
### 格式、检查与测试
```bash
# Format check：只检查，不改写文件
dart format --output=none --set-exit-if-changed .
# Static analysis
flutter analyze
# 当前测试为空桩；此命令暂不能代表有效回归保护
flutter test
```
### 代码与本地化生成
```bash
# JSON serialization 等生成代码
flutter pub run build_runner build --delete-conflicting-outputs
# 根据 ARB 生成 localization 代码
flutter gen-l10n
```
生成后应检查 diff，确认没有意外覆盖。`*.g.dart` 是 generated code，不应手工编辑。
### 合并门禁中的完整 clean build
“完整 clean build”必须由批准的 CI 在全新 checkout 的精确 commit 上执行，不复用 `build/`
或 `.dart_tool/` 状态。可以复用 pub cache，但依赖必须按已提交的 `pubspec.lock` 和已 pin 的
Git dependency 解析；当前仓库尚未满足这些前提。

门禁工作流必须先运行 `flutter clean`、`flutter pub get`，再运行变更所需的 codegen /
l10n，并确认没有意外 tracked diff；随后执行 format check、`flutter analyze` 和相关
`flutter test`。Android Runner 必须构建 debug 与 release APK；批准的 macOS Runner
必须执行 iOS release `--no-codesign` 构建。任何一步为 `BLOCKED` 或 `FAIL`，或要求的
步骤被标为 `N/A`，都不满足 merge gate。

该门禁只证明指定 commit 可编译并打包，不证明 production signing；正式签名、归档和商店
交付由独立 release pipeline 使用生产签名完成。
### Android 构建
```bash
flutter build apk --debug
flutter build apk --release
```
release APK 必须使用批准的非生产、CI-only 临时测试 keystore：job 启动时生成或由受控
CI secret 注入，临时创建 `android/key.properties`，禁止 commit / log，job 结束销毁；
缺少该测试 keystore 时结果为 `BLOCKED`，不得合并。
当前 Windows 会话尚未验证 debug 或 release APK 构建。
### iOS 构建
```bash
flutter build ios --release --no-codesign
```
iOS 构建只能在 macOS / Xcode 环境完成；正式归档还需要有效 signing 与 provisioning 配置。
Windows 环境不能验证该命令。

## 目录概览
```text
lib/
  main.dart                 # Flutter、Firebase、数据库、路由与生命周期入口
  app.dart                  # App 单例、当前账号、服务装配与账号切换
  api/                      # Dio HTTP、认证及业务 endpoint
  services/                 # 认证、SSE 同步、发送、文件和任务队列
  dao/                      # SQLite 数据访问
  models/                   # API、数据库与 UI 使用的数据模型
  ui/                       # 聊天、联系人、设置与通用 widgets
  l10n/                     # 英文和中文 ARB
android/                    # Android Gradle、Manifest 与网络策略
ios/                        # iOS Runner、ATS、权限与平台配置
assets/                     # SQLite schema、图片、字体与 changelog
test/                       # 当前仅有测试空桩
docs/                       # 项目审计与维护文档
```

## 核心架构
- `main.dart` 初始化 Flutter binding、Firebase、组织级 SQLite，并恢复当前账号。
- `App` 单例持有认证和聊天服务，账号切换时关闭旧用户库并重建服务。
- `api/` 基于 Dio 访问 VoceChat server；认证后请求使用当前账号 token。
- `services/` 处理认证、消息发送、文件、队列和实时同步。
- 实时链路当前固定使用 SSE；事件经串行队列处理后写入本地 SQLite 并通知 UI。
- 数据分为组织级数据库和按 server / user 隔离的用户数据库，以支持多账号。
- `dao/` 封装 SQLite 读写，`ui/` 通过全局 service、listener、EventBus 和
  `ValueNotifier` 获取状态；当前不是严格分层架构。

## 开发注意事项
- 不要手改 `*.g.dart`；修改源 model 后重新运行 `build_runner`。
- 新增或修改用户文案时，同步维护英文、中文 ARB，并运行 `flutter gen-l10n`。
- 修改 SQLite schema 必须提供可回滚、可测试的 migration，并覆盖旧数据升级路径。
- 网络默认目标是严格 TLS。当前代码和平台配置仍存在证书验证、cleartext / ATS 风险；
  不得把这些风险描述为已修复，也不要通过扩大不安全例外来绕过连接问题。
- 如需支持自签证书，应采用显式、受控、可撤销、可审计的 opt-in 方案。
- `test/` 目前只有空桩，`flutter test` 即使可运行也不能证明核心业务正确。
- 协作目标采用 GitHub Flow：短分支、Pull Request、自动检查、review 后合并。
- 当前只允许 P0 稳定安全工作实施和准备 PR；仓库没有 CI workflow，暂不具备合并条件。
- P1 仅可调研、设计和兼容性 spike，不得进入生产代码或形成可合并升级 PR；P0 验收完成
  后才允许 P1 实施。
- P2 功能仅可调研和设计；P0、P1 均验收完成后才允许实施 feature PR。
- P0 必须建立批准的 CI 与 macOS Runner。任何合并前，Android 和 iOS 完整 clean build
  都必须在该门禁中取得 `PASS`；`BLOCKED`、`FAIL` 或 `N/A` 均不可替代，也不可据此合并。
- `flutter analyze` 必须实际运行；相对已记录基线的 introduced issues 必须为 0。
  若基线已有问题，应如实记录完整命令结果和基线差异，不得把整体状态写成 `PASS`。
- 保持 server API、SSE、SQLite schema、`localMid` 和现有用户行为兼容，避免一次性重写。

## 当前已知限制与风险
- Dart 约束停留在 Dart 2，限制依赖与语言升级路径。
- 未固定 Flutter / Dart / JDK / Android SDK / Xcode 版本。
- 仓库没有 CI workflow，双平台构建和自动质量门禁尚未建立。
- `pubspec.lock` 被忽略，Git dependency 跟随 `master`，依赖解析不可完全复现。
- TLS 证书验证和 Android cleartext / user CA、iOS ATS 配置存在安全风险。
- Agora 只有 model / UI 占位，产品完成度未验证并已延后。
- 自动化测试不足，认证、SSE、发送队列、数据库迁移和关键 UI 缺少回归保护。

## 用户数据删除
用户可登录对应 VoceChat server 的 Web 前端，在 **My Account → Delete Account**
发起账号删除。执行前请确认目标 server、账号和数据范围，并先完成必要备份。

服务端管理员也可以按 VoceChat server 的官方运维流程处理数据库或数据目录，
但直接修改 SQLite 或删除服务端数据可能影响多个用户且通常不可逆。
此类操作必须先停止相关服务、验证备份可恢复，并由有权限的管理员执行；
不要仅依据本 README 直接运行破坏性数据库或文件命令。
