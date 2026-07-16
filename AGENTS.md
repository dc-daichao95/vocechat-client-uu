# VoceChat Mobile Client Agent 指南
## 1. Scope / Purpose
- 本文件适用于仓库根目录及其所有子目录，属于全仓库、始终生效的执行约束。
- Agent 与开发者 MUST 按以下顺序建立上下文：
  1. 阅读 [`README.md`](README.md) 了解项目入口、当前状态与预期命令。
  2. 阅读本 `AGENTS.md` 了解强制规则与变更边界。
  3. 阅读 [`docs/PROJECT_REPORT.md`](docs/PROJECT_REPORT.md) 了解审计证据、风险和路线。
  4. 阅读与任务直接相关的源码、配置、测试和生成输入。
- `docs/PROJECT_REPORT.md` 是指定审计基线下的证据记录，不是永远正确的运行时规范。
- 源码、配置和实际可复现命令结果是最终事实源（source of truth）。
- 报告与当前代码冲突时，MUST 以代码和真实验证结果为准，并明确记录偏差。
- MUST NOT 把报告中的【推断】改写成未经验证的【事实】。
- MUST NOT 把 `BLOCKED`、未执行或缺少环境误报为 `PASS` 或 `FAIL`。
- 规则冲突时，用户的明确要求优先；仍 MUST 遵守安全、数据保护和证据真实性底线。

## 2. 当前事实与验证边界
- 本项目是 VoceChat 自托管服务器的 Flutter 移动客户端。
- 本仓库按独立 fork 维护，不假定与其他 VoceChat client 仓库自动同步；这是用户治理决策，不是 Git 可证明事实。
- 产品目标平台为 **Android、iOS、Windows**（Flutter）；MUST NOT 默认扩展到 Web 或 Linux/macOS 桌面，除非用户另行批准。
- **构建优先级（用户 2026-07-13）**：先打通 **Windows** 与 **Android** 可复现构建；iOS 在 macOS Runner 可用后再作为合并门禁。旧文「仅 Android/iOS」叙述以本条为准废止。
- 跨端 E2E 协议契约以 `vocechat-web-uu/docs/E2E_ENCRYPTION_DESIGN.md` 为源；本仓副本见 [`docs/E2E_ENCRYPTION_DESIGN.md`](docs/E2E_ENCRYPTION_DESIGN.md)。E2E 未 Accepted 前 MUST NOT 写生产加密代码。
- 当前应用版本为 `0.2.113+83`。
- 当前 Dart SDK 约束为 `>=2.17.0 <3.0.0`。
- 仓库未固定精确 Flutter SDK 版本，也未提供完整可复现工具链基线。
- MUST NOT 猜测、补写或宣称某个 Flutter 版本是项目既定版本。
- 当前审计环境无法从 `PATH` 解析 `flutter`、`dart` 和 `java`。
- 因此 format、analyze、test、代码生成和 Android / iOS build 均未在当前基线中验证。
- MUST NOT 声称现有测试、分析、生成或构建已经通过。
- 工具恢复后的每个结果 MUST 按 `PASS`、`FAIL` 或 `BLOCKED` 记录，并附环境和命令证据。
- 依赖解析尚不可完全复现：`pubspec.lock` 被忽略，`dependency_overrides` 中 `azlistview` 与 `voce_widgets` 两个 Git 依赖均跟随 `master`。
- `provider: ^6.0.5` 已声明，但静态检索未发现运行时代码使用；Riverpod 未安装。
- 当前仓库不存在 CI workflow；MUST NOT 声称 CI 已就绪。

## 3. Project Map
- `lib/main.dart`：Flutter binding、Firebase、组织数据库、登录恢复、路由、生命周期和通知入口。
- `lib/app.dart`：`App` 单例、当前账号、服务装配、用户数据库切换和连接重建。
- `lib/api/`：普通 API 的 Dio 统一边界、认证 header、token 刷新及业务 endpoint。
- `lib/api/models/`：API 请求、响应和事件 payload models。
- `lib/services/`：认证、SSE 同步、消息发送、文件处理、数据库和任务队列。
- `lib/services/persistent_connection/`：SSE 与未启用的 WebSocket 实现。
- `lib/dao/`：SQLite 数据访问及 DB/property models；property models 位于 `lib/dao/**/properties_models/` 等对应 DAO 目录，默认用户库 DAO 与组织库 `OrgDao` 必须区分。
- `lib/models/`：主要保存 UI model、custom config 和 share-extension model，不是 API 或 DB model 的默认目录。
- `lib/ui/`：聊天、联系人、设置、导航和通用 widget。
- `lib/l10n/`：英文、中文 ARB 输入；生成配置见 `l10n.yaml`。
- `assets/`：数据库 schema、图片、字体和 changelog 等打包资源。
- `android/`：Gradle、Manifest、权限、签名引用和网络安全策略。
- `ios/`：Runner、Info.plist、ATS、权限和 iOS 平台配置。
- `test/`：当前仅有空测试桩，不能提供有效回归保护。
- `docs/`：项目审计和维护文档；文档不能替代源码验证。

## 4. Architecture Invariants
### 4.1 API、认证与 token

- 新增普通业务 API MUST 经现有 `DioUtil` 统一边界访问，除非独立 PR 明确引入可测试的替代 adapter。
- 认证后的请求 MUST 使用当前账号 token，并通过 `x-api-key` 发送。
- 登录和 token 续期请求 MUST NOT 误加旧的或当前的 `x-api-key`。
- 普通认证请求遇到 401 / 403 时，MUST 保持“刷新 token 后以最新 header 重放原请求”的语义。
- token 刷新 MUST 避免并发刷新风暴、重复重放和跨账号 token 污染。
- 切换账号后，任何 retry 或异步回调 MUST NOT 使用前一账号的 token。
- API 变更 MUST 覆盖登录无 header、认证 header、续期、刷新失败和重放测试。
- MUST NOT 在普通功能 PR 中绕开 Dio 层直接复制认证、retry 或 TLS 逻辑。
- 遗留例外：`lib/services/file_uploader.dart` 当前直接创建 `Dio` 并手工设置 token，其 retry interceptor 已被注释；MUST NOT 描述为已统一认证或已保持 retry。
- 修改上传链路时 MUST 统一认证、TLS、token 刷新，并定义明确且可测试的 retry 条件、次数、退避和幂等语义。

### 4.2 SSE 与事件顺序

- 当前实时链路是 `Server → VoceSse → VoceChatService.handleSseEvent → EventQueue → handleEventStream → DB/UI`。
- heartbeat 与 kick 在 `handleSseEvent` 中直接处理，不进入 `EventQueue`。
- 其余入队事件 MUST 保持 `EventQueue` 串行处理；该边界决定事件顺序和 SQLite 写入次序。
- WebSocket 代码是未启用实现；MUST NOT 把其描述为当前运行路径。
- 启用 WebSocket MUST 使用独立、明确批准、可回滚且有兼容测试的连接策略 PR。
- SSE 变更 MUST 保持 ready、增量事件、断线重连和账号切换的既有语义。
- MUST NOT 绕过 `EventQueue` 并发写入同一批聊天同步数据。
- 新事件类型 MUST 明确定义解析、去重、顺序、持久化、UI 通知和未知字段策略。
- 重复事件、乱序输入和重连重放 MUST 有真实断言，不能只验证“没有抛异常”。

### 4.3 消息发送与 `localMid`

- 消息发送 MUST 经 `VoceSendService`；文件和音频任务 MUST 保持 `SendTaskQueue` 串行边界。
- `localMid` 是 optimistic UI、retry、SQLite 唯一约束和服务端 `cid` 回流的稳定关联 ID。
- 服务端真实 `mid` 返回或经 SSE 回流时，MUST 与原 `localMid` 正确对齐。
- MUST NOT 在没有迁移测试时改变 fake mid、`localMid`、server mid 或 `cid` 的关联规则。
- MUST NOT 破坏发送顺序、幂等性、失败状态、重试状态或 pending message 可恢复性。
- 队列当前并不自动去重；新增去重 MUST 明确定义 key、生命周期和失败重试语义。
- 发送链路改动 SHOULD 测试文本、文件、音频、失败重试、重复回流和进程重启恢复。

### 4.4 双数据库与多账号

- `org_chat.db` 是组织级数据库，保存 server、账号索引、token 元数据和当前状态。
- 每个 server / user 组合使用独立用户数据库保存消息、群组、联系人和用户设置。
- 账号切换 MUST 先收敛旧账号队列和异步任务，再关闭旧用户库并打开目标用户库。
- 多账号操作 MUST NOT 跨用户数据库读取、写入、缓存或复用 token。
- 组织库 DAO 与用户库 DAO MUST 显式选择正确句柄；禁止依赖模糊的全局当前库假设。
- schema migration MUST 前向追加、版本单调、可重复验证，并保护已有数据。
- 每次 migration MUST 验证全新安装建库和至少一个旧版本升级路径。
- destructive migration、直接删表或清空用户数据 MUST 有用户明确批准、备份和恢复方案。

### 4.5 旧状态机制

- 当前状态机制包括 `ValueNotifier`、Aware listener、EventBus、全局 service 和 `App` 单例。
- 修改旧功能时 MUST 保持 listener 订阅、取消订阅、生命周期和通知时序。
- 新代码 MUST NOT 新增全局单例、`App` 全局字段或新的全局 EventBus topic 耦合。
- 不得仅把现有全局对象包进一个“大 Provider”并称为完成架构迁移。
- 跨边界状态 SHOULD 先抽象成可注入 interface / adapter，再迁移具体页面或 feature。

## 5. Riverpod Target

- Riverpod 是渐进目标，不是当前已安装或已运行的架构。
- MUST NOT 声称 Riverpod、ProviderScope 或相关测试基础已经就绪。
- Riverpod 只能在独立、明确批准的依赖或迁移 PR 中引入。
- 普通功能、缺陷修复或安全补丁 MUST NOT 顺带执行全局状态迁移。
- 引入前 MUST 先建立相关旧行为测试、依赖边界和 rollback 方案。
- 新的有界状态 SHOULD 优先采用 Riverpod，但前提是已批准依赖并明确 ownership。
- 迁移 MUST 以单个 feature、页面或 controller 为单位，保留兼容 adapter。
- 每步 MUST 可独立验证和回滚，并且不改变 API、SSE、DB 和 `localMid` 语义。
- SHOULD 优先迁移连接状态、账号 session 或单一页面，禁止一次性重写。

## 6. Change Workflow

### 6.1 开工前

- MUST 运行 `git status --short`，识别 staged、unstaged 和 untracked 用户改动。
- MUST 阅读 `README.md`、本文件、项目报告及任务相关源码和测试。
- MUST 用一句话定义变更目的、允许修改的文件范围和明确不做的事项。
- MUST 识别生成文件、数据库、平台配置、安全和多账号影响。
- 若缺少会实质改变方案的用户决策，MUST 先提出聚焦问题。

### 6.2 实施中

- 功能和 bugfix MUST 测试先行：先写能失败的真实断言，再做最小实现。
- 安全或基础设施修复 MUST 先建立可观测失败证据或可复现检查。
- 一次变更 MUST 只有一个主要目的，diff SHOULD 小且可审查。
- MUST NOT 混合依赖升级、架构迁移和业务功能。
- MUST NOT 顺手格式化无关文件、重命名无关符号或清理无关代码。
- MUST 保留用户已有改动；不得覆盖、回滚或隐藏非本任务修改。
- MUST NOT 擅自修改版本号、changelog、依赖版本或平台 target。
- MUST NOT 擅自 commit、push、发布、打 tag、force push 或创建 release。
- MUST NOT 删除数据库、缓存、签名材料或用户数据。

### 6.3 收尾

- MUST 查看完整 diff，并确认只有预期文件和生成结果。
- MUST 执行与风险相称的 format、analyze、test、生成和平台验证。
- 无法执行时 MUST 报告准确阻塞原因、未覆盖范围和所需外部证据。
- MUST 区分 pre-existing failure 与 introduced failure，禁止笼统写“测试失败”。

## 7. Recipes

### 7.1 API / Model / JSON

- 修改 endpoint 时 MUST 检查请求方法、路径、header、query、body、timeout、retry 和错误映射。
- 修改 `json_serializable` model 时 MUST 修改源 `.dart`、注解和测试样例。
- `*.g.dart` 是 generated code，MUST NOT 手工编辑。
- 生成命令：
  `flutter pub run build_runner build --delete-conflicting-outputs`
- 生成后 MUST 检查 diff，确认只包含预期 serializer 变化。
- 示例：新增 nullable server 字段时，MUST 测试字段存在、缺失和 `null` 三种 payload。

### 7.2 i18n

- 用户可见文案 MUST 进入 ARB，不得在 widget 中新增硬编码中英文。
- 新增或修改 key 时 MUST 同步 `lib/l10n/app_en.arb` 与 `lib/l10n/app_zh.arb`。
- key、placeholder、plural / select 参数 MUST 在两份 ARB 中一致。
- `flutter gen-l10n` 的生成物 MUST NOT 手工编辑。
- 生成命令：`flutter gen-l10n`
- UI 验证 MUST 覆盖英文、中文、长文本、换行和缺失 key 风险。

### 7.3 DB Schema / Migration

- 先确认变更属于组织库还是用户库，禁止同时“顺便”改两套 schema。
- schema 输入与 migration 版本 MUST 同步，版本号只能前向增加。
- migration MUST 使用事务或具备等价原子性，并考虑中断后的重试行为。
- 新列 SHOULD 提供兼容 default 或 nullable 策略，避免旧数据无法打开。
- MUST 测试 fresh install、旧库逐级升级、数据保留、索引和唯一约束。
- 涉及 `local_mid` 时 MUST 验证既有消息映射和重复写入行为。

### 7.4 SSE Event

- MUST 从真实或脱敏 fixture 建立事件解析测试。
- MUST 检查 event type filter、队列顺序、重复事件、未知字段和 malformed payload。
- MUST 检查 ready 聚合写库、增量写库、UI 通知和连接状态。
- MUST 验证账号切换期间旧流事件不会写入新账号数据库。
- MUST NOT 在日志中输出完整事件 payload。

### 7.5 UI State

- MUST 明确状态 owner、创建与 dispose 生命周期、loading / error / empty / data 状态。
- 旧 Aware、EventBus 或 `ValueNotifier` 变更 MUST 检查重复订阅和内存泄漏。
- 新有界状态 SHOULD 通过可注入边界测试，不能依赖真实全局单例。
- widget test MUST 包含用户交互和可见断言，空 `test()` 不算测试。
- 多账号 UI MUST 验证切换后旧账号内容和通知不残留。

### 7.6 文件 / 媒体

- MUST 检查账号、会话和 `localMid` 对应的文件路径隔离。
- MUST 校验 MIME、扩展名、大小、权限、失败清理和取消行为。
- 上传 MUST 保持 chunk、进度和发送队列语义；修改该遗留链路时 MUST 按 4.1 统一认证、TLS、token 刷新并明确定义 retry。
- 日志 MUST NOT 输出本地敏感路径、消息正文、下载 URL query 或凭据。
- 测试 fixture MUST 使用最小脱敏文件，不得加入真实用户媒体。

### 7.7 Platform Config

- Android 变更 MUST 检查 Manifest merger、权限最小化、network security config 和 debug / release 差异。
- release signing MUST 继续从本地受控配置获取，禁止提交签名文件或密码。
- iOS 变更 MUST 检查 ATS、用途说明、entitlement、signing 和 provisioning 影响。
- cleartext 或 ATS exception MUST 限定到最小环境或域名，并记录业务理由。
- 平台配置变更 MUST 在目标平台真实构建；仅静态阅读不足以宣称有效。

## 8. Security Red Lines

- 默认网络策略 MUST 使用严格 TLS 和系统信任根。
- MUST NOT 新增或保留无条件 `badCertificateCallback => true` 等 TLS 绕过作为修复。
- MUST NOT 扩大 Android cleartext、信任 user CA 或 iOS `NSAllowsArbitraryLoads`。
- 自签证书只能通过显式、受控、可撤销、可审计的 per-server opt-in 支持。
- pin / 指纹 MUST 通过可信 out-of-band 渠道或管理员预配置建立；默认禁止静默 TOFU。
- 若产品未来显式批准 TOFU，MUST 明确风险、显示指纹并要求用户确认。
- pin mismatch MUST fail closed；pin 只能通过经审核的证书轮换流程更新。
- MUST NOT 在日志、异常、analytics、Issue、文档或 CI artifact 中输出 token、refresh token、password、API key 或消息敏感内容。
- URL、header、Dio error、SSE / FCM payload MUST 在记录前 redaction。
- MUST NOT 提交 `key.properties`、keystore、证书私钥、provisioning profile 或 production secrets。
- Firebase mobile config 通常不是传统服务器 secret，但 MUST 按 dev / staging / production 隔离。
- Firebase MUST 依靠 Security Rules、API restriction、App Check、配额和后端授权保护。
- 权限 MUST 遵循 least privilege；删除无业务依据的敏感权限优于扩大授权。
- 安全失败 MUST fail closed；不得通过禁用 TLS、lint、test 或权限检查“修复”。

## 9. Expected Commands
- 以下命令是预期工作流，当前均未在审计环境验证。
- 工具链恢复与记录：
  - `flutter --version`
  - `dart --version`
  - `flutter doctor -v`
- 依赖解析：`flutter pub get`
- 只检查格式：`dart format --output=none --set-exit-if-changed .`
- 静态分析：`flutter analyze`
- 测试：`flutter test`
- JSON 生成：`flutter pub run build_runner build --delete-conflicting-outputs`
- 本地化生成：`flutter gen-l10n`
- Android debug：`flutter build apk --debug`
- Android release：`flutter build apk --release`
- iOS release unsigned build（仅 macOS / Xcode）：`flutter build ios --release --no-codesign`
- Android release job MUST 使用批准的非生产、CI-only 临时测试 keystore；MUST 在 job 启动时生成，或从受控 CI secret 注入。
- job MUST 临时创建 `android/key.properties`，MUST NOT commit 或 log keystore、密码及配置内容，结束时 MUST 销毁临时 keystore 与 `key.properties`。
- 缺少 CI test keystore、临时配置或销毁证据时，release build MUST 标记 `BLOCKED` 且 MUST NOT merge。
- 该 job 只证明 release 编译与打包；production signing MUST 由独立 release pipeline 使用生产签名完成。
- iOS 命令 MUST 在 macOS 执行；Windows 结果不能替代 iOS build evidence。
- 命令失败时 MUST 修复根因或报告阻塞，MUST NOT 禁用 lint、test、TLS 或安全门禁。
### 9.1 完整 clean build 定义
- “完整 clean build”MUST 由批准的 CI 在全新 checkout 的精确 commit 上执行，MUST NOT 复用 `build/` 或 `.dart_tool/` 状态。
- pub cache MAY 复用，但依赖 MUST 由已提交的 `pubspec.lock` 和已 pin 的 Git dependency 解析。
- 门禁工作流 MUST 运行 `flutter clean`、`flutter pub get`、变更所需的 codegen / l10n，并确认没有意外 tracked diff。
- 门禁工作流 MUST 再运行 format check、`flutter analyze` 和相关 `flutter test`。
- Android Runner MUST 构建 debug 与 release APK；批准的 macOS Runner MUST 执行 `flutter build ios --release --no-codesign`。
- Android release MUST 遵守上述 CI test-keystore 契约；门禁仅证明编译与打包，不证明 production signing，正式签名、归档和商店交付属于独立 release pipeline。
- 任一步为 `BLOCKED` 或 `FAIL` 均不满足 merge gate；要求的步骤不得以 `N/A` 代替。
- 当前 CI、lockfile 与依赖 pin 尚未建立，因此 MUST NOT 声称该门禁已可执行或通过。
## 10. Quality Gates

- 所有适用的 MUST 合并门槛均须满足各自验收条件；format、test 和 Android / iOS 双平台 build 须有 `PASS` 证据。
- `flutter analyze` MUST 实际运行，不能以 `BLOCKED` 代替；相对记录基线 introduced issues MUST 为 0。
- 若仓库基线已有 analyze 问题，MUST 清楚记录完整命令结果、已知基线问题和差异；不得假称整体 `PASS`。
- MUST 运行相关 unit、widget 或 integration test，并包含真实断言。
- 当前 `test/` 是空桩；仅运行 `flutter test` 不能证明核心业务正确。
- 新增或修改行为 MUST 新增能验证结果、顺序或副作用的测试。
- 关键链路 MUST 人工验证：登录/续期、SSE、发送、账号切换、DB migration 或相关 UI。
- 生成输入变更 MUST 运行生成器并验证 generated diff。
- 平台配置变更 MUST 在对应平台执行 clean build。
- 每次合并前 MUST 由批准的 CI 与 macOS Runner 按 9.1 完成 Android 和 iOS 完整 clean build；该门槛不可豁免。
- 当前只允许 P0 稳定安全工作实施和准备 PR；CI workflow 不存在，仓库暂不具备合并条件，MUST NOT merge。
- P1 MAY 调研、设计和执行兼容性 spike，但 MUST NOT 进入生产代码或形成可合并升级 PR；只有 P0 验收完成后才允许 P1 实施。
- P2 功能仅 MAY 调研和设计；只有 P0、P1 均验收完成后才允许实施 feature PR。
- 外部构建证据不能替代该门槛，除非证据本身来自批准的 CI / macOS Runner。
- `BLOCKED` 只表示门槛未完成，不是 `PASS` 的替代；任一 MUST 合并门槛为 `BLOCKED` 时 MUST NOT 合并。
- 除已指定不可豁免的双平台完整 build 外，用户若明确调整其他门槛，MUST 记录 decision、范围和理由；仍 MUST NOT 将未执行或 `BLOCKED` 伪报为 `PASS`。

## 11. GitHub Flow

- `master` SHOULD 受保护，禁止直接推送和绕过 review。
- 每项工作 SHOULD 使用短生命周期分支和小型 Pull Request。
- PR MUST 描述范围、风险、测试证据、阻塞项和 rollback 方式。
- 提交、推送、建 PR、修改版本和发布 MUST 有用户明确要求。
- MUST NOT force push；尤其禁止对 `master` force push。
- MUST NOT 跳过 hooks 或质量检查来制造绿色状态。
- 依赖升级、架构迁移、安全整改和业务功能 SHOULD 分成独立 PR。

## 12. Definition of Done Checklist

- 每项 MUST 标记 `PASS`、`FAIL`、`BLOCKED` 或 `N/A`，并附证据或理由。
- 只有与改动确实无关的领域检查可标记 `N/A`；用户指定的 Android / iOS 完整 build 对任何合并都不可 `N/A`。
- `BLOCKED` 项不得勾选完成且 MUST NOT 合并；`FAIL` 不满足验收条件。
- [ ] 范围单一，未混入无关重构、依赖升级或版本修改。
- [ ] `git diff` 仅包含预期文件，用户原有改动被完整保留。
- [ ] 生成输入和 generated code 一致，未手改 `*.g.dart` 或 l10n 产物。
- [ ] 新文案已同步英文和中文 ARB，并验证 placeholder 一致。
- [ ] DB 归属、schema version、fresh install 和旧版升级均已检查。
- [ ] API、SSE、发送顺序、`localMid` 和多账号隔离未被破坏。
- [ ] TLS、日志、secrets、Firebase 环境和 least privilege 已审查。
- [ ] 新增行为有真实断言，且相关测试已有 `PASS` 证据。
- [ ] format 已 `PASS`；analyze 已实际运行且 introduced issues 为 0，已知基线问题及命令整体结果已如实记录。
- [ ] 批准的 CI / macOS Runner 已按 9.1 完成 Android debug / release APK 与 iOS release `--no-codesign` clean build；Android release 遵守 CI test-keystore 契约，且均 `PASS`；此项不可 `N/A`。
- [ ] 所有 MUST 合并门槛均已完成；任何 `BLOCKED` 项保持未勾选并阻止合并，其他门槛的调整 decision 已记录。
- [ ] 关键用户链路已人工验证并记录环境。
- [ ] README、报告或相关文档只在行为或流程确实变化时更新。
- [ ] 报告清楚区分 pre-existing failure 与 introduced failure。
- [ ] 未泄露任何实际 key、token、password、签名或消息内容。
- [ ] 未擅自 commit、push、force push、发布或删除数据。

## 13. Known Boundaries

- Agora 保留 API / model / UI 脚手架，但入口被注释、Agora RTC SDK 未安装、运行能力未验证；路线已延后。
- MUST NOT 在 P0 / P1 或无关功能中顺带完成 Agora。
- 产品支持范围：Android / iOS / Windows；构建与门禁按「Win+Android 优先，iOS 随后」执行，不为 Linux/macOS 桌面或 Web 承诺兼容。
- 路线顺序 MUST 保持：稳定与安全基线 → 渐进升级 → 功能开发。
- 当前仅 P0 可实施；P1 仅可调研、设计、兼容性 spike，P0 验收后才可实施。
- P2 功能仅可调研和设计，P0、P1 均验收后才可实施；各阶段 MUST NOT 提前进入生产代码或形成可合并 PR。
- MUST 先恢复可观测工具链基线，再宣称可复现或可构建。
- MUST NOT 在任务外顺手做全局重构、一次性重写或跨层清理。
- 若发现重大旁支问题，SHOULD 记录证据并单独建议，不扩大当前 diff。

## 14. Links

- 项目入口与当前状态：[`README.md`](README.md)
- 审计证据、风险和路线：[`docs/PROJECT_REPORT.md`](docs/PROJECT_REPORT.md)
- 跨端 E2E 对齐（Draft，未批准实现）：[`docs/E2E_ENCRYPTION_DESIGN.md`](docs/E2E_ENCRYPTION_DESIGN.md)
