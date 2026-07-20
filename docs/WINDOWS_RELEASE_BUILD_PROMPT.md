# Windows Release Build Prompt

将下面整段 Prompt 交给运行在 Windows 11 或 Windows Server 2022 上的 Codex。构建机必须已安装：

- Visual Studio 2022，并勾选“使用 C++ 的桌面开发”、Windows 10/11 SDK 和 CMake；
- Git；
- Flutter 3.19.6（自带 Dart 3.3.4）；
- Rust 1.95.0，目标 `x86_64-pc-windows-msvc`；
- PowerShell 7。

```text
你正在 Windows PowerShell 7 中构建 VoceChat generation-2 E2EE Windows 正式制品。

目标：从当前已检出的 vocechat-client-uu 与 vocechat-server-rust-uu 精确 commit，构建
voce_e2ee_core.dll 和 Flutter Windows release，将完整运行目录压缩为 ZIP，并输出可审计
的 commit 与 SHA-256。只构建，不修改业务源码，不提交、不推送、不打 tag、不发布。

安全边界：
1. 不读取或输出 token、密码、用户数据、Android/iOS 签名材料。
2. 不关闭 TLS、签名、测试或静态检查。
3. 不用仓库里旧的 windows/libs/voce_e2ee_core.dll；必须从当前 Server commit 重建。
4. 不只复制 exe；ZIP 必须包含 Release 目录中的 DLL、data 和插件文件。
5. 任一步失败就停止并报告原始错误，不得把 BLOCKED/FAIL 写成 PASS。

假定目录：
- 客户端：C:\work\vocechat-client-uu
- 服务端：C:\work\vocechat-server-rust-uu
- 输出：C:\work\artifacts

执行：

$ErrorActionPreference = 'Stop'
$Client = 'C:\work\vocechat-client-uu'
$Server = 'C:\work\vocechat-server-rust-uu'
$Out = 'C:\work\artifacts'

foreach ($Path in @($Client, $Server)) {
  if (-not (Test-Path $Path)) { throw "Missing repository: $Path" }
  if (git -C $Path status --porcelain) {
    throw "Working tree must be clean before release build: $Path"
  }
}

$ClientCommit = git -C $Client rev-parse HEAD
$ServerCommit = git -C $Server rev-parse HEAD

flutter --version
dart --version
rustc --version
cargo --version
flutter doctor -v

rustup target add x86_64-pc-windows-msvc
cargo build `
  --manifest-path "$Server\crates\voce-e2ee-core\Cargo.toml" `
  --release `
  --target x86_64-pc-windows-msvc

$Dll = "$Server\target\x86_64-pc-windows-msvc\release\voce_e2ee_core.dll"
if (-not (Test-Path $Dll)) { throw "Missing E2EE DLL: $Dll" }
New-Item -ItemType Directory -Force "$Client\windows\libs" | Out-Null
Copy-Item $Dll "$Client\windows\libs\voce_e2ee_core.dll" -Force

Push-Location $Client
try {
  flutter clean
  flutter pub get
  dart format --output=none --set-exit-if-changed lib test
  flutter analyze --no-fatal-infos
  flutter test --timeout 90s `
    test/e2e_v2_attachment_test.dart `
    test/e2e_v2_backup_test.dart `
    test/e2e_v2_identity_device_test.dart `
    test/e2ee_v2_wire_test.dart
  flutter build windows --release

  $Release = "$Client\build\windows\x64\runner\Release"
  $Exe = "$Release\vocechat_client.exe"
  $BundledDll = "$Release\voce_e2ee_core.dll"
  if (-not (Test-Path $Exe)) { throw "Missing Windows executable: $Exe" }
  if (-not (Test-Path $BundledDll)) { throw "Missing bundled E2EE DLL: $BundledDll" }

  New-Item -ItemType Directory -Force $Out | Out-Null
  $Zip = "$Out\vocechat-windows-$ClientCommit.zip"
  if (Test-Path $Zip) { Remove-Item $Zip -Force }
  Compress-Archive -Path "$Release\*" -DestinationPath $Zip -CompressionLevel Optimal

  $ExeHash = (Get-FileHash $Exe -Algorithm SHA256).Hash.ToLowerInvariant()
  $DllHash = (Get-FileHash $BundledDll -Algorithm SHA256).Hash.ToLowerInvariant()
  $ZipHash = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLowerInvariant()

  Write-Host "PASS Windows release build"
  Write-Host "client_commit=$ClientCommit"
  Write-Host "server_commit=$ServerCommit"
  Write-Host "exe=$Exe sha256=$ExeHash"
  Write-Host "e2ee_dll=$BundledDll sha256=$DllHash"
  Write-Host "zip=$Zip sha256=$ZipHash"
} finally {
  Pop-Location
}
```

最终回复必须列出：工具链版本、两个 commit、测试数量、EXE/DLL/ZIP 路径与 SHA-256；如果
`flutter analyze` 只有仓库已知 info，也要列出数量，不能写成“零问题”。不要把 ZIP 上传到
GitHub、网盘或发布服务器，除非用户另行明确授权。
