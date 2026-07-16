# Message Notifications + Desktop Shell UX — Design Spec

Date: 2026-07-14  
Repo: `vocechat-client-uu`  
Status: Approved

## Goals

1. System message notifications on **Windows + Android**.
2. Fix Windows desktop shell UX: settings stuck, server header, vertical section rail, conversation list (newest on top), clearer rows, add friend/channel actions.

## Notifications

- Trigger: SSE `fireMsg` / inbound normal messages when `afterReady`, not from self, chat not focused, not muted.
- Windows: local OS toast via plugin (`local_notifier` or equivalent).
- Android: foreground local notification (`flutter_local_notifications`); background remains FCM.
- Tap: navigate/open corresponding DM or channel when possible.
- Respect existing mute group/user settings.

## Desktop shell layout

```
[ServerRail 56] [SectionRail ~72 vertical: Channels/People/Saved/Files] [Conversation list ~280] [Chat | Settings | empty]
```

- Top of mid area or above list: server name + icon.
- Opening Channels/People/Saved/Files clears settings mode.
- Conversation list sorted by latest message time descending.
- Row dividers / alternating contrast for readability.
- Buttons: Add Channel, Add Friend (New DM).

## Settings stuck fix

- Selecting a section or conversation sets `_showSettings = false`.
- Settings rail button toggles settings; selecting chat content leaves settings.
