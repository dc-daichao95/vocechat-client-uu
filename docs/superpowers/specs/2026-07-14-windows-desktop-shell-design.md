# Windows Desktop Shell & Chat UX — Design Spec

Date: 2026-07-14  
Repo: `vocechat-client-uu`  
Status: Approved for planning (awaiting user review of this file)

## 1. Goal

Make the Windows exe usable as a desktop client aligned with Web navigation and common desktop chat habits, while keeping Android on the existing mobile shell. Ship all requested capabilities in one implementation cycle.

## 2. Decisions (locked)

| Topic | Choice |
|-------|--------|
| Overall layout | **A — Web-like**: left rail + mid list + chat pane |
| Delivery | **All features in one pass** |
| Refresh | Reconnect SSE + refresh session list; keep current chat open |
| Saved / Files | Align with Web: global Saved + global file index |
| Platform shell | Windows-only desktop shell; Android/iOS keep bottom tabs |
| Approach | Conditional `Platform.isWindows` desktop shell (not full cross-platform rewrite) |

## 3. Feature scope

### 3.1 Windows desktop shell

- Entry: `ChatsMainPage` branches on `Platform.isWindows` into a new `DesktopShell` (name may vary).
- **Left rail**
  - Current server/account avatar → open account switcher (reuse `ChatsDrawer` data / `App.changeUser`).
  - `+` → add server/account via existing `ServerPage(showClose: true)`.
  - Settings gear → existing `SettingPage`.
- **Mid pane** sections (Web-aligned):
  - **Channels** — group chats
  - **People** — DMs / contacts entry to DM
  - **Saved** — global favorites (`SavedApi` / existing saved models)
  - **Files** — aggregate file messages across chats (local DB query of file-type messages; open parent chat or download)
- **Right pane** — selected `VoceChatPage`, or empty placeholder when none selected.
- New channel / new DM actions stay available from mid-pane or chat chrome; they must **not** replace the server `+`.

Out of scope for shell: redesigning Android/iOS navigation.

### 3.2 Refresh

- Affordance: chat (or shell) toolbar refresh control.
- Action: renew/reconnect persistent connection (`chatService` init / SSE) + re-run chat list prepare (`prepareChats` / equivalent).
- Must not pop the open conversation on success.
- On failure: SnackBar; keep previous list data.

### 3.3 Enter to send

- In `ChatTextField` / `AppMentions` on desktop (at least Windows): **Enter** sends; **Shift+Enter** inserts newline.
- Fix current mismatch: multiline + `TextInputAction.newline` prevents reliable `onSubmitted` on desktop — use `Shortcuts` / `KeyboardListener` / `CallbackShortcuts`.

### 3.4 Send emoji

- Input-bar emoji button opens a compact in-app emoji panel.
- Selecting an emoji inserts at the caret (compose path), then user can send normally.
- Message long-press reactions remain as today (separate from compose picker).

### 3.5 Settings button

- Exposed on the Windows left rail (gear).
- Reuses `SettingPage`; no new settings IA required in this pass unless E2E toggles already exist elsewhere.

### 3.6 File message E2E (encrypt + decrypt)

**Send (already implemented)** — keep:

- `E2eCrypto.encryptFileBytes` → upload ciphertext (`*.e2e`) → `vocechat/e2e` envelope with wraps / path / fiv.

**Receive (to implement)**:

1. `_decryptE2eInPlace` file branch keeps `content_type` as file (not demote to text label).
2. Persist props: `e2e`, `e2e_file_path`, `e2e_file_fiv`, name, size, mime.
3. Add `E2eCrypto.decryptFileBytes` (AES-GCM over downloaded ciphertext using envelope key material).
4. `VoceFileBubble` / `FileHandler`: when E2E props present, download ciphertext → decrypt locally → open/save plaintext temp/cache file.
5. Decrypt failure → failed bubble state + retry; do **not** rewrite as fake plaintext text message.

Applies to Windows and Android (shared services).

### 3.7 Multi-server via `+`

- Left-rail `+` = add server/account only.
- Avatar / switcher = switch among logged-in accounts (`App.changeUser`).
- Respect existing preset-server URL guards if `SharedFuncs.hasPreSetServerUrl()` disables multi-server.

## 4. Architecture

```
ChatsMainPage
 ├─ if Windows → DesktopShell
 │    ├─ ServerRail (avatar, +, settings)
 │    ├─ MidNav (Channels | People | Saved | Files)
 │    └─ ChatHost (VoceChatPage | empty)
 └─ else → existing CupertinoTabScaffold

ChatTextField
 ├─ Keyboard: Enter send / Shift+Enter newline
 └─ EmojiButton → EmojiPanel → insert into mentions controller

VoceChatService._decryptE2eInPlace (file)
 └─ FileHandler / VoceFileBubble → decryptFileBytes on download
```

Reuse existing DAOs/APIs: group/user lists, `SavedApi`, `FileHandler`, `ServerPage`, `SettingPage`, `ChatsDrawer` account list.

## 5. Error handling

| Case | Behavior |
|------|----------|
| Refresh fails | SnackBar; keep old list and open chat |
| E2E file decrypt fails | Bubble error + retry; keep ciphertext metadata |
| Add server / login fails | Existing auth error UI |
| Missing peer keys on file send | Existing E2E send failure path (no plaintext fallback when E2E required) |

## 6. Testing / acceptance

### Windows Release

1. Desktop three-pane shell shows Channels, People, Saved, Files; Settings and multi-server add/switch work.
2. Refresh reconnects without closing the open chat.
3. Enter sends; Shift+Enter newlines; emoji inserts and sends as text.
4. Send encrypted file from A; B downloads, decrypts, and opens; server store remains ciphertext.
5. Own bubbles remain right-aligned (existing layout work).

### Android (optional same cycle)

1. `flutter build apk --release` succeeds on this machine’s SDK/JDK/keystore.
2. No desktop shell; bottom tabs unchanged.
3. Enter/emoji/refresh/file decrypt paths work where applicable on device/emulator.

## 7. Non-goals

- Full Web pixel parity.
- Replacing mobile navigation with the desktop shell.
- New server-side APIs for global files index (use local message DB first).
- Full emoji category browser parity with OS emoji panel (compact panel is enough).

## 8. Implementation order (for planning)

1. Desktop shell skeleton + server rail (+ / switch / settings)
2. Mid pane sections (Channels / People / Saved / Files)
3. Chat chrome: Refresh
4. Input: Enter/Shift+Enter + emoji panel
5. File E2E receive/decrypt path
6. Windows Release + Android APK verification
