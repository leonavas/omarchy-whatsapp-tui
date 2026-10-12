# Notes

Decisions that are not obvious from the code. The widget is the Slack widget
(`leonavas.slack`, for slick) adapted to whatsapp-tui: the window handling
(special workspace parking, the background launch, the `0x` address prefix,
the double focus, Lua vs legacy dispatch), the quit fallback, the pause picker
and the not-installed state are the same code, and that widget's NOTES explain
them. What differs is below.

## Contract

Everything comes from whatsapp-tui's `docs/events.md`: the snapshot at
`$XDG_RUNTIME_DIR/whatsapp-tui/state.json`, the `whatsapp-tui events` stream,
and the commands (`open <jid> [message-id]`, `quit`, `pause`, `resume`,
`status --json`). A snapshot with a `v` other than 1 reads as no snapshot.

## The state file is trusted only while the window exists

Same rule as the Slack widget: whatsapp-tui writes `running: false` when it
quits, a crash writes nothing, so the file is ignored whenever no window of
`windowClass` exists.

## Badges

Two numbers, summed from `conversations` with muted chats left out: unread
messages in direct chats (red, bottom-right) and in groups (blue, top-right).
whatsapp-tui's own `totals.direct_messages` and `group_messages` include muted
chats, the way WhatsApp counts them; the badges follow `attention` instead,
which leaves them out, so a muted group never lights the bar. Archived chats
are in neither (whatsapp-tui does not list them).

"Combined" folds both into one badge, red while any direct chat waits and blue
when only groups do: the badge shows the most urgent thing waiting, as the
WhatsApp Web widget (`leonavas.whatsapp`) did.

The colors are slick's red and blue, so the two chat widgets read the same
way side by side.

## Muted chats and the pause

A muted chat gets no row, no badge and no notification, only the footer line
("+1 muted chat unread"). The pause is whatsapp-tui's own (WhatsApp has no
do-not-disturb): it hides both badges behind the bell-off, as a Slack pause
does, and whatsapp-tui keeps it in its data dir, so the menu's pause entries
work with whatsapp-tui closed. With no live snapshot, the menu asks
`whatsapp-tui status --json` whether to offer Resume. "Until tomorrow" passes
`tomorrow` and lets whatsapp-tui pick the hour (9 AM).

## Notifications

whatsapp-tui sends none itself, so the widget does. Only the primary instance
(the first bar, on a multi-monitor setup) runs `whatsapp-tui events`, while a
whatsapp-tui window exists and "Desktop notifications" is on; a timer restarts
the stream if it drops.

Every `message.new` with `notify: true` becomes a `notify-send`. whatsapp-tui
already sets `notify: false` for muted chats, during a pause and for the chat
open in its focused window; the widget checks muted and paused again, for a
whatsapp-tui that leaves the field out. A message id seen in the last 200 is
not notified again, so a reconnect cannot double one.

The body is the message's `html`: whatsapp-tui escapes it, so nothing a
message says becomes markup, and its bold and italic survive. The icon is the
chat's `avatar` when it has one, else the green mark from `assets/`.

The click runs `whatsapp-tui open <jid> <message-id>` through Omarchy's
`omarchy-exec-argv` hint, which the notification center keeps across shell
restarts, unlike a libnotify action, which needs the sender alive.
`whatsapp-tui open` brings the window up itself.

## The preview

Plain `Text` with `StyledText` per message, up to two lines each, the newest
`previewMessages` of the five whatsapp-tui publishes. In a group the author
leads the line where it changes; in a direct chat the name is the chat's.

## Icons

`assets/` holds whatsapp-tui's own marks: `whatsapp-tui-white.svg` (Mono,
tinted through `MultiEffect` like the Slack widget's), `whatsapp-tui.svg`
(Color, also the card header and the notifications) and
`whatsapp-tui-outline.svg` (the white mark over a 60% black copy stroked
wider, as slick's outline). Copy them again from whatsapp-tui's `assets/` when
they change there rather than editing them here.

## No conflict with the WhatsApp Web widget

`leonavas.whatsapp` watches any class containing "whatsapp" as a substring,
which would include `org.omarchy.whatsapp-tui`. With both widgets on the bar,
set that one's `windowClass` to the web app's own class
(`chrome-web.whatsapp.com__-Default`). This widget matches its class exactly
and never sees the web app. Ids, settings and the window rule name
(`whatsapp-tui-launching`) are all distinct.

## Hot reload

Editing the QML while the widget is on the bar logs "Local plugin changed,
reloading" but keeps running the old component. `omarchy restart shell` picks
up the change.
