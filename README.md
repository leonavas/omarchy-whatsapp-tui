# WhatsApp TUI for the Omarchy bar

A bar widget for [Omarchy](https://omarchy.org) that puts WhatsApp in your bar
the way a tray icon would, through
[whatsapp-tui](https://github.com/leonavas/whatsapp-tui), a WhatsApp client
for the terminal.

> Unofficial. This project is not affiliated with, endorsed by or connected
> to WhatsApp or Meta. "WhatsApp" and its logo are trademarks of their
> owners, used here only to say what the widget is for.

## What it does

- **Icon.** The WhatsApp mark in the bar, white and tinted like the bar's
  glyphs by default (Outline, the green Color mark or any Nerd Font glyph are
  settings). It is dimmed while whatsapp-tui is not running.
- **Badges.** Red at the bottom-right counts unread direct chats,
  blue at the top-right unread groups, as WhatsApp counts them. Muted chats count in
  neither; they only show in the preview's footer. A badge with nothing to
  count is not drawn.
- **Combined mode.** "Group notifications" in the menu folds both into one
  badge with their sum: red while a direct chat waits, blue when only groups do.
- **Hover preview.** Hover the icon to see the unread chats: who, their newest
  unread messages ("Ana: are we still on for lunch?") with WhatsApp's bold,
  italic and strikethrough, the unread count and how long ago. Click a chat to
  jump straight to it in whatsapp-tui.
- **Desktop notifications.** One per new message, with the contact's picture
  when whatsapp-tui has it. Not for muted chats, not while notifications are
  paused, and not for the chat you have open on screen. A click opens the chat
  at that message.
- **Scratchpad parking.** whatsapp-tui lives in Omarchy's scratchpad
  (SUPER+S). A click shows it, another click puts it away without closing it,
  so it keeps running and counting.
- **Menu (right click).** Launch on Login, Launch in Foreground, Open in
  Scratchpad, Group notifications, Desktop notifications, pause notifications
  (30 minutes, 1 hour, 2 hours, until tomorrow, or until a day and time you
  pick) or resume them, and Quit WhatsApp.
- **Pause notifications** uses whatsapp-tui's own pause, so it works with
  whatsapp-tui closed and survives restarts. While it is on, the badges give
  way to a small bell-off mark.
- **Not installed?** Without whatsapp-tui on your `PATH`, the icon dims and
  its card links to
  [github.com/leonavas/whatsapp-tui](https://github.com/leonavas/whatsapp-tui),
  where to get it. The widget picks it up on its own once installed.

| Mouse | Action |
|---|---|
| Left click | Open whatsapp-tui, show it, or put it away |
| Middle click | Quit whatsapp-tui |
| Right click | The menu |
| Hover | Preview of unread chats |

## Requirements

- Omarchy, with its shell (the Quickshell bar).
- whatsapp-tui installed and on your `PATH`, with your phone linked: see
  [github.com/leonavas/whatsapp-tui](https://github.com/leonavas/whatsapp-tui).

## Install

```bash
omarchy plugin add https://github.com/leonavas/omarchy-whatsapp-tui.git
omarchy plugin enable leonavas.whatsapp-tui --section right
```

To update later: `omarchy plugin update leonavas.whatsapp-tui`, then
`omarchy restart shell`.

It does not touch the older WhatsApp Web widget (`leonavas.whatsapp`): both
can be installed, with their own settings.

## Remove

```bash
omarchy plugin remove leonavas.whatsapp-tui
```

It unloads the widget from the bar and deletes the plugin folder. The plugin
writes nothing outside its entry in `~/.config/omarchy/shell.json`.
whatsapp-tui itself stays installed, with its session in
`~/.local/share/whatsapp-tui/`.

## Settings

Change them in the bar's widget settings panel, or inline on the widget's entry
in `~/.config/omarchy/shell.json`, e.g.
`{ "id": "leonavas.whatsapp-tui", "badgeLayout": "Combined" }`.

| Key | Default | What it does |
|---|---|---|
| `launchCommand` | `""` | Empty runs `omarchy-launch-tui --app-id=<windowClass> whatsapp-tui`. Anything else must open a window with class `windowClass` |
| `windowClass` | `org.omarchy.whatsapp-tui` | The whatsapp-tui window the widget drives |
| `iconStyle` | `Mono` | `Mono` (white mark tinted like the bar's glyphs), `Outline` (white with a faint dark edge), `Color` (green mark) or `Glyph` |
| `glyph` | `󰖣` | Nerd Font character for the `Glyph` style |
| `glyphSize` | `0` | Glyph size in px; 0 follows the bar |
| `glyphOffsetY` | `-0.5` | Vertical nudge for the glyph, in px |
| `badge` | `Count` | `Count`, `Dot` or `None` |
| `badgeLayout` | `Split` | `Split` (red direct chats + blue groups) or `Combined` (one badge) |
| `directColor` | `#b65f4e` | Direct chat badge color |
| `groupColor` | `#467996` | Group badge color |
| `badgeScale` | `0.45` | Dot size, as a fraction of the icon |
| `tintWhenUnread` | `false` | Color the mark too (`Mono` and `Glyph` styles) |
| `hideMode` | `Special workspace` | What a click on the open window does: park it, or `Never hide` |
| `specialWorkspace` | `scratchpad` | The special workspace whatsapp-tui parks in |
| `openInSpecial` | `true` | whatsapp-tui opens straight into that workspace |
| `autoStart` | `false` | Open whatsapp-tui when the shell starts (Launch on Login) |
| `launchForeground` | `true` | Show and focus whatsapp-tui when it opens; off, it opens hidden |
| `dimWhenClosed` | `true` | Dim the icon while whatsapp-tui is not running |
| `hideWhenNotRunning` | `false` | Remove the icon while whatsapp-tui is not running |
| `middleClickCloses` | `true` | Middle click quits whatsapp-tui |
| `hoverPreview` | `true` | Show the preview on hover |
| `previewRows` | `6` | Chats in the preview |
| `previewMessages` | `3` | Newest unread messages shown per chat (up to 5) |
| `notifications` | `true` | Desktop notifications for new messages |
| `notificationText` | `true` | Show the message in the notification; off, only who wrote |
| `mutedIndicator` | `Bell` | While paused: `Bell`, `Dim` or `None` |

## How it works

whatsapp-tui publishes what it knows to
`$XDG_RUNTIME_DIR/whatsapp-tui/state.json`, rewriting it atomically whenever
something changes: the unread chats with their newest messages, which are
muted, and the pause. The widget watches that file. It is ignored whenever no
whatsapp-tui window is open, so a crash never leaves a stale badge behind.

Notifications come from `whatsapp-tui events`, a stream of JSON lines: each
`message.new` whatsapp-tui marks `notify: true` becomes one.

Actions go back through whatsapp-tui's command line:

- `whatsapp-tui open <chat> [message-id]`: jump to a chat
- `whatsapp-tui quit`: close whatsapp-tui
- `whatsapp-tui pause <minutes | tomorrow>`, `whatsapp-tui resume`,
  `whatsapp-tui status --json`

The format is documented in whatsapp-tui's
[docs/events.md](https://github.com/leonavas/whatsapp-tui/blob/master/docs/events.md).
[`NOTES.md`](NOTES.md) has the design decisions that are not obvious from the
code.

## Troubleshooting

- **Changes to the plugin do not show up.** After updating or editing the
  plugin, run `omarchy restart shell`. The shell's own reload keeps running
  the old code.
- **Two icons.** whatsapp-tui may have a tray icon of its own; turn one of
  them off.
- **Notifications twice.** A `message.new` hook in
  `~/.config/whatsapp-tui/hooks/` that also calls `notify-send` doubles them:
  remove it, or turn "Desktop notifications" off in the widget's menu.
- **No badges or preview.** Check that whatsapp-tui is running and that
  `$XDG_RUNTIME_DIR/whatsapp-tui/state.json` exists. The widget only trusts it
  while a window of class `org.omarchy.whatsapp-tui` is open, so a
  whatsapp-tui started some other way needs `windowClass` set to its class.

## License

MIT, see [`LICENSE`](LICENSE).
