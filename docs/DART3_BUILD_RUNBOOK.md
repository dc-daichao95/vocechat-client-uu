# Android 构建工具链安装与问题修复归档

> 适用分支：`chore/dart3-build-attempt`（隔离实验分支，`master` 未改动）
> 记录日期：2026-07-10
> 目的：归档从零安装 Flutter/Android 工具链、越过依赖阻塞、尝试构建 Android APK 的完整流程与所有修复。
> 状态口径：本文档只记录已发生的事实与当前进度；未完成或未验证的步骤显式标注，不写成成功。
> 结果：debug 与 release APK 在本机（Windows + Flutter 3.19.6/Dart 3 + AGP 7.2）**构建成功**（release 用临时测试 keystore 签名）；正式发布签名/测试/iOS/CI 均未做。

---

## 1. 起始环境与结论

- 【事实】目标机器为 Windows（PowerShell）。审计基线 commit：`e38c2e2`；文档提交后 `master` 位于 `057c243`。
- 【事实】开工前机器上没有 `flutter`、`dart`、`java`，也没有 Android SDK；`JAVA_HOME`/`ANDROID_SDK_ROOT`/`FLUTTER_HOME` 均为空。
- 【事实】没有 `winget`/`choco`/`scoop` 包管理器，仅有 `git`（`C:\Program Files\Git`）。
- 【结论】要构建 APK 必须手动安装整套工具链，并解决“依赖不可复现”这一 P0 级根因（见第 4 节）。

---

## 2. 安装位置与镜像

所有工具集中安装在 `C:\devtools`，不修改系统全局 `PATH`；每次通过会话脚本注入环境。

| 组件 | 版本 | 路径 | 下载源 |
|---|---|---|---|
| Temurin JDK | 17.0.19+10 | `C:\devtools\jdk17` | 清华 Adoptium 镜像 |
| Flutter（Dart 2） | 3.7.12（Dart 2.19.6） | `C:\devtools\flutter` | `storage.flutter-io.cn` |
| Flutter（Dart 3，用于构建） | 3.19.6（Dart 3.3.4） | `C:\devtools\f319\flutter` | `storage.flutter-io.cn` |
| Android SDK | 见下 | `C:\devtools\android-sdk` | `dl.google.com` |

Android SDK 组件：`cmdline-tools;latest`(11076708)、`platform-tools`、`platforms;android-33`、`platforms;android-34`、`build-tools;34.0.0`、`build-tools;33.0.2`；已接受全部 SDK 许可。

镜像环境变量（写入会话脚本）：

```
FLUTTER_STORAGE_BASE_URL = https://storage.flutter-io.cn
PUB_HOSTED_URL           = https://pub.flutter-io.cn
```

### 会话环境脚本
- `C:\devtools\env.ps1`：Flutter 3.7.12（Dart 2）。
- `C:\devtools\env319.ps1`：Flutter 3.19.6（Dart 3），用于本次 APK 构建。

两个脚本都设置 `JAVA_HOME`、`ANDROID_SDK_ROOT`/`ANDROID_HOME`、上述镜像变量，并把对应 Flutter、JDK、cmdline-tools、platform-tools 前置注入本会话 `PATH`。

---

## 3. 安装流程（按实际执行顺序）

1. 测试下载源连通性：`storage.flutter-io.cn`、`pub.flutter-io.cn`、清华镜像、`dl.google.com`、`storage.googleapis.com`、`github.com` 443 均可达。
2. 建目录 `C:\devtools\dl`、`C:\devtools\android-sdk`。
3. 下载并解压 JDK 17（清华 Adoptium）到 `C:\devtools\jdk17`，验证 `bin\java.exe`。
4. 下载并布置 Android cmdline-tools 到 `C:\devtools\android-sdk\cmdline-tools\latest`。
5. 下载并解压 Flutter 3.7.12 到 `C:\devtools\flutter`；`flutter --version` 确认 Dart 2.19.6。
6. `flutter config --no-analytics --android-sdk C:\devtools\android-sdk`。
7. `sdkmanager --licenses` 自动接受许可，再安装 platform-tools / platforms / build-tools。
8. 因依赖阻塞（第 4 节）改用 Dart 3：下载解压 Flutter 3.19.6 到 `C:\devtools\f319\flutter`，`flutter --version` 确认 Dart 3.3.4。

### flutter doctor（Flutter 3.19.6）关键结果
- [√] Flutter 3.19.6
- [√] Android toolchain（Android SDK 34.0.0）
- [√] Chrome
- [!] Visual Studio 缺少 C++ 组件（与 Android APK 构建无关）
- [!] Android Studio 未安装（使用命令行 SDK，不影响构建）
- [X] `adb` 无法运行导致设备检测崩溃（不影响 `flutter build apk`）

---

## 4. 遇到的问题与修复

### 4.1 GitHub 连接间歇失败（网络）
- 【现象】`git push`、`git fetch`、`git ls-remote` 到 `github.com:443` 时好时坏，报 `Connection was reset` / `Could not connect` / `504`。百度、gitee、Google 源均正常，说明是到 GitHub 的间歇性受限。
- 【影响】文档分支推送、以及 `pubspec.yaml` 里两个 Git 依赖（`voce_widgets`、`azlistview`）拉取失败。
- 【修复】
  - 文档推送：重试直到连接窗口出现，`e38c2e2..057c243 master -> master` 推送成功。
  - Git 依赖：在 GitHub 可用的窗口内用 `git clone --depth 1`（带重试）把两个仓库克隆到本地缓存 `C:\devtools\gitdeps\`，再改为本地 path override（见 4.3）。
- 【备注】GitHub 镜像 `kkgithub.com` 当时返回 504、不稳定，未采用；最终以“本地克隆 + path override”解耦网络波动。

### 4.2 依赖不可复现导致 pub 解析失败（P0 根因）
- 【现象】`flutter pub get`（Dart 2.19.6）失败：
  `audioplayers >=5.0.0 requires SDK version >=3.0.0 <4.0.0`。
- 【根因】`pubspec.yaml` 同时声明 `audioplayers: ^5.2.0` 与 `environment sdk: ">=2.17.0 <3.0.0"`；而 `audioplayers` 全部 5.x 版本（5.0.0/5.1.0/5.2.0/5.2.1，经 pub.dev API 核实）都要求 Dart ≥3.0。由于 `pubspec.lock` 被 `.gitignore` 忽略、依赖使用浮动版本，干净检出会解析到需要 Dart 3 的版本，从而与项目自身的 Dart 2 约束冲突。
  - Dart 2.19 下：audioplayers 5.x 需要 Dart 3 → 失败。
  - Dart 3 的 Flutter 下：项目 `environment <3.0.0` 又会挡住。
  - 因此**未修改仓库无法从干净检出构建**，与项目报告中标记的 P0“依赖不可复现”风险一致。
- 【采用方案（用户决策）】走 Dart 3 升级路线，在隔离分支 `chore/dart3-build-attempt` 上操作，`master` 不动。

### 4.3 Dart 3 升级路线的具体修改（均在实验分支）
1. `pubspec.yaml`：`environment.sdk` 由 `">=2.17.0 <3.0.0"` 改为 `">=3.0.0 <4.0.0"`。
2. `pubspec.yaml`：`dependency_overrides` 的 `azlistview`、`voce_widgets` 由 Git 源改为本地 path：
   - `azlistview: path: C:/devtools/gitdeps/azlistview`
   - `voce_widgets: path: C:/devtools/gitdeps/voce_widgets`
3. 结果：`flutter pub get`（Flutter 3.19.6 / Dart 3.3.4）成功，解析 234 个依赖。

### 4.4 Gradle 发行包下载缓慢（构建卡住）
- 【现象】首次 `flutter build apk` 长时间停在 `assembleDebug` 无输出；`services.gradle.org` 下载 `gradle-7.5-all.zip` 极慢，wrapper dists 目录为空。
- 【修复】将实验分支 `android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 改为腾讯镜像：
  `https://mirrors.cloud.tencent.com/gradle/gradle-7.5-all.zip`。改后成功进入 Gradle 配置阶段。

### 4.5 Maven 依赖下载可靠性
- 【预防性修复】在实验分支 `android/build.gradle` 的 `buildscript.repositories` 与 `allprojects.repositories` 前置阿里云镜像：
  `maven.aliyun.com/repository/google`、`/central`、`/gradle-plugin`，保留官方 `google()`、`mavenCentral()` 作为回退。

### 4.6 legacy Gradle apply 弃用警告
- 【现象】构建输出提示 `app_plugin_loader` / 主 Gradle 插件的 imperative apply 已弃用。
- 【处置】非致命警告。因此选择 Flutter 3.19.6（仍支持 legacy apply；Flutter 3.29+ 才移除），本次不迁移到 declarative plugins block。

### 4.7 传递依赖 wechat_picker_library 1.0.6 使用过新 API（Dart 编译失败）
- 【现象】`kernel_snapshot` 编译失败：`wechat_picker_library-1.0.6` 的 `src/themes.dart`、`src/extensions.dart` 使用了 `WidgetState`/`WidgetStateProperty`（Flutter 3.22+）和 `Color.toARGB32()`（Flutter 3.27+），Flutter 3.19.6 没有这些 API。
- 【根因】浮动版本把 `wechat_assets_picker` 解析到 9.4.2，其 `wechat_picker_library: ^1.0.5` 又被解析成最新的 1.0.6；且 1.0.6 的 `environment.flutter` 声明为 `>=3.16.0`，与其实际使用的 3.22/3.27 API 不符，导致声明约束不可信。
- 【修复】在实验分支 `pubspec.yaml` 的 `dependency_overrides` 中 pin `wechat_picker_library: 1.0.5`（满足 assets 9.4.2 的 `^1.0.5` 与 camera 4.3.2 的 `^1.0.2`）。经核实 1.0.5 不含 `toARGB32`/`WidgetState`，与 Flutter 3.19.6 兼容；`flutter pub get` 通过。

### 4.8 exifinterface 1.4.2 触发 D8 dex 失败
- 【现象】`:app:mergeExtDexDebug` 失败：
  `Failed to transform exifinterface-1.4.2.aar ... D8: java.lang.NullPointerException: Cannot invoke "String.length()" because "<parameter1>" is null`。
- 【根因】AGP 7.2.0 自带的 D8 版本过旧，无法 dex 较新的 `androidx.exifinterface:exifinterface:1.4.2`（由图像相关插件传递引入）。
- 【修复】在实验分支 `android/app/build.gradle` 增加：
  ```gradle
  configurations.all {
      resolutionStrategy {
          force 'androidx.exifinterface:exifinterface:1.3.7'
      }
  }
  ```
  强制降级到 1.3.7，避开 D8 NPE。

### 4.9 release 签名（临时测试 keystore）
- 【背景】`android/app/build.gradle` 的 release `signingConfig` 从 `key.properties` 读取签名信息；仓库不含该文件。
- 【处置（非生产）】用 JDK keytool 生成**一次性测试 keystore** `C:\devtools\keys\test-release.jks`（别名 testkey，口令 android，有效期 3650 天），并在工作树 `android/key.properties` 指向它。仅用于本机 release 验证，**不是生产签名**，不提交仓库。

### 4.10 release 资源校验失败：aapt2 无法解析 android-35/36
- 【现象】`:photo_manager:verifyReleaseResources`、随后 `:sqlite3_flutter_libs:verifyReleaseResources` 失败：
  `aapt2 ... RES_TABLE_TYPE_TYPE entry offsets overlap` / `failed to load include path ...\platforms\android-36\android.jar`（及 android-35）。
- 【根因】浮动版本把 `photo_manager` 解析到 3.10.0（compileSdk 36）、部分插件用 compileSdk 35；而 AGP 7.2 自带的 aapt2 太旧，无法解析 android-35/36 资源表。debug 不跑资源校验，故只在 release 暴露。
- 【修复】
  1. pin `photo_manager: 3.5.0`（compileSdk 34，满足 assets 的 `^3.5.0`、camera 的 `^3.2.3`）。
  2. 在 `android/build.gradle` 增加全局钩子，把所有 Android 子模块的 `compileSdkVersion` 统一降到 34（匹配 AGP 7.2 的 aapt2），并注意在 `evaluationDependsOn(':app')` **之前**注册 `afterEvaluate`，否则报 `Cannot run Project.afterEvaluate(Closure) when the project is already evaluated`。
- 【结果】release 构建通过。

---

## 5. 当前状态（截至记录时）

- 【已验证】工具链安装成功：Flutter 3.7.12 与 3.19.6、JDK 17、Android SDK 34。
- 【已验证】`flutter pub get`（Dart 3.3.4）成功解析依赖。
- 【已验证】`flutter build apk --debug` 成功。
  - 产物：`build\app\outputs\flutter-apk\app-debug.apk`，约 197.5 MB（debug 未裁剪、含多 ABI），构建于 2026-07-10 19:03。
- 【已验证】`flutter build apk --release` 成功（临时测试 keystore 签名）。
  - 产物：`build\app\outputs\flutter-apk\app-release.apk`，约 66.3 MB（R8 裁剪 + AOT），构建于 2026-07-10 19:24。
- 【范围】以上为 **debug 与 release** APK 在本机 Windows + Flutter 3.19.6（Dart 3）+ AGP 7.2 下成功；release 使用**非生产临时测试 keystore**，不代表正式发布签名；未跑测试，也未在 CI / macOS Runner 上验证 iOS。这些不满足合并门禁。

---

## 6. 复现命令速查

```powershell
# 载入 Dart 3 构建环境（含 JDK/Android SDK/国内镜像）
. C:\devtools\env319.ps1

# 在实验分支工作树中
cd C:\Users\Administrator\.config\superpowers\worktrees\vocechat-client-uu\dart3-build

flutter pub get
flutter build apk --debug
# 产物：build\app\outputs\flutter-apk\app-debug.apk
```

---

## 7. 后续建议（与项目报告 P0/P1 一致）

- 这些修改属于**实验性构建验证**，尚未合入 `master`；是否采纳 Dart 3 升级应作为 P1 决策，并配套测试与 CI。
- 若确定长期方向，应把“提交 `pubspec.lock` + pin 两个 Git 依赖到固定 commit”纳入 P0，以获得可复现构建（当前用本地 path override 只是绕过网络波动的临时手段）。
- Gradle/Maven 国内镜像与 `gradle-wrapper` 改动应通过统一、可审计的方式管理，避免散落在个人环境。
- APK 构建成功后，仍需按门禁要求在批准的 CI / macOS Runner 上完成 Android + iOS 完整 clean build 才满足合并条件。
