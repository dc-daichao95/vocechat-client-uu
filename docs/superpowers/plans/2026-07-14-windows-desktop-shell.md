# Windows Desktop Shell & Chat UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Windows-only Web-like three-pane shell plus Enter-to-send, emoji compose, refresh, and E2E file decrypt, while Android keeps the existing tab shell.

**Architecture:** `ChatsMainPage` branches on `Platform.isWindows` into `DesktopShell` (server rail + mid nav + embedded chat). Input fixes live in `ChatTextField`. File decrypt extends `E2eCrypto` + `_decryptE2eInPlace` + `FileHandler`/`VoceFileBubble`.

**Tech Stack:** Flutter 3.19 / Dart, existing VoceChat DAOs/APIs, pointycastle E2E crypto already in-tree.

**Spec:** `docs/superpowers/specs/2026-07-14-windows-desktop-shell-design.md`

---

## File map

| Path | Role |
|------|------|
| `lib/ui/chats/chats/desktop/desktop_shell.dart` | Windows three-pane host |
| `lib/ui/chats/chats/desktop/desktop_server_rail.dart` | Avatar / + / settings |
| `lib/ui/chats/chats/desktop/desktop_mid_nav.dart` | Channels / People / Saved / Files |
| `lib/ui/chats/chats/desktop/desktop_files_page.dart` | Global file message list |
| `lib/ui/chats/chats/chats_main_page.dart` | Branch Windows → DesktopShell |
| `lib/ui/chats/chat/input_field/chat_textfield.dart` | Enter/Shift+Enter + emoji |
| `lib/ui/chats/chat/input_field/emoji_panel.dart` | Compact emoji grid |
| `lib/ui/chats/chat/voce_chat_page.dart` | Refresh action in app bar |
| `lib/services/e2e_crypto.dart` | `decryptFileBytes` + return MK on file decrypt |
| `lib/services/voce_chat_service.dart` | Keep file type + store `e2e_file_*` props |
| `lib/services/file_handler.dart` | Download ciphertext + decrypt |
| `lib/ui/chats/chat/voce_msg_tile/voce_file_bubble.dart` | E2E-aware open path |
| `test/e2e_file_crypto_test.dart` | Round-trip encrypt/decrypt file bytes |

---

### Task 1: E2E file decrypt crypto + persist as file

**Files:**
- Modify: `lib/services/e2e_crypto.dart`
- Modify: `lib/services/voce_chat_service.dart` (`_decryptE2eInPlace`)
- Create: `test/e2e_file_crypto_test.dart`

- [ ] **Step 1: Extend `decryptIncoming` return to include optional `fileMk`**

Change return type to:

```dart
Future<({String kind, String plaintext, Map? file, Uint8List? fileMk})?> decryptIncoming(...)
```

When `alg` unwraps `aesKey` and kind is file, also export:

```dart
fileMk: Uint8List.fromList(await aesKey.extractBytes()),
```

(Use cryptography `SecretKeyData` / extractBytes pattern already used in this file.)

Add:

```dart
static Future<Uint8List> decryptFileBytes({
  required Uint8List cipherWithTag,
  required Uint8List mk,
  required Uint8List fiv,
}) async {
  final clear = await _aes.decrypt(
    SecretBox(
      cipherWithTag.sublist(0, cipherWithTag.length - 16),
      nonce: fiv,
      mac: Mac(cipherWithTag.sublist(cipherWithTag.length - 16)),
    ),
    secretKey: SecretKey(mk),
  );
  return Uint8List.fromList(clear);
}
```

Update all `decryptIncoming` call sites for the new record field.

- [ ] **Step 2: Fix `_decryptE2eInPlace` file branch**

Replace text demotion with:

```dart
if (dec.kind == 'file' && dec.file != null) {
  final f = dec.file!;
  final path = (f['path'] ?? '') as String;
  final name = (f['name'] ?? 'file') as String;
  final mime = (f['mime'] ?? 'application/octet-stream') as String;
  final size = f['size'] ?? 0;
  detail['content'] = path;
  detail['content_type'] = typeFile;
  props['e2e'] = true;
  props['inner_content_type'] = typeFile;
  props['name'] = name;
  props['size'] = size;
  props['content_type'] = mime;
  props['e2e_file_path'] = path;
  if (f['fiv'] != null) props['e2e_file_fiv'] = f['fiv'];
  if (dec.fileMk != null) props['e2e_file_mk'] = base64Encode(dec.fileMk!);
  detail['properties'] = props;
  return;
}
```

- [ ] **Step 3: Unit test round-trip**

```dart
test('encryptFileBytes + decryptFileBytes round trip', () async {
  // ensureIdentity for a temp uid, encryptFileBytes with recipients=[self],
  // decrypt with decryptFileBytes using mk from finalize envelope file.fiv
  // and known mk from encrypt path (expose via wrapping test helper or
  // decryptIncoming on packed finalize content after mock path).
});
```

Run: `. C:\devtools\env319.ps1; flutter test test/e2e_file_crypto_test.dart`  
Expected: PASS

- [ ] **Step 4: Wire FileHandler / VoceFileBubble**

When props contain `e2e_file_path` + `e2e_file_mk` + `e2e_file_fiv`:
1. Download ciphertext via existing resource download for `e2e_file_path`
2. `decryptFileBytes`
3. Write plaintext under app temp/cache with original `name`
4. Open via existing file page

On failure: show error SnackBar / keep bubble tappable for retry.

- [ ] **Step 5: Commit**

```bash
git add lib/services/e2e_crypto.dart lib/services/voce_chat_service.dart lib/services/file_handler.dart lib/ui/chats/chat/voce_msg_tile/voce_file_bubble.dart test/e2e_file_crypto_test.dart
git commit -m "feat: decrypt E2E file attachments on receive/open"
```

---

### Task 2: Enter-to-send + emoji panel

**Files:**
- Modify: `lib/ui/chats/chat/input_field/chat_textfield.dart`
- Create: `lib/ui/chats/chat/input_field/emoji_panel.dart`

- [ ] **Step 1: Keyboard shortcuts**

Wrap the `AppMentions` input with:

```dart
CallbackShortcuts(
  bindings: {
    const SingleActivator(LogicalKeyboardKey.enter): () {
      if (!HardwareKeyboard.instance.isShiftPressed) _sendTxt();
    },
    const SingleActivator(LogicalKeyboardKey.enter, shift: true): () {
      // allow default newline — do not call _sendTxt
    },
  },
  child: ...,
)
```

Prefer intercepting Enter without Shift via `Focus` `onKeyEvent` if `CallbackShortcuts` still inserts newline:

```dart
onKeyEvent: (node, event) {
  if (event is KeyDownEvent &&
      event.logicalKey == LogicalKeyboardKey.enter &&
      !HardwareKeyboard.instance.isShiftPressed) {
    _sendTxt();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}
```

- [ ] **Step 2: Emoji panel widget**

`emoji_panel.dart`: Grid of ~40 common emoji; `onSelected(String emoji)`.

In `ChatTextField` leading row, add smile button → `showModalBottomSheet` / overlay inserting into `mentionsKey.controller` at selection.

- [ ] **Step 3: Manual check on Windows** — Enter sends; Shift+Enter newlines; emoji inserts.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: desktop Enter-to-send and compose emoji panel"
```

---

### Task 3: Refresh affordance

**Files:**
- Modify: `lib/ui/chats/chat/voce_chat_page.dart` (app bar actions)
- Optionally notify mid-list via callback/`eventBus`

- [ ] **Step 1: Add refresh IconButton**

On press:

```dart
try {
  await SharedFuncs.renewAuthToken(); // if exists; else skip
  await App.app.chatService.initPersistentConnection();
  // Fire event or call registered list refresher so prepareChats runs
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Refreshed')),
  );
} catch (e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Refresh failed')),
  );
}
```

Must not `Navigator.pop` the chat.

- [ ] **Step 2: Commit**

```bash
git commit -m "feat: add chat refresh reconnect action"
```

---

### Task 4: Desktop shell skeleton + server rail

**Files:**
- Create: `lib/ui/chats/chats/desktop/desktop_shell.dart`
- Create: `lib/ui/chats/chats/desktop/desktop_server_rail.dart`
- Modify: `lib/ui/chats/chats/chats_main_page.dart`

- [ ] **Step 1: `DesktopServerRail`**

Narrow column (~56px):
- Current account avatar → opens modal/drawer content reused from `ChatsDrawer` account list / `App.changeUser`
- `+` → `Navigator.push(ServerPage(showClose: true))` if `!SharedFuncs.hasPreSetServerUrl()`
- Settings → push or swap to `SettingPage`

- [ ] **Step 2: `DesktopShell` Row**

`ServerRail | MidNav (width ~280) | Expanded(chatOrEmpty)`

- [ ] **Step 3: Branch in `ChatsMainPage.build`**

```dart
if (Platform.isWindows) {
  return DesktopShell(disableGesture: disableGesture);
}
// existing CupertinoTabScaffold
```

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: Windows desktop shell with server rail"
```

---

### Task 5: Mid nav — Channels / People / Saved / Files

**Files:**
- Create: `lib/ui/chats/chats/desktop/desktop_mid_nav.dart`
- Create: `lib/ui/chats/chats/desktop/desktop_files_page.dart`
- Reuse: chat tile data patterns from `chats_page.dart`, `saved_page.dart`, `contacts_page.dart`

- [ ] **Step 1: Section switcher** tabs or vertical headers: Channels, People, Saved, Files

- [ ] **Step 2: Channels + People**

Build lists from same DAOs as `prepareChannels` / `prepareDms` / contacts. Selecting a tile sets `DesktopShell` selected controller and shows `VoceChatPage` in the right pane **without** `Navigator.push` (embed). Provide a mid-pane `+` / menu for new channel & new DM (not server +).

- [ ] **Step 3: Saved**

Embed or navigate-in-pane to existing `SavedPage` / `SavedApi` list (global).

- [ ] **Step 4: Files**

Query local `ChatMsgDao` (or equivalent) for file-type messages; list name/size/chat; tap opens download (E2E-aware) or parent chat.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: desktop mid-nav Channels People Saved Files"
```

---

### Task 6: Build & verify

- [ ] **Step 1:** Bump `pubspec.yaml` version (e.g. `0.2.124+94`)

- [ ] **Step 2:** `flutter build windows --release`

- [ ] **Step 3:** `flutter build apk --release` (Android keeps tabs; shared input/E2E)

- [ ] **Step 4:** Smoke checklist from spec §6

- [ ] **Step 5: Commit version bump**

```bash
git commit -m "chore: bump client for desktop shell release"
```

---

## Execution notes

- Prefer implementing Task 1 → 2 → 3 → 4 → 5 → 6 in order (crypto independent of shell).
- Do not redesign Android navigation.
- Do not commit `deploy/minewire/runtime` secrets (other repo).
- If `ChatPageController` assumes route pop for draft save, adapt dispose/draft save for embedded mode.
