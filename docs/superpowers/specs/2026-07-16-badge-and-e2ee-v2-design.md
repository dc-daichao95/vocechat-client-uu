# Windows Badge Reliability + E2EE v2 — Design Spec

Date: 2026-07-16  
Repos: `vocechat-client-uu`, `vocechat-web-uu`, `vocechat-server-rust-uu`  
Status: **Approved**

## 1. Goals

1. **Taskbar overlay badge** on Windows stays in sync with unread count: shows after every new message, clears on read, survives minimize/restore.
2. **E2EE v2** replaces v1 for all new encrypted traffic: identity authentication, X3DH, Double Ratchet (DM), Sender Keys (channels), replay protection, metadata encryption for files.
3. **Migration**: new messages **write v2 only**; **v1 decrypt read-only**; **old clients blocked** from sending in encrypted sessions.

## 2. Locked decisions

| Topic | Decision |
|-------|----------|
| E2EE scope | Full v2 (not v1 hardening only) |
| Crypto implementation | Shared **Rust** crate `voce-e2ee-core`; Web via **WASM**, Flutter via **FFI** |
| v1 migration | Read v1 / write v2; old clients cannot send encrypted messages |
| Identity key change | **Block send** until user verifies safety number |
| New device recovery | **Device link** (QR from logged-in device) + optional **passphrase-encrypted cloud backup** |
| Badge vs notify | Overlay badge and flash/toast remain **independent** paths |

## 3. Phase A — Taskbar badge (client only)

### Root causes (code-proven)

- `WindowsTaskbar.setOverlayIcon` fails while window hidden; `_lastApplied` still updates → no retry on restore.
- `ChatPageController.onMessage` calls `updateReadIndex` even when `appInForeground == false` → unread cleared while minimized.
- `DesktopMidNav._updateUnreadTotals` and `UnreadCountService` both write `globals.unreadCountSum` → race / missed listener fires.

### Fixes

1. `TaskbarBadgeService.refresh()` — bypass `_lastApplied`, re-apply current count after `resumed`.
2. `_applyWindows` returns success/failure; `_lastApplied` only on success.
3. `onMessage` → `updateReadIndex` only when `appInForeground` and focused chat matches.
4. `DesktopMidNav` stops writing `globals.unreadCountSum`; sole writer is `UnreadCountService`.

## 4. Phase B — `voce-e2ee-core` (new crate under server repo)

```
vocechat-server-rust-uu/crates/voce-e2ee-core/
  src/lib.rs          # C ABI + JSON IPC surface for WASM/FFI
  src/identity.rs     # Ed25519 sign + Curve25519 DH identity
  src/x3dh.rs
  src/ratchet.rs      # Double Ratchet (DM)
  src/sender_keys.rs  # Channel SK + rotation
  src/envelope.rs     # v2 wire format, replay window
  src/v1_compat.rs    # Read-only v1 MK+AES-GCM decrypt
```

- **Do not** invent custom crypto; use audited crates (e.g. `x25519-dalek`, `ed25519-dalek`, `aes-gcm`, Signal-style ratchet via `double-ratchet` or `libsignal`-compatible subset).
- Spike gate: WASM build + Flutter FFI link + official test vectors **before** UI integration.

### v2 envelope

- `content_type`: `vocechat/e2e`
- `properties.e2e_ver`: `2`
- `content`: opaque base64(JSON) with `alg`, `sender_device_id`, ratchet header / SK id, ciphertext, optional encrypted file meta.

## 5. Phase C — Server API extensions

Extend existing `api/e2e.rs`:

| Endpoint | Purpose |
|----------|---------|
| `PUT /identity` | Require valid `signed_prekey` + signature over identity key |
| `GET /identity/:uid` | List devices + fingerprint material |
| `PUT /prekeys` | Already exists; wire clients to upload OTP batches |
| `GET /bundle/:uid` | X3DH session start |
| `POST /device-link/start` | Short-lived pairing token |
| `POST /device-link/complete` | New device receives encrypted identity blob |
| `PUT /backup` | Passphrase-encrypted blob (existing) |
| `GET /dm/:peer` / group `e2e_enabled` | Unchanged semantics; enforce v2 send when `min_client_e2e_ver >= 2` |

Server **never** holds private keys. Webhook/FCM remain opaque for E2E (`e2e_opaque`).

## 6. Phase D — Client integration

### Web (`vocechat-web-uu`)

- Replace `src/app/e2e/crypto.ts` v1 send path with WASM bindings to `voce-e2ee-core`.
- Keep v1 decrypt in WASM `v1_compat` for history.
- `useE2eBootstrap`: publish signed identity + prekeys.
- Safety number UI: block send on key change until approved.
- Device link page + backup restore settings.

### Flutter (`vocechat-client-uu`)

- Replace `lib/services/e2e_crypto.dart` send/decrypt with FFI.
- Windows: **OS secure storage** for private keys (no plaintext JSON).
- `voce_send_service.dart`: route through FFI; fail closed on v2 required.
- Bump `min_supported_e2e_ver` in login response handling; show upgrade dialog if server rejects.

## 7. Security properties (v2 target)

| Property | v1 today | v2 target |
|----------|----------|-----------|
| Server read DB | ciphertext | ciphertext |
| PFS (DM) | no | yes (Double Ratchet) |
| Sender auth | no | yes (signed prekey chain) |
| MITM (bad server) | vulnerable | safety number + block |
| Replay | no | sliding window + message keys |
| Group PCS | no | Sender Key rotation on membership change |
| File name privacy | no | encrypted in envelope |

## 8. Testing

### Phase A

- Unit: `TaskbarBadgeService` success/failure updates `_lastApplied`.
- Manual: minimize → receive 3 msgs → flash yes, badge on restore → open chat → badge clears.

### Phase B–D

- Rust: official X3DH/ratchet test vectors.
- Integration: Web ↔ Server ↔ Flutter roundtrip DM + channel + file.
- Migration: v1 history readable; v2-only send; old client gets `E2E_UPGRADE_REQUIRED`.

## 9. Delivery order

1. **Phase A** — badge (this sprint, shippable alone).
2. **Spike** — `voce-e2ee-core` WASM/FFI + vectors.
3. **DM v2** — Web + Flutter + server enforcement.
4. **Channel SK + files** — rotation + encrypted metadata.
5. **Device link + backup + safety UI** — multi-device.
6. **Docs** — update `SECURITY_E2E_AND_OBFUSCATION.md` to match code (remove false Signal claims).

## 10. Out of scope

- Voice/Agora E2E
- REALITY / Minewire in-process crypto
- MLS (post-v2)
