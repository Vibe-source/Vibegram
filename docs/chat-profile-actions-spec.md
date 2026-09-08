# Chat profile: action control, More menu, per-chat wallpaper, auto-delete

Spec captured from the product owner, 2026-09-01. Not built yet — the clear/delete
semantics below ARE built and deployed; everything under "Not built" is the backlog.

## Built and deployed (2026-09-01)

**Clear ≠ Delete.** They were the same server call.

| Action | Server | Effect |
|---|---|---|
| Clear messages | `POST /api/chats/:chat_id/clear` | moves the caller's `messages_cleared_at` only |
| Delete chat | `DELETE /api/chats/:chat_id` | sets `deleted: true` on the participant |

Clearing keeps membership, the row on Home, and the MLS session. `Vibe.Chat.clear_messages/2`
is the only writer of the watermark that does not also delete; tests in
`test/vibe/chat_clear_messages_test.exs` hold that line.

The "Joined" pill is now read from a live session (`isPeerConfirmed`), never from the
persisted latch alone — a cleared or reinstalled chat used to claim a key it did not have.

## Built (2026-09-01, second pass) — the action control

A DM's action row is five chips: call · video · search · mute · **more**. Groups keep
mute · search · more. More opens `ChatProfileMoreMenuOverlay` — the chat context menu's
own `ContextMenuView` card, rows and glass, anchored to the chip, never a SwiftUI `Menu`.
`ContextMenuView` gained an `onAction` closure so a non-message host does not have to
pretend to be a `ChatContextMenuOverlayDelegate`.

Menu contents today: Change Wallpaper, Clear Messages, and Block User (DM) or Report +
Leave/Delete (group). The DM danger section is gone — those actions live here now.

Change Wallpaper pushes the profile's `.appearance` page, which already hosts
`ChatWallpaperPickerView`. That destination existed but nothing pushed it, so this is its
first entry point. The host reaches the SwiftUI NavigationStack through
`onNavigatorReady`, installed on appear.

## Not built — the rest of the action control

- **Auto-delete** — a timer in the More menu (off / 1 day / 2 days / …). Selecting it has
  to reach the server, the engine and the core, not just the chat view. New column on the
  participant or room, a server-side sweep, and a client that hides expired rows.
- **A dynamic identity row** — a first-contact chat shows **Block user**; once the peer is
  a contact or there is history, the row shows the username and the encryption key.

## Not built — per-chat wallpaper

Wallpaper today is global; the target is per `chat_id`. The picker page above is the
entry point, but it still writes one appearance for every chat.

1. From the profile, open the chat view.
2. A sheet rises from the bottom carrying wallpaper/appearance previews.
3. Selecting a preview applies live to the chat's wallpaper *and* colour palette behind
   the sheet — the preview is the real thing, not a thumbnail.
4. **Apply** commits it for that `chat_id`; the list shows that it updated.
