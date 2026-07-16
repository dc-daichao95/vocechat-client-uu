# voce_e2ee_core.dll (Windows)

Copy from server build:

```powershell
cargo build -p voce-e2ee-core --release
Copy-Item ..\vocechat-server-rust-uu\target\release\voce_e2ee_core.dll .\voce_e2ee_core.dll
```

CMake installs this file next to `vocechat_client.exe` on build.
