.pragma library

// Pure helpers for the whatsapp-tui widget. The Hyprland readers only touch
// properties off the toplevel objects, which keeps QML binding capture
// working: the widget re-evaluates whenever a workspace or the window list
// moves. The state helpers take the parsed state.json and never throw on a
// field that is missing or of the wrong type.

// ------------------------------------------------------------------ windows

function classOf(toplevel) {
  if (!toplevel) return ""
  var wayland = toplevel.wayland
  if (wayland && wayland.appId) return String(wayland.appId)
  var ipc = toplevel.lastIpcObject
  if (ipc) {
    if (ipc["class"]) return String(ipc["class"])
    if (ipc["initialClass"]) return String(ipc["initialClass"])
  }
  return ""
}

function isActive(toplevel) {
  if (!toplevel) return false
  var wayland = toplevel.wayland
  return toplevel.activated === true || !!(wayland && wayland.activated)
}

// Exact, case-insensitive class match. whatsapp-tui's window carries a class
// of its own, so a substring match would only buy false hits on the
// terminals around it, or on the old WhatsApp Web window ("whatsapp").
function findWindow(toplevels, windowClass) {
  var wanted = String(windowClass || "").toLowerCase()
  if (wanted.length === 0) return null
  var list = toplevels || []
  var found = null
  for (var i = 0; i < list.length; i++) {
    var toplevel = list[i]
    if (classOf(toplevel).toLowerCase() !== wanted) continue
    if (isActive(toplevel)) return toplevel
    if (!found) found = toplevel
  }
  return found
}

function workspaceName(toplevel) {
  if (!toplevel) return ""
  var workspace = toplevel.workspace
  if (workspace && workspace.name) return String(workspace.name)
  var ipc = toplevel.lastIpcObject
  if (ipc && ipc["workspace"] && ipc["workspace"]["name"]) return String(ipc["workspace"]["name"])
  return ""
}

function isParked(toplevel, specialName) {
  var name = String(specialName || "")
  if (name.length === 0) return false
  return workspaceName(toplevel) === "special:" + name
}

function specialShown(hyprland, specialName) {
  if (!hyprland || !hyprland.focusedMonitor) return false
  var ipc = hyprland.focusedMonitor.lastIpcObject
  var special = ipc ? ipc["specialWorkspace"] : null
  return !!special && String(special.name || "") === "special:" + String(specialName || "")
}

function activeWorkspaceName(hyprland) {
  if (!hyprland) return ""
  var workspace = hyprland.focusedWorkspace
  return workspace && workspace.name ? String(workspace.name) : ""
}

// -------------------------------------------------------------------- state

function countOf(value) {
  var count = Number(value)
  return isFinite(count) && count > 0 ? Math.floor(count) : 0
}

// Absent, malformed or from a schema this widget does not know is "no state":
// the widget then behaves as if whatsapp-tui published nothing.
function parseState(text) {
  var value = String(text || "").trim()
  if (value.length === 0) return null
  var data
  try {
    data = JSON.parse(value)
  } catch (e) {
    return null
  }
  if (!data || typeof data !== "object") return null
  if (Number(data.v) !== 1) return null
  if (!Array.isArray(data.conversations)) data.conversations = []
  return data
}

function attention(state) {
  return state ? countOf(state.attention) : 0
}

function kindOf(value) {
  return String(value || "") === "group" ? "group" : "dm"
}

// Nerd Font glyphs: account, account-multiple.
function kindGlyph(kind) {
  return kind === "group" ? "󰀎" : "󰀄"
}

// A muted chat counts nowhere: no badge, no row, no notification. It only
// shows in the card's footer. `quiet` is the same flag under the name the
// other widgets know.
function isMuted(conv) {
  return !!conv && (conv.muted === true || conv.quiet === true)
}

// Unread messages in one listed chat: `unread`, at least one, since
// `conversations` only lists chats with something unread.
function unreadOf(conv) {
  if (!conv || typeof conv !== "object") return 0
  return Math.max(1, countOf(conv.unread))
}

// Unread messages per kind, muted chats left out (whatsapp-tui's own
// `totals.direct_messages` and `group_messages` count them in, `attention`
// does not; the badges follow `attention`). `mutedChats` counts the muted
// unread chats, for the card's footer.
function totals(state) {
  var result = { direct: 0, group: 0, mutedChats: 0 }
  if (!state) return result
  var list = state.conversations
  for (var i = 0; i < list.length; i++) {
    var conv = list[i]
    if (!conv || typeof conv !== "object" || !conv.id) continue
    if (isMuted(conv)) { result.mutedChats += 1; continue }
    if (kindOf(conv.kind) === "group") result.group += unreadOf(conv)
    else result.direct += unreadOf(conv)
  }
  return result
}

// The pause you set (`whatsapp-tui pause`), still in the future. `until`
// null is a pause without an end. Takes the snapshot or `status --json`.
function paused(state, nowSec) {
  var p = state && typeof state === "object" ? state.paused : null
  if (!p || typeof p !== "object" || p.paused !== true) return false
  var until = Number(p.until)
  return !(isFinite(until) && until > 0 && until <= nowSec)
}

function pausedUntil(state) {
  var p = state && typeof state === "object" ? state.paused : null
  var until = p && typeof p === "object" && p.paused === true ? Number(p.until) : 0
  return isFinite(until) && until > 0 ? until : 0
}

// `whatsapp-tui status --json` read leniently: only `paused` matters.
function statusPaused(text, nowSec) {
  try {
    return paused(JSON.parse(String(text || "")), nowSec)
  } catch (e) {
    return false
  }
}

function pad(n) {
  return n < 10 ? "0" + n : String(n)
}

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Calendar days from now's day to when's day; DST days are 23 or 25 hours
// long, so the difference is rounded rather than floored.
function dayOffset(when, now) {
  var a = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  var b = new Date(when.getFullYear(), when.getMonth(), when.getDate()).getTime()
  return Math.round((b - a) / 86400000)
}

// "Oct 20", with the year only when it is not this one.
function dateLabel(when, now) {
  var text = MONTHS[when.getMonth()] + " " + when.getDate()
  return when.getFullYear() !== now.getFullYear() ? text + " " + when.getFullYear() : text
}

// "14:30" today, "tomorrow 08:00", "Tue 08:00" within the coming week,
// otherwise "Oct 20, 08:00". A bare weekday further out would point at the
// wrong week.
function clockLabel(unixSec, nowSec) {
  if (!unixSec) return ""
  var when = new Date(unixSec * 1000)
  var now = new Date(nowSec * 1000)
  var hm = pad(when.getHours()) + ":" + pad(when.getMinutes())
  var days = dayOffset(when, now)
  if (days === 0) return hm
  if (days === 1) return "tomorrow " + hm
  if (days > 1 && days <= 6) return WEEKDAYS[when.getDay()] + " " + hm
  return dateLabel(when, now) + ", " + hm
}

// The day picker's label for `offset` days from now: "Today", "Tomorrow",
// then "Wed, Oct 14".
function pickerDayLabel(offset, nowSec) {
  if (offset === 0) return "Today"
  if (offset === 1) return "Tomorrow"
  var now = new Date(nowSec * 1000)
  var day = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset)
  return WEEKDAYS[day.getDay()] + ", " + dateLabel(day, now)
}

// Unix seconds of hour:minute, `offset` days from now's day. Built from the
// calendar date, so month ends and DST come out right.
function pickerTarget(offset, hour, minute, nowSec) {
  var now = new Date(nowSec * 1000)
  return new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset, hour, minute, 0).getTime() / 1000
}

// Where the picker starts: the full hour after the next one (14:20 gives
// 16:00), rolling over into tomorrow when that passes midnight.
function pickerDefault(nowSec) {
  var now = new Date(nowSec * 1000)
  var hour = now.getHours() + 2
  return { day: hour >= 24 ? 1 : 0, hour: hour % 24, minute: 0 }
}

// Whole minutes from now to the target, rounded up so the pause never ends
// before the time picked. 0 when the target is not in the future.
function minutesUntil(targetSec, nowSec) {
  var delta = targetSec - nowSec
  return delta > 0 ? Math.ceil(delta / 60) : 0
}

// Unix seconds, as a number or a numeric string.
function seconds(value) {
  var number = Number(value)
  return isFinite(number) && number > 0 ? number : 0
}

function relativeTime(ts, nowSec) {
  var then = seconds(ts)
  if (!then) return ""
  var delta = Math.max(0, nowSec - then)
  if (delta < 60) return "now"
  if (delta < 3600) return Math.floor(delta / 60) + "m"
  if (delta < 86400) return Math.floor(delta / 3600) + "h"
  return Math.floor(delta / 86400) + "d"
}

function oneLine(text) {
  return String(text || "").replace(/\s+/g, " ").trim()
}

// Text made safe to show as StyledText.
function escapeHtml(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

// A message as StyledText: whatsapp-tui's `html` (escaped, with only the
// message's own <b>, <i>, <s> and <tt>), else the plain text escaped here.
// Nothing a message says becomes markup of its own.
function messageHtml(message) {
  if (!message || typeof message !== "object") return ""
  var html = typeof message.html === "string" ? message.html : escapeHtml(message.text)
  return html.replace(/\s+/g, " ").trim()
}

// The rows the hover popup renders, already trimmed so the QML side can trust
// every field to exist. Muted chats get no row. Returns { rows, hidden } where
// hidden counts the unmuted unread chats past the row cap.
function previewRows(state, max, messagesPerChat) {
  var result = { rows: [], hidden: 0 }
  if (!state) return result
  var limit = Math.max(1, Number(max) || 6)
  var perChat = Math.max(1, Number(messagesPerChat) || 3)
  var list = state.conversations
  for (var i = 0; i < list.length; i++) {
    var conv = list[i]
    if (!conv || typeof conv !== "object" || !conv.id) continue
    if (isMuted(conv)) continue
    if (result.rows.length >= limit) { result.hidden += 1; continue }
    var kind = kindOf(conv.kind)
    var name = String(conv.name || conv.id).trim()
    var messages = Array.isArray(conv.messages) ? conv.messages : []
    // The newest few, oldest first; the author only in groups, and only
    // where it changes.
    var lines = []
    var lastAuthor = ""
    for (var m = Math.max(0, messages.length - perChat); m < messages.length; m++) {
      var msg = messages[m]
      var html = messageHtml(msg)
      if (html.length === 0) continue
      var by = String(msg.author || "").trim()
      var prefixed = kind === "group" && by.length > 0 && by !== lastAuthor
      lines.push(prefixed ? "<b>" + escapeHtml(by) + ":</b> " + html : html)
      lastAuthor = by
    }
    var last = messages.length > 0 ? messages[messages.length - 1] : null
    var lastId = last && typeof last === "object" && last.id ? String(last.id) : ""
    result.rows.push({
      id: String(conv.id),
      kind: kind,
      glyph: kindGlyph(kind),
      name: name,
      count: unreadOf(conv),
      latest: seconds(conv.latest) || (last ? seconds(last.ts) : 0),
      lines: lines,
      msgId: lastId,
    })
  }
  return result
}

// argv for `whatsapp-tui open`, at the newest unread message when known.
function openArgs(row) {
  var argv = ["whatsapp-tui", "open", String(row.id)]
  if (row.msgId) argv.push(String(row.msgId))
  return argv
}

// argv for `whatsapp-tui pause`: whole minutes, or "tomorrow" (its 9 AM).
function pauseArgs(minutes) {
  return ["whatsapp-tui", "pause", minutes === "tomorrow" ? "tomorrow" : String(Math.max(1, Math.round(minutes)))]
}

// --------------------------------------------------------------- notifications

// What a line from `whatsapp-tui events` should become as a desktop
// notification, or null. Only `message.new` with `notify: true` does:
// whatsapp-tui already says false for a muted chat, while paused, and for
// the chat open on screen. The plugin's own checks (muted, paused) back it up
// for a whatsapp-tui that leaves `notify` out.
function notification(line, state, nowSec) {
  var event
  try {
    event = JSON.parse(String(line || ""))
  } catch (e) {
    return null
  }
  if (!event || typeof event !== "object" || event.event !== "message.new") return null
  var data = event.data && typeof event.data === "object" ? event.data : {}
  if (data.notify === false || data.muted === true) return null
  if (paused(state, nowSec)) return null
  var conv = data.conversation && typeof data.conversation === "object" ? data.conversation : {}
  var message = data.message && typeof data.message === "object" ? data.message : {}
  if (!conv.id || isMuted(conv)) return null
  var kind = kindOf(conv.kind)
  var name = String(conv.name || conv.id).trim()
  var author = String(message.author || "").trim()
  var body = messageHtml(message)
  return {
    id: String(conv.id),
    msgId: message.id ? String(message.id) : "",
    kind: kind,
    // The summary is plain text; the body is markup, already escaped.
    title: kind === "group" && author.length > 0 ? author + " · " + name : name,
    body: body.length > 0 ? body : "New message",
    avatar: typeof conv.avatar === "string" && conv.avatar.length > 0 ? conv.avatar : "",
  }
}

function badgeLabel(count) {
  return count > 99 ? "99+" : String(count)
}

// A Lua string literal, for commands handed to `hyprctl eval`.
function luaString(text) {
  return '"' + String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
}
