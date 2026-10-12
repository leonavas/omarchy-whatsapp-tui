import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// whatsapp-tui: a tray-style button for the bar. Opens the whatsapp-tui
// terminal window, parks it in a special workspace so it keeps running out of
// sight, badges the unread chats, previews them on hover and turns new
// messages into desktop notifications. Everything whatsapp-tui knows reaches
// the widget through one JSON file it rewrites in the runtime dir, and its
// event stream.
BarWidget {
  id: root
  moduleName: "leonavas.whatsapp-tui"

  // ---------------------------------------------------------------- settings
  readonly property string launchCommand: String(setting("launchCommand", ""))
  readonly property string windowClass: String(setting("windowClass", "org.omarchy.whatsapp-tui"))
  readonly property string iconStyle: String(setting("iconStyle", "Mono"))
  readonly property string glyph: String(setting("glyph", "󰖣"))
  readonly property int glyphSize: Math.max(0, Number(setting("glyphSize", 0)))
  readonly property real glyphOffsetY: Number(setting("glyphOffsetY", -0.5))
  readonly property string badgeStyle: String(setting("badge", "Count"))
  readonly property bool combinedBadge: String(setting("badgeLayout", "Split")) === "Combined"
  readonly property string directColorSetting: String(setting("directColor", "#b65f4e"))
  readonly property string groupColorSetting: String(setting("groupColor", "#467996"))
  readonly property real badgeScale: Math.max(0.2, Math.min(0.9, Number(setting("badgeScale", 0.45))))
  readonly property bool tintWhenUnread: setting("tintWhenUnread", false) === true
  readonly property string hideMode: String(setting("hideMode", "Special workspace"))
  readonly property string specialName: String(setting("specialWorkspace", "scratchpad"))
  readonly property bool openInSpecial: setting("openInSpecial", true) !== false
  readonly property bool autoStart: setting("autoStart", false) === true
  readonly property bool launchForeground: setting("launchForeground", true) !== false
  readonly property bool dimWhenClosed: setting("dimWhenClosed", true) !== false
  readonly property bool hideWhenNotRunning: setting("hideWhenNotRunning", false) === true
  readonly property bool closeOnMiddle: setting("middleClickCloses", true) !== false
  readonly property bool hoverPreview: setting("hoverPreview", true) !== false
  readonly property int previewRows: Math.max(1, Number(setting("previewRows", 6)))
  readonly property int previewMessages: Math.max(1, Number(setting("previewMessages", 3)))
  readonly property bool desktopNotifications: setting("notifications", true) !== false
  readonly property bool notificationText: setting("notificationText", true) !== false
  readonly property string mutedIndicator: String(setting("mutedIndicator", "Bell"))

  // ------------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  // slick's red and blue, as the Slack widget paints them: direct chats in
  // one, groups in the other. An empty setting falls back to the theme's
  // urgent color.
  readonly property color directColor: root.directColorSetting.length > 0 ? root.directColorSetting : root.urgentColor
  readonly property color groupColor: root.groupColorSetting.length > 0 ? root.groupColorSetting : root.directColor
  readonly property color badgeDigitColor: "#ffffff"
  readonly property color badgeTextColor: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------------ window
  readonly property var toplevels: Hyprland.toplevels ? (Hyprland.toplevels.values || []) : []
  readonly property var window: Model.findWindow(root.toplevels, root.windowClass)
  readonly property bool running: root.window !== null && root.window !== undefined
  readonly property bool focused: Model.isActive(root.window)
  readonly property bool parked: Model.isParked(root.window, root.specialName)
  readonly property bool specialShown: Model.specialShown(Hyprland, root.specialName)

  // ------------------------------------------------------ whatsapp-tui state
  //
  // Gated on the window: whatsapp-tui writes `running: false` when it quits,
  // but a crash writes nothing, and a file left behind must not keep a badge
  // up.
  readonly property string statePath: Quickshell.env("XDG_RUNTIME_DIR") + "/whatsapp-tui/state.json"
  property var rawState: null
  readonly property var appState: root.running && root.rawState !== null
    && root.rawState.running !== false ? root.rawState : null
  readonly property bool stateLive: root.appState !== null

  // Wall clock for relative times and pause expiry, coarse on purpose.
  property real nowSec: Date.now() / 1000
  Timer {
    interval: 20000
    repeat: true
    running: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  readonly property int attention: Model.attention(root.appState)
  readonly property var totals: Model.totals(root.appState)
  readonly property bool muted: Model.paused(root.appState, root.nowSec)
  readonly property var preview: Model.previewRows(root.appState, root.previewRows, root.previewMessages)

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.rawState = Model.parseState(text())
    onLoadFailed: root.rawState = null
  }

  // The watch only helps once the file exists; until whatsapp-tui's first
  // write lands, poke the reader ourselves.
  Timer {
    interval: 3000
    repeat: true
    running: root.running && root.rawState === null
    onTriggered: stateFile.reload()
  }

  onRunningChanged: {
    stateFile.reload()
    if (!root.running) {
      quitFallbackTimer.stop()
      root.quitting = ""
      return
    }
    // A window this widget launched unseen waits for whatsapp-tui to start,
    // then goes away in one step (`stowUnseen`).
    if (root.unseenLaunch) {
      root.unseenLaunch = false
      unseenTimer.focusTarget = root.lastOtherAddress
      unseenTimer.ticks = 0
      unseenTimer.restart()
      return
    }
    // A new window goes straight to the special workspace. `settled` keeps a
    // shell restart from yanking one that is already open.
    if (root.openInSpecial && settleTimer.settled) {
      root.placeInSpecial()
      if (!root.launchForeground) {
        backgroundFixTimer.focusTarget = root.lastOtherAddress
        backgroundFixTimer.restart()
      }
    }
    if (root.launchForeground && settleTimer.settled) foregroundTimer.restart()
  }

  // Moving a just-opened window into the special workspace makes Hyprland
  // refocus, and its pick can be a window that lives in the scratchpad (or the
  // moved one itself), which opens the scratchpad on screen: "silent" does not
  // cover that. A background launch then puts things back: scratchpad hidden,
  // focus on the window you were using. Checked against hyprctl rather than
  // the cached monitor state, which lags the events by a beat.
  property string lastOtherAddress: ""
  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { root.noteActive() }
  }
  function noteActive() {
    var t = Hyprland.activeToplevel
    if (!t || !t.address) return
    if (Model.classOf(t).toLowerCase() === root.windowClass.toLowerCase()) return
    if (Model.workspaceName(t).indexOf("special:") === 0) return
    var value = String(t.address)
    if (value.indexOf("0x") !== 0) value = "0x" + value
    root.lastOtherAddress = "address:" + value
  }
  Timer {
    id: backgroundFixTimer
    property string focusTarget: ""
    interval: 200
    onTriggered: {
      var lua = Hyprland.usingLua === true
      var hide = lua ? 'hl.dsp.workspace.toggle_special("' + root.specialName + '")'
                     : "togglespecialworkspace " + root.specialName
      var focus = focusTarget.length === 0 ? ""
        : lua ? 'hl.dsp.focus({ window = "' + focusTarget + '" })' : "focuswindow " + focusTarget
      Util.execArgv(["bash", "-c",
        'shown=$(hyprctl monitors -j | jq -r \'.[] | select(.focused) | .specialWorkspace.name\'); '
        + '[ "$shown" = "special:$1" ] && hyprctl dispatch "$2" >/dev/null; '
        + '[ -n "$3" ] && hyprctl dispatch "$3" >/dev/null; exit 0',
        "whatsapp-tui-background", root.specialName, hide, focus])
    }
  }

  Timer {
    id: foregroundTimer
    interval: 400
    onTriggered: root.showWindow()
  }
  Timer {
    id: settleTimer
    property bool settled: false
    interval: 3000
    running: true
    onTriggered: settled = true
  }

  property string homeWorkspace: ""
  onWindowChanged: root.rememberHome()
  Connections {
    target: root.window
    ignoreUnknownSignals: true
    function onWorkspaceChanged() { root.rememberHome() }
  }

  function rememberHome() {
    var name = Model.workspaceName(root.window)
    if (name.length > 0 && name.indexOf("special:") !== 0) root.homeWorkspace = name
  }

  // ------------------------------------------------------------------- icons
  // Mono (default) is the white WhatsApp mark tinted like the bar's glyphs;
  // Outline is the white mark with a faint dark edge, readable on light and
  // dark bars; Color is the green mark as WhatsApp ships it; Glyph is any
  // Nerd Font character.
  readonly property url outlineIconSource: Qt.resolvedUrl("assets/whatsapp-tui-outline.svg")
  readonly property url colorIconSource: Qt.resolvedUrl("assets/whatsapp-tui.svg")
  readonly property url monoIconSource: Qt.resolvedUrl("assets/whatsapp-tui-white.svg")
  // The green mark, as a path, for the notifications without an avatar.
  readonly property string notificationIcon: {
    var url = String(root.colorIconSource)
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.slice(7)) : "whatsapp"
  }
  // Tinted: red while a direct chat waits, blue while only groups do.
  readonly property color tintColor: root.directCount > 0 ? root.directColor : root.groupColor
  readonly property color glyphColor: root.anyBadge && root.tintWhenUnread ? root.tintColor : root.foreground
  readonly property int glyphPixelSize: root.glyphSize > 0 ? root.glyphSize : Math.max(8, Style.bar.iconFont)
  // A pause you set fades the mark under the bell-off.
  readonly property real markOpacity: root.muted && root.mutedIndicator === "Bell" ? 0.45 : 1

  // Two counts, two corners. A pause hides both.
  readonly property bool badgesOn: !root.muted && root.badgeStyle !== "None" && !root.notInstalled
  readonly property int directCount: root.badgesOn ? root.totals.direct : 0
  readonly property int groupCount: root.badgesOn ? root.totals.group : 0
  readonly property bool anyBadge: root.directCount > 0 || root.groupCount > 0
  // "Combined" folds both into one badge: red while a direct chat waits, blue
  // when only groups do, as the WhatsApp Web widget painted it.
  readonly property int combinedCount: root.directCount + root.groupCount
  readonly property color combinedColor: root.directCount > 0 ? root.directColor : root.groupColor

  // Which corner each badge takes. Change these two to move them.
  readonly property string directCorner: "bottom-right"
  readonly property string groupCorner: "top-right"

  // ----------------------------------------------------------------- actions
  function dispatch(luaForm, legacyForm) {
    Hyprland.dispatch(Hyprland.usingLua === true ? luaForm : legacyForm)
  }

  function windowAddress() {
    var target = root.window
    if (!target || !target.address) return ""
    var value = String(target.address)
    if (value.indexOf("0x") !== 0) value = "0x" + value
    return "address:" + value
  }

  // omarchy-launch-tui gives the terminal the app id it is passed, which is
  // the class this widget watches. The window opens on the current workspace:
  // Ghostty only starts the command once its window is shown, so a terminal
  // born in the hidden scratchpad would never run whatsapp-tui. With Launch
  // in Foreground off it opens without taking the focus, and
  // onRunningChanged then moves it silently to the scratchpad; with it on,
  // onRunningChanged shows it there.
  function launch() {
    var cmd = root.launchCommand.length > 0 ? root.launchCommand
                                            : "omarchy-launch-tui --app-id=" + root.windowClass + " whatsapp-tui"
    var lua = {}
    if (!root.launchForeground) lua.no_initial_focus = true
    if (Hyprland.usingLua === true) {
      // Headed for the hidden scratchpad: the window shows up floating and
      // all but transparent, so nothing on screen moves or flashes.
      var unseen = root.openInSpecial && !root.launchForeground
      if (unseen) lua.tag = "+" + root.unseenRule
      root.unseenLaunch = unseen
      var rules = Object.keys(lua).map(function (k) {
        return k + " = " + (typeof lua[k] === "string" ? Model.luaString(lua[k]) : String(lua[k]))
      })
      Util.execArgv(["hyprctl", "eval", (unseen ? root.unseenRuleLua(true) + "; " : "")
        + "hl.exec_cmd(" + Model.luaString(cmd) + ", { " + rules.join(", ") + " })"])
    } else {
      var legacy = []
      if (lua.no_initial_focus) legacy.push("noinitialfocus")
      Util.execArgv(["hyprctl", "dispatch", "exec", (legacy.length > 0 ? "[" + legacy.join(";") + "] " : "") + cmd])
    }
  }

  // Launched for the hidden scratchpad (Lua configs): the window opens on the
  // current workspace floating and all but transparent. Opacity 0.01, not 0:
  // a window Hyprland does not draw gets no frames, and Ghostty only starts
  // the command after its first one. Once the title says the command runs,
  // `stowUnseen` moves it in a single Lua call. The rule is named and only on
  // around a launch; switching it off gives the window its usual opacity back.
  readonly property string unseenRule: "whatsapp-tui-launching"
  property bool unseenLaunch: false
  function unseenRuleLua(enabled) {
    return "hl.window_rule({ name = " + Model.luaString(root.unseenRule) + ", enabled = " + enabled
      + ", match = { tag = " + Model.luaString(root.unseenRule) + " }"
      + (enabled ? ", float = true, opacity = \"0.01 0.01\", no_anim = true" : "") + " })"
  }
  Timer {
    id: unseenTimer
    property string focusTarget: ""
    property int ticks: 0
    interval: 50
    repeat: true
    onTriggered: {
      ticks++
      var title = root.window ? String(root.window.title || "") : ""
      if (!root.running) { stop(); Util.execArgv(["hyprctl", "eval", root.unseenRuleLua(false)]); return }
      if ((title.length === 0 || title === "Ghostty") && ticks < 80) return
      stop()
      root.stowUnseen(focusTarget)
    }
  }
  function stowUnseen(focusTarget) {
    var address = root.windowAddress()
    var special = "special:" + root.specialName
    var lua = []
    if (address.length > 0) {
      lua.push("hl.dispatch(hl.dsp.window.move({ window = " + Model.luaString(address) + ", workspace = " + Model.luaString(special) + ", silent = true }))")
      lua.push("hl.dispatch(hl.dsp.window.float({ window = " + Model.luaString(address) + ", action = \"unset\" }))")
    }
    lua.push("local shown = hl.get_active_special_workspace()")
    lua.push("if shown and shown.name == " + Model.luaString(special) + " then hl.dispatch(hl.dsp.workspace.toggle_special(" + Model.luaString(root.specialName) + ")) end")
    if (focusTarget.length > 0) lua.push("hl.dispatch(hl.dsp.focus({ window = " + Model.luaString(focusTarget) + " }))")
    lua.push(root.unseenRuleLua(false))
    Util.execArgv(["hyprctl", "eval", lua.join("; ")])
  }

  function focusWindow() {
    var address = root.windowAddress()
    if (address.length === 0) return
    root.dispatch('hl.dsp.focus({ window = "' + address + '" })', "focuswindow " + address)
    refocusTimer.address = address
    refocusTimer.restart()
  }

  function park() {
    var address = root.windowAddress()
    if (address.length === 0) return
    if (root.parked && root.specialShown) { root.toggleSpecial(); return }
    var workspace = "special:" + root.specialName
    root.dispatch(
      'hl.dsp.window.move({ window = "' + address + '", workspace = "' + workspace + '", silent = true })',
      "movetoworkspacesilent " + workspace + "," + address)
  }

  function showWindow() {
    var address = root.windowAddress()
    if (address.length === 0) return
    if (root.openInSpecial && root.parked) {
      if (!root.specialShown) root.toggleSpecial()
      root.focusWindow()
      return
    }
    var target = root.homeWorkspace.length > 0 ? root.homeWorkspace
                                               : Model.activeWorkspaceName(Hyprland)
    if (target.length > 0) {
      root.dispatch(
        'hl.dsp.window.move({ window = "' + address + '", workspace = "' + target + '" })',
        "movetoworkspace " + target + "," + address)
    }
    root.focusWindow()
  }

  function toggleSpecial() {
    root.dispatch('hl.dsp.workspace.toggle_special("' + root.specialName + '")',
                  "togglespecialworkspace " + root.specialName)
  }

  function placeInSpecial() {
    var address = root.windowAddress()
    if (address.length === 0 || root.parked) return
    var workspace = "special:" + root.specialName
    root.dispatch(
      'hl.dsp.window.move({ window = "' + address + '", workspace = "' + workspace + '", silent = true })',
      "movetoworkspacesilent " + workspace + "," + address)
  }

  function closeWindow() {
    var address = root.windowAddress()
    if (address.length === 0) return
    root.dispatch('hl.dsp.window.close({ window = "' + address + '" })', "closewindow " + address)
  }

  // Ask whatsapp-tui to quit, so it writes its goodbye; closing the window is
  // the fallback for one that refuses or does not answer. The fallback only
  // ever closes the window it was asked to: one opened again within those
  // 4 s is a new window, and must stay.
  property string quitting: ""
  function quit() {
    if (!root.running) return
    if (root.stateLive && !quitProc.running) {
      root.quitting = root.windowAddress()
      quitProc.running = true
      quitFallbackTimer.restart()
    } else {
      root.closeWindow()
    }
  }
  function closeQuitting() {
    if (root.quitting.length > 0 && root.quitting === root.windowAddress()) root.closeWindow()
    root.quitting = ""
  }
  Process {
    id: quitProc
    command: ["bash", "-lc", "whatsapp-tui quit"]
    onExited: function (code) { if (code !== 0) root.closeQuitting() }
  }
  Timer {
    id: quitFallbackTimer
    interval: 4000
    onTriggered: root.closeQuitting()
  }

  // Left click: open it, bring it back, put it away.
  function toggle() {
    if (!root.running) root.launch()
    else if (root.focused && root.hideMode === "Special workspace") root.park()
    else if (root.parked) root.showWindow()
    else root.focusWindow()
  }

  function open() {
    if (!root.running) root.launch()
    else if (root.parked) root.showWindow()
    else root.focusWindow()
  }

  // The window is brought up first: whatsapp-tui's own focus lands after, on
  // a workspace that is already showing, so the two never toggle each other.
  function openConversation(row) {
    root.popupOpen = false
    root.open()
    Util.execArgv(["bash", "-lc", 'exec "$@"', "whatsapp-tui-open"].concat(Model.openArgs(row)))
  }

  // Minutes, or "tomorrow" (whatsapp-tui's own: 9 AM tomorrow). Works with
  // whatsapp-tui closed too: it keeps the pause in its data dir.
  function pause(minutes) {
    Util.execArgv(["bash", "-lc", 'exec "$@"', "whatsapp-tui-pause"].concat(Model.pauseArgs(minutes)))
  }

  // "Until a date and time…": a day and an hour:minute picked in the menu,
  // `pickerDay` days from today. The pause is the minutes from the moment of
  // the click to that time, rounded up.
  readonly property int pickerMaxDays: 30
  readonly property int pickerMinuteStep: 15
  property bool pickerOpen: false
  property int pickerDay: 0
  property int pickerHour: 0
  property int pickerMinute: 0
  readonly property real pickerTarget: Model.pickerTarget(root.pickerDay, root.pickerHour, root.pickerMinute, root.nowSec)
  readonly property bool pickerValid: Model.minutesUntil(root.pickerTarget, root.nowSec) > 0

  function resetPicker() {
    root.nowSec = Date.now() / 1000
    var start = Model.pickerDefault(root.nowSec)
    root.pickerDay = start.day
    root.pickerHour = start.hour
    root.pickerMinute = start.minute
  }

  function stepPickerDay(delta) {
    root.pickerDay = Math.max(0, Math.min(root.pickerMaxDays, root.pickerDay + delta))
  }
  function stepPickerHour(delta) { root.pickerHour = (root.pickerHour + delta + 24) % 24 }
  function stepPickerMinute(delta) {
    root.pickerMinute = (root.pickerMinute + delta * root.pickerMinuteStep + 60) % 60
  }

  // Measured again at the click: the clock the label follows ticks every 20 s.
  function pauseUntilPicked() {
    var now = Date.now() / 1000
    var minutes = Model.minutesUntil(Model.pickerTarget(root.pickerDay, root.pickerHour, root.pickerMinute, now), now)
    if (minutes <= 0) { root.nowSec = now; return }
    root.close()
    root.pause(minutes)
  }
  function resume() { Util.execArgv(["bash", "-lc", "whatsapp-tui resume"]) }

  function writeSetting(key, value) {
    var shell = root.bar ? root.bar.shell : null
    if (!shell || typeof shell.updateEntryInline !== "function") return
    var merged = JSON.parse(JSON.stringify(root.settings || {}))
    merged[key] = value
    shell.updateEntryInline(root.moduleName, merged)
  }

  Timer {
    id: refocusTimer
    property string address: ""
    interval: 120
    repeat: false
    onTriggered: if (address.length > 0)
      root.dispatch('hl.dsp.focus({ window = "' + address + '" })', "focuswindow " + address)
  }

  // One bar surface per monitor means N copies of this widget; only the first
  // may act on the session as a whole (launching at login, notifying).
  function isPrimaryInstance() {
    var peers = root.bar && typeof root.bar.moduleWidgets === "function"
      ? root.bar.moduleWidgets(root.moduleName) : []
    return peers.length === 0 || peers[0] === root
  }

  Timer {
    interval: 2500
    repeat: false
    running: root.autoStart
    onTriggered: if (!root.running && root.isPrimaryInstance()) root.launch()
  }

  // ---------------------------------------------------- desktop notifications
  //
  // `whatsapp-tui events` streams one JSON line per event. Each `message.new`
  // becomes a notification, unless notifications are paused, the chat is
  // muted, or you are looking at that chat. Only the primary instance
  // listens, so two monitors do not notify twice. The stream runs while the
  // window is open and is restarted if it drops.
  readonly property bool notifyWanted: root.desktopNotifications && root.running && !root.notInstalled
  property var notifiedIds: ({})
  property var notifiedOrder: []

  Process {
    id: events
    command: ["bash", "-lc", "exec whatsapp-tui events"]
    stdout: SplitParser {
      onRead: function (line) { root.handleEvent(line) }
    }
  }
  Timer {
    interval: 3000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      var want = root.notifyWanted && root.isPrimaryInstance()
      if (want && !events.running) events.running = true
      else if (!want && events.running) events.running = false
    }
  }

  function handleEvent(line) {
    var note = Model.notification(line, root.appState, Date.now() / 1000)
    if (!note) return
    // The same message twice (a reconnect replaying it) notifies once.
    if (note.msgId.length > 0) {
      if (root.notifiedIds[note.msgId]) return
      var ids = root.notifiedIds
      var order = root.notifiedOrder
      ids[note.msgId] = true
      order.push(note.msgId)
      while (order.length > 200) delete ids[order.shift()]
    }
    // The body is markup: whatsapp-tui's `html`, already escaped.
    var body = root.notificationText ? note.body : "New message"
    // A click on it runs the argv in Omarchy's notification center: the
    // chat opens at that message (`open` also brings the window up).
    var openArgv = Model.openArgs({ id: note.id, msgId: note.msgId })
    Util.execArgv(["notify-send",
      "--app-name=WhatsApp",
      "--icon=" + (note.avatar.length > 0 ? note.avatar : root.notificationIcon),
      "--hint=string:omarchy-exec-argv:" + JSON.stringify(openArgv),
      note.title,
      body])
  }

  // ----------------------------------------------------------- hover preview
  property bool popupOpen: false
  property bool menuOpen: false
  function close() {
    root.popupOpen = false
    root.menuOpen = false
  }

  onMenuOpenChanged: {
    if (!menuOpen) return
    root.popupOpen = false
    root.pickerOpen = false
    root.nowSec = Date.now() / 1000
    if (root.notInstalled) root.checkInstalled()
    else if (!root.stateLive && !pauseStatus.running) pauseStatus.running = true
  }

  // ---------------------------------------------------------- not installed
  //
  // Without a `whatsapp-tui` on PATH the widget turns into a way to get it: a
  // dimmed mark, and a card with a link to its repository. Assumed installed
  // until the first check says otherwise, so the bar does not flash the empty
  // state at login; re-checked every 30 s while missing, so an install is
  // picked up without restarting the shell.
  readonly property string websiteUrl: "https://github.com/leonavas/whatsapp-tui"
  property bool installed: true
  readonly property bool notInstalled: !root.installed && !root.running

  function checkInstalled() {
    if (!installCheck.running) installCheck.running = true
  }
  Process {
    id: installCheck
    command: ["bash", "-lc", "command -v whatsapp-tui >/dev/null"]
    onExited: function (code) { root.installed = code === 0 }
  }
  Component.onCompleted: root.checkInstalled()
  Timer {
    interval: 30000
    repeat: true
    running: !root.installed
    onTriggered: root.checkInstalled()
  }

  function openWebsite() { Util.execArgv(["xdg-open", root.websiteUrl]) }

  // `whatsapp-tui pause` and `resume` work with whatsapp-tui closed, but
  // there is no state file then: whether a pause is on comes from
  // `whatsapp-tui status --json`, asked when the menu opens.
  property bool offlinePaused: false
  Process {
    id: pauseStatus
    command: ["bash", "-lc", "whatsapp-tui status --json"]
    stdout: StdioCollector {
      onStreamFinished: root.offlinePaused = Model.statusPaused(this.text, Date.now() / 1000)
    }
  }

  // Available whenever whatsapp-tui is running and publishing, empty or not,
  // paused or not: "nothing waiting" is an answer worth hovering for.
  readonly property bool previewAvailable: ((root.hoverPreview && root.stateLive) || root.notInstalled)
    && !root.menuOpen
  readonly property bool previewHovered: button.tooltipHovered || popup.containsMouse

  onPreviewAvailableChanged: if (!previewAvailable) root.popupOpen = false
  onPreviewHoveredChanged: {
    if (root.previewHovered && root.previewAvailable) {
      closePreviewTimer.stop()
      if (!root.popupOpen) openPreviewTimer.restart()
    } else {
      openPreviewTimer.stop()
      if (root.popupOpen) closePreviewTimer.restart()
    }
  }
  onPopupOpenChanged: {
    if (!popupOpen) return
    root.nowSec = Date.now() / 1000
    if (root.notInstalled) root.checkInstalled()
  }

  Timer {
    id: openPreviewTimer
    interval: 350
    repeat: false
    onTriggered: if (root.previewHovered && root.previewAvailable) root.popupOpen = true
  }

  Timer {
    id: closePreviewTimer
    interval: 250
    repeat: false
    onTriggered: if (!root.previewHovered) root.popupOpen = false
  }

  // ------------------------------------------------------------------ layout
  visible: root.running || !root.hideWhenNotRunning
  implicitWidth: root.visible ? button.implicitWidth : 0
  implicitHeight: root.visible ? button.implicitHeight : 0

  readonly property string pauseLabel: {
    var until = Model.clockLabel(Model.pausedUntil(root.appState), root.nowSec)
    return until.length > 0 ? "Notifications paused until " + until : "Notifications paused"
  }

  readonly property string tooltip: {
    if (!root.running) return "WhatsApp: click to open"
    var text = "WhatsApp"
    if (root.attention > 0) text += ": " + root.attention + " waiting"
    if (root.muted) text += " (notifications paused)"
    else if (root.parked) text += root.attention > 0 ? "" : ", hidden"
    return text
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    iconComponent: root.iconStyle === "Glyph" ? glyphIcon
      : root.iconStyle === "Outline" ? outlineIcon
      : root.iconStyle === "Color" ? colorIcon : monoIcon
    active: root.anyBadge
    useActiveColor: root.tintWhenUnread
    dimmed: root.notInstalled || (!root.running && root.dimWhenClosed)
      || (root.muted && root.mutedIndicator === "Dim")
    tooltipText: root.previewAvailable ? "" : root.tooltip
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.closeOnMiddle && !root.notInstalled) root.quit()
      } else if (mouseButton === Qt.RightButton) {
        root.menuOpen = !root.menuOpen
      } else if (root.notInstalled) {
        // Nothing to launch: the left button opens the install card.
        root.menuOpen = false
        root.popupOpen = true
      } else {
        root.toggle()
      }
    }
  }

  Component {
    id: glyphIcon

    Item {
      opacity: root.markOpacity

      TextMetrics {
        id: metrics
        font.family: root.fontFamily
        font.pixelSize: root.glyphPixelSize
        text: root.glyph
      }

      Text {
        id: painted
        textFormat: Text.PlainText
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: painted.implicitWidth / 2
          - (metrics.tightBoundingRect.x + Math.max(1, metrics.tightBoundingRect.width) / 2)
        anchors.verticalCenterOffset: root.glyphOffsetY
        text: root.glyph
        color: root.glyphColor
        font.family: root.fontFamily
        font.pixelSize: root.glyphPixelSize
        renderType: Text.NativeRendering

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }
    }
  }

  Component {
    id: outlineIcon

    Image {
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      sourceSize.width: Math.round(width * Screen.devicePixelRatio)
      sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      source: root.outlineIconSource
      opacity: root.markOpacity
      smooth: true
    }
  }

  Component {
    id: colorIcon

    Image {
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      // Decode at physical pixels: the logical size leaves it blurry on HiDPI.
      sourceSize.width: Math.round(width * Screen.devicePixelRatio)
      sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      source: root.colorIconSource
      opacity: root.markOpacity
      smooth: true
    }
  }

  Component {
    id: monoIcon

    Item {
      opacity: root.markOpacity

      Image {
        id: monoImage
        anchors.fill: parent
        fillMode: Image.PreserveAspectFit
        sourceSize.width: Math.round(width * Screen.devicePixelRatio)
        sourceSize.height: Math.round(height * Screen.devicePixelRatio)
        source: root.monoIconSource
        smooth: true
        // Hidden layer so the effect can sample it, the way the tray tints
        // symbolic icons.
        visible: false
        layer.enabled: true
      }

      MultiEffect {
        anchors.fill: monoImage
        source: monoImage
        colorization: 1.0
        colorizationColor: root.glyphColor
      }
    }
  }

  // A small count pill on one corner of the icon canvas. A dot fits inside
  // the canvas; a count is nearly as tall as the canvas, so it is centred on
  // the corner instead, out into the slot's padding, like a tray badge.
  component CornerBadge: Rectangle {
    id: cornerBadge

    property int count: 0
    property string corner: "bottom-right"
    readonly property bool dotOnly: root.badgeStyle === "Dot"
    readonly property int sx: corner.indexOf("left") >= 0 ? -1 : 1
    readonly property int sy: corner.indexOf("top") === 0 ? -1 : 1

    visible: count > 0
    z: 2
    height: dotOnly ? Math.round(Style.bar.iconCanvas * root.badgeScale)
                    : Math.round(digits.contentHeight + Style.space(1))
    width: dotOnly ? height : Math.max(height, Math.round(digits.contentWidth + Style.space(5)))
    radius: height / 2

    // Vertically a little past the corner: with a badge on each right-hand
    // corner, that keeps the two off each other and off most of the mark.
    readonly property int reachX: dotOnly ? Math.round((Style.bar.iconCanvas - height) / 2)
                                          : Math.round(Style.bar.iconCanvas / 2)
    readonly property int reachY: dotOnly ? reachX : Math.round(Style.bar.iconCanvas / 2 + 1)
    readonly property int maxX: Math.max(0, Math.round((root.width - width) / 2))
    readonly property int maxY: Math.max(0, Math.round((root.height - height) / 2))

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.horizontalCenterOffset: sx * Math.min(reachX, maxX)
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: sy * Math.min(reachY, maxY)

    Text {
      id: digits
      textFormat: Text.PlainText
      // Aligned over the whole badge, like the card's pill: centerIn left
      // the digit off to the right.
      anchors.fill: parent
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      visible: !cornerBadge.dotOnly
      text: Model.badgeLabel(cornerBadge.count)
      color: root.badgeDigitColor
      font.family: root.fontFamily
      font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.85))
      font.bold: true
      renderType: Text.NativeRendering
    }
  }

  CornerBadge {
    count: root.combinedBadge ? root.combinedCount : root.directCount
    corner: root.directCorner
    color: root.combinedBadge ? root.combinedColor : root.directColor
  }

  CornerBadge {
    count: root.combinedBadge ? 0 : root.groupCount
    corner: root.groupCorner
    color: root.groupColor
  }

  // Paused: no badge. The mark fades and a bell-off takes the badge's
  // corner, outlined in the background color so it stays its own shape where
  // it overlaps the mark.
  Text {
    id: mutedMark
    textFormat: Text.PlainText
    readonly property int size: Math.max(8, Math.round(Style.bar.iconCanvas * 0.6))
    readonly property int corner: Math.round(Style.bar.iconCanvas / 2 - 1)
    visible: root.muted && root.mutedIndicator === "Bell"
    z: 2
    text: "󰂛"
    color: root.foreground
    style: Text.Outline
    styleColor: root.badgeTextColor
    font.family: root.fontFamily
    font.pixelSize: size
    renderType: Text.NativeRendering
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.horizontalCenterOffset: Math.min(corner, Math.max(0, Math.round((root.width - implicitWidth) / 2)))
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: Math.min(corner, Math.max(0, Math.round((root.height - implicitHeight) / 2)))
  }

  // ----------------------------------------------------------- preview card
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    triggerMode: "hover"
    contentWidth: popup.fittedContentWidth(Style.space(400))
    contentHeight: popup.fittedContentHeight(root.notInstalled ? installColumn.implicitHeight
                                                               : previewColumn.implicitHeight)

    readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
    readonly property color dim: Qt.rgba(popup.fg.r, popup.fg.g, popup.fg.b, 0.6)

    // whatsapp-tui not installed: what it is and where to get it.
    Column {
      id: installColumn
      anchors.fill: parent
      spacing: Style.space(8)
      visible: root.notInstalled

      Text {
        textFormat: Text.PlainText
        text: "whatsapp-tui not detected"
        color: popup.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "whatsapp-tui is a WhatsApp client for the terminal. Get it at:"
        color: popup.dim
        wrapMode: Text.Wrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        text: "github.com/leonavas/whatsapp-tui"
        color: siteArea.containsMouse ? popup.fg : popup.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.underline: true

        MouseArea {
          id: siteArea
          anchors.fill: parent
          anchors.margins: -Style.space(3)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.popupOpen = false
            root.openWebsite()
          }
        }
      }
    }

    Column {
      id: previewColumn
      anchors.fill: parent
      spacing: Style.space(6)
      visible: !root.notInstalled

      Row {
        width: parent.width
        spacing: Style.space(6)

        Image {
          readonly property int box: Math.round(Style.font.bodySmall * 1.2)
          width: box
          height: box
          anchors.verticalCenter: parent.verticalCenter
          source: root.colorIconSource
          sourceSize.width: Math.round(box * Screen.devicePixelRatio)
          sourceSize.height: Math.round(box * Screen.devicePixelRatio)
          fillMode: Image.PreserveAspectFit
          smooth: true
        }

        Text {
          textFormat: Text.PlainText
          // `connected` false: reconnecting, the counts are the last known.
          text: (root.attention > 0 ? "WhatsApp · " + root.attention + " waiting" : "WhatsApp")
            + (root.appState && root.appState.connected === false ? " · connecting…" : "")
          color: popup.fg
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      // Paused: when it ends, and a way out.
      Row {
        visible: root.muted
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: "󰂛"
          color: popup.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          textFormat: Text.PlainText
          text: root.pauseLabel + " ·"
          color: popup.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          textFormat: Text.PlainText
          text: "Resume"
          color: popup.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          font.underline: resumeArea.containsMouse

          MouseArea {
            id: resumeArea
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.resume()
          }
        }
      }

      PanelSeparator {
        foreground: popup.fg
      }

      Text {
        textFormat: Text.PlainText
        visible: root.preview.rows.length === 0
        text: root.totals.mutedChats > 0 ? "Nothing that notifies you" : "No unread messages"
        color: popup.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Repeater {
        model: root.preview.rows

        Rectangle {
          id: chatRow
          required property var modelData

          readonly property bool isGroup: chatRow.modelData.kind === "group"
          readonly property color kindColor: chatRow.isGroup ? root.groupColor : root.directColor
          readonly property int indent: Math.round(Style.font.bodySmall * 1.5)

          width: previewColumn.width
          height: chatInner.implicitHeight + Style.space(12)
          radius: Style.spacing.labelGap
          color: rowArea.containsMouse
            ? Qt.rgba(popup.fg.r, popup.fg.g, popup.fg.b, 0.08) : "transparent"

          Column {
            id: chatInner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(3)

            Item {
              width: parent.width
              height: nameText.implicitHeight

              Text {
                id: kindText
                textFormat: Text.PlainText
                width: chatRow.indent
                text: chatRow.modelData.glyph
                color: chatRow.kindColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                anchors.left: parent.left
                anchors.baseline: nameText.baseline
              }

              Text {
                id: nameText
                textFormat: Text.PlainText
                text: chatRow.modelData.name
                color: popup.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
                anchors.left: kindText.right
                anchors.right: marker.left
                anchors.rightMargin: Style.space(8)
              }

              // Unread count as a pill, in the badge's color for the kind.
              Rectangle {
                id: marker
                // Whole pixels: a fractional box puts the digit off center.
                width: Math.max(height, Math.round(countText.contentWidth + Style.space(8)))
                height: Math.round(countText.contentHeight + Style.space(2))
                radius: height / 2
                color: chatRow.kindColor
                anchors.right: timeText.left
                anchors.rightMargin: timeText.text !== "" ? Style.space(8) : 0
                anchors.verticalCenter: nameText.verticalCenter

                Text {
                  id: countText
                  textFormat: Text.PlainText
                  // Centered by the text's own alignment over the whole pill,
                  // not by centerIn, which rounds the text box's position
                  // and left the digit a pixel or two to the right.
                  anchors.fill: parent
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  text: Model.badgeLabel(chatRow.modelData.count)
                  color: root.badgeDigitColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Text {
                id: timeText
                textFormat: Text.PlainText
                text: Model.relativeTime(chatRow.modelData.latest, root.nowSec)
                color: popup.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.baseline: nameText.baseline
              }
            }

            // The newest unread messages, oldest first, up to two lines each,
            // with WhatsApp's bold, italic, strikethrough and monospace.
            // whatsapp-tui's `html` is escaped: nothing a message says
            // becomes markup of its own (Model.messageHtml).
            Repeater {
              model: chatRow.modelData.lines

              Text {
                required property var modelData
                x: chatRow.indent
                width: chatInner.width - x
                text: modelData
                textFormat: Text.StyledText
                color: Qt.darker(popup.fg, 1.3)
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openConversation(chatRow.modelData)
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.preview.hidden > 0
        text: "+" + root.preview.hidden + (root.preview.hidden === 1 ? " more chat" : " more chats")
        color: popup.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // Muted chats with unread messages: counted, not listed.
      Text {
        textFormat: Text.PlainText
        visible: root.totals.mutedChats > 0
        text: "+" + root.totals.mutedChats
          + (root.totals.mutedChats === 1 ? " muted chat unread" : " muted chats unread")
        color: popup.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ------------------------------------------------------------------- menu
  PopupCard {
    id: menu
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.menuOpen
    contentWidth: menu.fittedContentWidth(Style.space(210))
    contentHeight: menu.fittedContentHeight(menuColumn.implicitHeight)

    readonly property color fg: root.bar ? root.bar.foreground : Color.foreground

    component MenuEntry: Rectangle {
      id: entry

      property string label: ""
      property bool showCheck: false
      property bool checked: false
      property bool clickable: true
      property int indent: 0

      signal activated()

      width: menuColumn.width
      height: entryText.implicitHeight + Style.space(12)
      radius: Style.spacing.labelGap
      color: entry.clickable && entryArea.containsMouse && entry.enabled
        ? Qt.rgba(menu.fg.r, menu.fg.g, menu.fg.b, 0.08) : "transparent"
      opacity: !entry.enabled ? 0.4 : (entry.clickable ? 1 : 0.6)

      Text {
        id: entryText
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8) + entry.indent
        anchors.verticalCenter: parent.verticalCenter
        text: entry.label
        color: menu.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        visible: entry.showCheck
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: entry.checked ? "✓" : ""
        color: menu.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      MouseArea {
        id: entryArea
        anchors.fill: parent
        enabled: entry.clickable
        hoverEnabled: true
        cursorShape: entry.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: entry.activated()
      }
    }

    // ‹ value ›, for the pause picker. Clicks on the chevrons or the wheel
    // over it step the value.
    component Stepper: Item {
      id: stepper

      property string label: ""
      property int valueWidth: 0
      property bool canBack: true
      property bool canForward: true

      signal stepped(int delta)

      implicitWidth: backChevron.implicitWidth + stepper.valueWidth + forwardChevron.implicitWidth + Style.space(8)
      implicitHeight: valueText.implicitHeight + Style.space(8)

      WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function (event) {
          if (event.angleDelta.y > 0 && stepper.canForward) stepper.stepped(1)
          else if (event.angleDelta.y < 0 && stepper.canBack) stepper.stepped(-1)
        }
      }

      Text {
        id: backChevron
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "󰅁"
        color: menu.fg
        opacity: !stepper.canBack ? 0.25 : backArea.containsMouse ? 1 : 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        MouseArea {
          id: backArea
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          enabled: stepper.canBack
          cursorShape: Qt.PointingHandCursor
          onClicked: stepper.stepped(-1)
        }
      }

      Text {
        id: valueText
        textFormat: Text.PlainText
        anchors.left: backChevron.right
        anchors.right: forwardChevron.left
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignHCenter
        text: stepper.label
        color: menu.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        id: forwardChevron
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "󰅂"
        color: menu.fg
        opacity: !stepper.canForward ? 0.25 : forwardArea.containsMouse ? 1 : 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        MouseArea {
          id: forwardArea
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          enabled: stepper.canForward
          cursorShape: Qt.PointingHandCursor
          onClicked: stepper.stepped(1)
        }
      }
    }

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(2)

      // whatsapp-tui not installed: only the way to get it.
      MenuEntry {
        visible: root.notInstalled
        label: "Get whatsapp-tui on GitHub"
        onActivated: {
          root.close()
          root.openWebsite()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: !root.notInstalled

        MenuEntry {
          label: !root.running ? "Open WhatsApp"
            : root.parked && !root.specialShown ? "Show WhatsApp"
            : (root.focused && root.hideMode === "Special workspace") ? "Hide WhatsApp"
            : "Focus WhatsApp"
          onActivated: {
            root.close()
            root.toggle()
          }
        }

        PanelSeparator { foreground: menu.fg }

        // Closed before the write: saving shell.json can rebuild the bar's
        // widgets, and a menu owned by a destroyed widget dies mid-click.
        MenuEntry {
          label: "Launch on Login"
          showCheck: true
          checked: root.autoStart
          onActivated: {
            root.close()
            root.writeSetting("autoStart", !root.autoStart)
          }
        }

        MenuEntry {
          label: "Launch in Foreground"
          showCheck: true
          checked: root.launchForeground
          onActivated: {
            root.close()
            root.writeSetting("launchForeground", !root.launchForeground)
          }
        }

        MenuEntry {
          label: "Open in Scratchpad"
          showCheck: true
          checked: root.openInSpecial
          onActivated: {
            root.close()
            root.writeSetting("openInSpecial", !root.openInSpecial)
          }
        }

        MenuEntry {
          label: "Group notifications"
          showCheck: true
          checked: root.combinedBadge
          onActivated: {
            root.close()
            root.writeSetting("badgeLayout", root.combinedBadge ? "Split" : "Combined")
          }
        }

        MenuEntry {
          label: "Desktop notifications"
          showCheck: true
          checked: root.desktopNotifications
          onActivated: {
            root.close()
            root.writeSetting("notifications", !root.desktopNotifications)
          }
        }

        PanelSeparator { foreground: menu.fg }

        MenuEntry {
          visible: root.stateLive ? root.muted : root.offlinePaused
          label: "Resume notifications"
          onActivated: {
            root.close()
            root.resume()
          }
        }

        MenuEntry {
          label: "Pause notifications"
          clickable: false
        }

        Repeater {
          model: [
            { label: "30 minutes", minutes: 30 },
            { label: "1 hour", minutes: 60 },
            { label: "2 hours", minutes: 120 },
            { label: "Until tomorrow", minutes: -1 },
          ]

          MenuEntry {
            required property var modelData
            label: modelData.label
            indent: Style.space(10)
            onActivated: {
              root.close()
              root.pause(modelData.minutes > 0 ? modelData.minutes : "tomorrow")
            }
          }
        }

        MenuEntry {
          label: "Until a date and time…"
          indent: Style.space(10)
          onActivated: {
            if (!root.pickerOpen) root.resetPicker()
            root.pickerOpen = !root.pickerOpen
          }
        }

        // The picker: a day, an hour and a minute, then the pause itself,
        // labelled with when it would end.
        Column {
          visible: root.pickerOpen
          width: parent.width
          spacing: Style.space(2)

          Stepper {
            x: Style.space(18)
            width: parent.width - x - Style.space(8)
            label: Model.pickerDayLabel(root.pickerDay, root.nowSec)
            canBack: root.pickerDay > 0
            canForward: root.pickerDay < root.pickerMaxDays
            onStepped: function (delta) { root.stepPickerDay(delta) }
          }

          Row {
            x: Style.space(18)
            spacing: Style.space(4)

            Stepper {
              valueWidth: Math.round(Style.font.bodySmall * 2)
              label: Model.pad(root.pickerHour)
              onStepped: function (delta) { root.stepPickerHour(delta) }
            }
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: ":"
              color: menu.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Stepper {
              valueWidth: Math.round(Style.font.bodySmall * 2)
              label: Model.pad(root.pickerMinute)
              onStepped: function (delta) { root.stepPickerMinute(delta) }
            }
          }

          MenuEntry {
            indent: Style.space(10)
            enabled: root.pickerValid
            label: root.pickerValid ? "Pause until " + Model.clockLabel(root.pickerTarget, root.nowSec)
                                    : "Pick a time in the future"
            onActivated: root.pauseUntilPicked()
          }
        }

        PanelSeparator { foreground: menu.fg }

        MenuEntry {
          label: "Quit WhatsApp"
          enabled: root.running
          onActivated: {
            root.close()
            root.quit()
          }
        }
      }
    }
  }
}
