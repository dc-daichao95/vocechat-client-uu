# Badge + E2EE v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Fix Windows taskbar overlay badge reliability, then migrate VoceChat to E2EE v2 via shared Rust crypto core.

**Architecture:** Phase A client-only badge fixes; Phases B–D new `voce-e2ee-core` crate with WASM/FFI adapters.

**Tech Stack:** Flutter 3.19, React 19, Rust 2021, `windows_taskbar`, WASM, FFI.

## Global Constraints

- New encrypted messages use `e2e_ver=2` only after Phase D cutover.
- v1 messages remain decryptable read-only.
- Identity key change blocks send until safety number approved.
- Private keys never uploaded to server.

---

### Task 1: Taskbar badge reliability (Phase A)

**Files:**
- Modify: `lib/services/taskbar_badge_service.dart`
- Modify: `lib/main.dart` (resumed → `refresh()`)
- Modify: `lib/models/ui_models/chat_page_controller.dart`
- Modify: `lib/ui/chats/chats/desktop/desktop_mid_nav.dart`
- Test: `test/taskbar_badge_service_test.dart`

**Interfaces:**
- `TaskbarBadgeService.refresh()` — force re-apply overlay from `globals.unreadCountSum`

- [ ] Add `refresh()`, return `bool` from `_applyWindows`, only set `_lastApplied` on success
- [ ] Call `refresh()` on `AppLifecycleState.resumed`
- [ ] Gate `updateReadIndex` on `appInForeground` + focused chat
- [ ] Remove `globals.unreadCountSum` write from `DesktopMidNav`; use `UnreadCountService.requestRecompute()`
- [ ] Bump version; `flutter build windows --release`

---

### Task 2: voce-e2ee-core spike (Phase B) — **DONE 2026-07-16**

**Files:**
- Create: `vocechat-server-rust-uu/crates/voce-e2ee-core/`

- [x] Cargo workspace member + core modules (identity/X3DH/DR/SK/v1_compat/FFI)
- [x] Dependency/license audit document in crate README
- [x] WASM build (`scripts/build-wasm.ps1`) + Flutter FFI smoke (`scripts/ffi-smoke.ps1`)
- [x] X3DH agreement vector test (`tests/x3dh_vector.rs`) + unit roundtrips

---

### Task 3–6: DM v2, channels, migration, docs (Phases C–D)

See design spec `docs/superpowers/specs/2026-07-16-badge-and-e2ee-v2-design.md`.
