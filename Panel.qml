import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Bar icon that opens a filterable list of Italian web radios. The directory
// is fetched only when the panel opens and the saved copy is missing or older
// than a day. The left column is the player and favorites. The right column
// is the filters and the station list. A click asks radio-player to play the
// stream in one sandboxed mpv. The player pauses and resumes that stream.
Panel {
  id: root
  moduleName: "mattia.radio"
  ipcTarget: "mattia.radio"
  // This panel owns the handler so start/stop and next-favorite can share it
  // with open and close. A second handler for the same target is ignored.
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function power(): string { return root.power() }
    function next(): string { return root.nextFavorite() }
  }

  readonly property string radioGlyph: "󰐹"
  readonly property string starOnGlyph: String.fromCodePoint(0xF04CE)
  readonly property string starOffGlyph: String.fromCodePoint(0xF04D2)
  readonly property string playGlyph: String.fromCodePoint(0xF040A)
  readonly property string pauseGlyph: String.fromCodePoint(0xF03E4)
  readonly property string cacheDir: {
    var home = String(Quickshell.env("HOME") || "")
    if (!home || /[\u0000-\u001F]/.test(home)) return ""
    return home + "/.cache/mattia.radio"
  }
  readonly property string cachePath: cacheDir !== "" ? cacheDir + "/stations.json" : ""
  readonly property string stateDir: {
    var home = String(Quickshell.env("HOME") || "")
    if (!home || /[\u0000-\u001F]/.test(home)) return ""
    var state = String(Quickshell.env("XDG_STATE_HOME") || "")
    var base = home + "/.local/state"
    if (state.charAt(0) === "/" && state.indexOf("..") === -1 && !/[\u0000-\u001F\s]/.test(state))
      base = state.replace(/\/+$/, "")
    return base + "/mattia.radio"
  }
  readonly property string favoritesPath: stateDir !== "" ? stateDir + "/favorites.json" : ""
  readonly property string playerPath: {
    var text = Qt.resolvedUrl("radio-player").toString()
    if (text.indexOf("file://") !== 0) return ""
    var path = decodeURIComponent(text.slice(7))
    if (path.charAt(0) !== "/" || path.indexOf("..") !== -1 || /[\u0000-\u001F]/.test(path)) return ""
    return path
  }
  // radio-player rewrites this on every command. A reloaded bar icon has no
  // memory of the station, so it reads the file instead of waiting for a click.
  readonly property string playbackPath: {
    var runtime = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    if (runtime.charAt(0) !== "/" || runtime.indexOf("..") !== -1 || /[\u0000-\u001F\s]/.test(runtime)) return ""
    return runtime.replace(/\/+$/, "") + "/mattia.radio/playback.json"
  }
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  // Brighter than list text, in the theme accent hue, so the station in the
  // player reads at a glance. A light panel uses a darker shade of that hue.
  readonly property color playingTitleColor: {
    var bg = Commons.Color.background
    var dark = (bg.r * 0.2126 + bg.g * 0.7152 + bg.b * 0.0722) < 0.5
    var hue = Commons.Color.accent.hslHue
    return dark ? Qt.hsla(hue, 0.55, 0.90, 1) : Qt.hsla(hue, 0.65, 0.28, 1)
  }
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(foreground, Commons.Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(foreground, Commons.Color.accent) : "transparent"

  property var stations: []
  property double fetchedAt: 0
  property bool cacheReady: false
  property string query: ""
  property string regionQuery: ""
  property var favorites: []
  property bool favoritesReady: false
  property bool favoritesDirty: false
  property string pendingFavorites: ""
  readonly property var favoriteMark: {
    var mark = {}
    var rows = favorites
    for (var i = 0; i < rows.length; i++) mark[rows[i].id] = true
    return mark
  }
  readonly property var shownFavorites: Model.resolveFavorites(favorites, stations)
  // Each list has one row height, measured from its own longest name and
  // region at that list's width. Text wraps onto full lines and is not cut off.
  readonly property real entryActionSize: Math.round(Math.max(Style.space(22), Style.font.icon + Style.spacing.sm * 2)) | 1
  function entryTextWidth(listWidth) {
    var chrome = Style.space(8) + Style.space(28) + Style.space(8) + entryActionSize + Style.space(4)
    var width = listWidth > 0 ? listWidth - chrome : Style.space(320) - chrome
    return Math.max(Style.space(40), width)
  }
  readonly property string favoriteNameSample: {
    var sample = Model.longestField(favorites, [], "name")
    return sample !== "" ? sample : " "
  }
  readonly property string favoriteRegionSample: Model.longestField(favorites, [], "region")
  readonly property string stationNameSample: {
    var sample = Model.longestField(stations, [], "name")
    return sample !== "" ? sample : " "
  }
  readonly property string stationRegionSample: Model.longestField(stations, [], "region")
  readonly property real favoriteEntryHeight: Math.max(favoriteProbe.implicitHeight, Style.space(28), entryActionSize) + Style.space(8)
  readonly property real stationEntryHeight: Math.max(stationProbe.implicitHeight, Style.space(28), entryActionSize) + Style.space(8)
  property int selectedIndex: 0
  property bool wheelScrolling: false
  property real lastCursorMs: 0
  property bool fetchBusy: false
  property bool loadFailed: false
  property int hostIndex: 0
  property bool fetchHandled: false
  property string pendingCache: ""

  property string playingId: ""
  property string playingName: ""
  // Kept after stop, so the start key can play this station again.
  property var lastStation: null
  // Same directory row the lists use, so the player can show its icon and region.
  readonly property var playingStation: Model.findStation(stations, favorites, playingId)
  readonly property string playingIcon: playingStation && playingStation.icon ? playingStation.icon : ""
  readonly property string playingRegion: playingStation && playingStation.region ? playingStation.region : ""
  property bool paused: false
  property bool playerActive: false
  property bool playbackError: false
  property string playerReason: ""

  readonly property var filtered: Model.filterStations(stations, query, regionQuery)
  readonly property string statusText: {
    if (fetchBusy && stations.length === 0) return strings.t("panel.loading")
    if (loadFailed && stations.length === 0) return strings.t("panel.failed")
    if (stations.length > 0 && filtered.length === 0) return strings.t("panel.none")
    if (playbackError && playerReason === "no-player") return strings.t("panel.noPlayer")
    if (playbackError) return strings.t("panel.playbackFailed")
    if (stations.length === 0) return ""
    return strings.tn("panel.count", filtered.length).arg(Commons.I18n.formatNumber(filtered.length))
  }
  readonly property string tooltipText: Model.tooltipText(
    playingName,
    strings.t("tooltip.idle"),
    strings.t("tooltip.playing")
  )

  function applyCache(raw) {
    var parsed = Model.parseCache(raw)
    if (parsed.stations.length === 0) return
    stations = parsed.stations
    fetchedAt = parsed.fetchedAt
  }

  function refreshIfStale() {
    if (!cacheReady || fetchBusy) return
    if (stations.length > 0 && !Model.cacheIsStale(fetchedAt, Date.now())) return
    refreshDirectory()
  }

  function refreshDirectory() {
    if (fetchBusy) return
    hostIndex = 0
    startFetch()
  }

  function startFetch() {
    var command = Model.fetchCommand(hostIndex)
    if (!command.length) {
      fetchBusy = false
      loadFailed = stations.length === 0
      return
    }
    fetchBusy = true
    loadFailed = false
    fetchHandled = false
    fetchProc.command = command
    fetchProc.running = true
  }

  function acceptFetch(raw) {
    var parsed = Model.parseDirectory(raw)
    if (parsed.length > 0) {
      stations = parsed
      fetchedAt = Date.now()
      fetchBusy = false
      loadFailed = false
      saveCache()
      return
    }
    hostIndex += 1
    if (Model.fetchCommand(hostIndex).length > 0) {
      startFetch()
      return
    }
    fetchBusy = false
    loadFailed = stations.length === 0
  }

  function isFavorite(id) {
    return favoriteMark[id] === true
  }

  function toggleFavorite(station) {
    favoritesDirty = true
    favorites = Model.toggleFavorite(favorites, station)
    saveFavorites()
  }

  function saveFavorites() {
    if (favoritesPath === "") return
    pendingFavorites = Model.favoritesPayload(favorites)
    if (!stateMkdir.running) stateMkdir.running = true
  }

  function syncFavoriteSnapshots() {
    if (lastStation && lastStation.id) rememberStation(lastStation.id, lastStation.name)
    if (!favoritesReady || favorites.length === 0) return
    var next = Model.resolveFavorites(favorites, stations)
    if (Model.favoritesPayload(next) === Model.favoritesPayload(favorites)) return
    favorites = next
    saveFavorites()
  }

  function saveCache() {
    if (cachePath === "") return
    var payload = Model.cachePayload(stations, fetchedAt)
    if (!payload) return
    pendingCache = payload
    if (!mkdirProc.running) mkdirProc.running = true
  }

  function focusFilter() {
    var field = panel.loadedContent ? panel.loadedContent.filterField : null
    if (field) field.forceActiveFocus()
  }

  function handleFieldKey(event) {
    var plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
    if (event.key === Qt.Key_Down) {
      moveCursor(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      moveCursor(-1)
      event.accepted = true
    } else if (plain && event.key === Qt.Key_PageDown) {
      moveByPage(1)
      event.accepted = true
    } else if (plain && event.key === Qt.Key_PageUp) {
      moveByPage(-1)
      event.accepted = true
    } else if (plain && event.key === Qt.Key_Home) {
      moveToEdge(false)
      event.accepted = true
    } else if (plain && event.key === Qt.Key_End) {
      moveToEdge(true)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      activateCursor()
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      close()
      event.accepted = true
    }
  }

  function moveCursor(delta) {
    var now = Date.now()
    var gap = lastCursorMs === 0 ? 1000 : now - lastCursorMs
    lastCursorMs = now
    // A held arrow repeats much faster than a separate press. Treat that
    // like the wheel: scroll, and do not keep a highlight on a flying row.
    if (gap < 80) {
      noteWheelScroll()
      if (panel.loadedContent) panel.loadedContent.scrollByRows(delta)
      return
    }
    wheelScrolling = false
    pointerGate.reset()
    var count = filtered.length
    if (count === 0) {
      selectedIndex = -1
      return
    }
    if (selectedIndex < 0) {
      var visible = panel.loadedContent ? panel.loadedContent.indexAtEdge(delta < 0) : -1
      selectedIndex = visible >= 0 ? visible : (delta > 0 ? 0 : count - 1)
    } else {
      selectedIndex = Math.max(0, Math.min(count - 1, selectedIndex + delta))
    }
    if (panel.loadedContent) panel.loadedContent.revealSelection()
  }

  // One press moves about a viewport and keeps the target row highlighted.
  function moveByPage(direction) {
    var count = filtered.length
    if (count === 0) {
      selectedIndex = -1
      return
    }
    wheelScrolling = false
    pointerGate.reset()
    lastCursorMs = 0
    var page = panel.loadedContent ? panel.loadedContent.pageStride() : 1
    var origin = selectedIndex
    if (origin < 0 && panel.loadedContent)
      origin = panel.loadedContent.indexAtEdge(direction < 0)
    if (origin < 0) origin = direction > 0 ? 0 : count - 1
    selectedIndex = Math.max(0, Math.min(count - 1, origin + direction * page))
    if (panel.loadedContent) panel.loadedContent.revealSelection()
  }

  function moveToEdge(toEnd) {
    var count = filtered.length
    if (count === 0) {
      selectedIndex = -1
      return
    }
    wheelScrolling = false
    pointerGate.reset()
    lastCursorMs = 0
    selectedIndex = toEnd ? count - 1 : 0
    if (panel.loadedContent) panel.loadedContent.revealSelection()
  }

  function noteWheelScroll() {
    wheelScrolling = true
    pointerGate.reset()
    if (selectedIndex !== -1) selectedIndex = -1
    wheelIdle.restart()
  }

  function activateCursor() {
    if (selectedIndex < 0 || selectedIndex >= filtered.length) return
    toggleStation(filtered[selectedIndex])
  }

  function applyPlayerStatus(raw, failed) {
    var status = Model.parsePlayerStatus(raw)
    if (!status) {
      if (failed) {
        playbackError = true
        playerReason = "playback"
        playerActive = false
      }
      return
    }
    if (!status.running && !status.error) {
      playingId = ""
      playingName = ""
      paused = false
      playerActive = false
      playbackError = false
      playerReason = ""
      return
    }
    if (status.id) {
      playingId = status.id
      root.rememberStation(status.id, status.name)
    }
    if (status.name) playingName = status.name
    paused = status.paused
    playerActive = status.running && !status.error && (!status.idle || status.starting)
    playbackError = status.error || (failed && !playerActive)
    playerReason = playbackError ? (status.reason || "playback") : ""
  }

  function runPlayer(args) {
    if (!playerPath || !args || args.length === 0) {
      playbackError = true
      playerReason = "no-player"
      playerActive = false
      return
    }
    if (playerAction.running) {
      playerAction.queued = args
      return
    }
    playerAction.output = ""
    playerAction.errorOutput = ""
    playerAction.command = args
    playerAction.running = true
  }

  function refreshStatus() {
    if (!playerPath || playerAction.running || statusProc.running) return
    statusProc.output = ""
    statusProc.command = [playerPath, "status"]
    statusProc.running = true
  }

  function rememberStation(id, name) {
    var found = Model.findStation(stations, favorites, id)
    if (found) {
      lastStation = found
      return
    }
    if (lastStation && lastStation.id === id && lastStation.stream) return
    if (id) lastStation = { id: id, name: name || "", stream: "" }
  }

  function playStation(station) {
    if (!station) return false
    var resolved = Model.findStation(stations, favorites, station.id) || station
    if (!Model.streamUrl(resolved.stream)) {
      playbackError = true
      playerReason = "playback"
      return false
    }
    playbackError = false
    playerReason = ""
    paused = false
    playerActive = true
    playingId = resolved.id
    playingName = resolved.name
    lastStation = resolved
    runPlayer([playerPath, "play", resolved.id, resolved.name, resolved.stream])
    return true
  }

  // Stop a running player, including while it is paused. Start the last
  // station, or the first favorite when nothing has played yet.
  function power() {
    if (playerActive) {
      playerActive = false
      paused = false
      runPlayer([playerPath, "stop"])
      return "stopped"
    }
    var station = lastStation
    if (station && station.id) {
      var live = Model.findStation(stations, favorites, station.id)
      if (live) station = live
    }
    if (!station || !Model.streamUrl(station.stream)) {
      var saved = shownFavorites
      station = saved && saved.length ? saved[0] : null
    }
    return playStation(station) ? "started" : "no-station"
  }

  // The favorite after the one that is playing. The row after the last is
  // the first. A station that is not a favorite starts at the first.
  function nextFavorite() {
    var rows = shownFavorites || []
    if (!rows.length) return "no-favorites"
    var current = playingId || (lastStation && lastStation.id) || ""
    return playStation(Model.nextInCircle(rows, current)) ? "ok" : "no-station"
  }

  function toggleStation(station) {
    if (!station) return
    if (station.id === playingId && playerActive) {
      togglePause()
      return
    }
    playStation(station)
  }

  function togglePause() {
    if (!playerActive) {
      if (selectedIndex >= 0 && selectedIndex < filtered.length)
        toggleStation(filtered[selectedIndex])
      return
    }
    runPlayer([playerPath, "toggle"])
  }

  onQueryChanged: {
    pointerGate.reset()
    selectedIndex = filtered.length > 0 ? 0 : -1
  }
  onRegionQueryChanged: {
    pointerGate.reset()
    selectedIndex = filtered.length > 0 ? 0 : -1
  }
  onFilteredChanged: {
    if (selectedIndex >= filtered.length) selectedIndex = filtered.length > 0 ? 0 : -1
  }
  onStationsChanged: syncFavoriteSnapshots()
  Component.onCompleted: refreshStatus()
  onOpenedChanged: {
    if (!opened) return
    panel.ensureContent()
    refreshIfStale()
    refreshStatus()
    Qt.callLater(focusFilter)
  }

  FileView {
    id: cacheFile
    path: root.cachePath
    printErrors: false
    watchChanges: false
    onLoaded: {
      root.applyCache(text())
      root.cacheReady = true
      if (root.opened) root.refreshIfStale()
    }
    onLoadFailed: {
      root.cacheReady = true
      if (root.opened) root.refreshIfStale()
    }
  }

  FileView {
    id: playbackFile
    path: root.playbackPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyPlayerStatus(text(), false)
    onFileChanged: reload()
  }

  FileView {
    id: favoritesFile
    path: root.favoritesPath
    printErrors: false
    watchChanges: false
    onLoaded: {
      if (!root.favoritesDirty) root.favorites = Model.parseFavorites(text())
      root.favoritesReady = true
      root.syncFavoriteSnapshots()
    }
    onLoadFailed: {
      root.favoritesReady = true
      root.syncFavoriteSnapshots()
    }
  }

  Process {
    id: stateMkdir
    command: ["mkdir", "-p", root.stateDir]
    onExited: function(code) {
      if (code !== 0 || root.pendingFavorites === "" || root.favoritesPath === "") return
      favoritesFile.setText(root.pendingFavorites)
      root.pendingFavorites = ""
    }
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.cacheDir]
    onExited: function(code) {
      if (code !== 0 || root.pendingCache === "" || root.cachePath === "") return
      cacheFile.setText(root.pendingCache)
      root.pendingCache = ""
    }
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.fetchHandled) return
        root.fetchHandled = true
        root.acceptFetch(text)
      }
    }
    onExited: function() {
      Qt.callLater(function() {
        if (root.fetchHandled) return
        root.fetchHandled = true
        root.acceptFetch("")
      })
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && !playerAction.running && !statusProc.running
    onTriggered: root.refreshStatus()
  }

  Process {
    id: playerAction
    property var queued: null
    property string output: ""
    property string errorOutput: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: playerAction.output = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: playerAction.errorOutput = text
    }
    onExited: function(code) {
      var queued = playerAction.queued
      var failed = code !== 0
      playerAction.queued = null
      // The collector writes the output after this signal. Apply it on the next turn.
      Qt.callLater(function() {
        root.applyPlayerStatus(playerAction.output, failed)
        if (queued) root.runPlayer(queued)
      })
    }
  }

  Process {
    id: statusProc
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        statusProc.output = text
        if (!playerAction.running) root.applyPlayerStatus(text, false)
      }
    }
    onExited: function(code) {
      var failed = code !== 0
      Qt.callLater(function() {
        if (!playerAction.running && (failed || statusProc.output !== ""))
          root.applyPlayerStatus(statusProc.output, failed)
      })
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PointerMoveGate { id: pointerGate }

  Timer {
    id: wheelIdle
    interval: 180
    onTriggered: root.wheelScrolling = false
  }

  component FilterField: Item {
    id: box

    property string placeholder: ""
    property alias editor: field
    signal edited(string value)

    implicitHeight: field.implicitHeight

    TextField {
      id: field
      anchors.fill: parent
      placeholderText: box.placeholder
      foreground: root.foreground
      accent: Commons.Color.accent
      font.family: root.fontFamily
      rightPadding: horizontalPadding + clearButton.implicitWidth
      onTextChanged: box.edited(text)
      Keys.onPressed: function(event) { root.handleFieldKey(event) }
    }

    PanelActionButton {
      id: clearButton
      anchors.right: parent.right
      anchors.rightMargin: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter
      z: 1
      visible: field.text !== ""
      iconText: "󰅖"
      tooltipText: strings.t("panel.clear")
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      size: Style.space(18)
      onClicked: {
        field.text = ""
        field.forceActiveFocus()
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.radioGlyph
    tooltipText: root.tooltipText
    active: root.playerActive && !root.paused
    activeColor: "#f5c518"
    onPressed: root.toggle()
  }

  Column {
    id: favoriteProbe
    visible: false
    width: root.entryTextWidth(favoriteList.width)
    spacing: Style.space(1)

    Text {
      width: favoriteProbe.width
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: root.favoriteNameSample
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: favoriteProbe.width
      visible: root.favoriteRegionSample !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: root.favoriteRegionSample
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Column {
    id: stationProbe
    visible: false
    width: root.entryTextWidth(stationList.width)
    spacing: Style.space(1)

    Text {
      width: stationProbe.width
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: root.stationNameSample
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: stationProbe.width
      visible: root.stationRegionSample !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: root.stationRegionSample
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(860))
    contentHeight: panel.fittedContentHeight(panel.loadedContent ? panel.loadedContent.implicitHeight : Style.space(720))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias filterField: nameFilter.editor

      function revealSelection() {
        if (root.selectedIndex < 0) return
        stationList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      }

      function indexAtEdge(fromEnd) {
        var y = fromEnd ? stationList.contentY + stationList.height - 2 : stationList.contentY + 2
        var item = stationList.itemAt(4, y)
        return item && item.index >= 0 ? item.index : -1
      }

      function pageStride() {
        var top = indexAtEdge(false)
        var bottom = indexAtEdge(true)
        if (top < 0 || bottom < top) return 1
        return Math.max(1, bottom - top + 1)
      }

      function scrollByRows(delta) {
        var sample = stationList.itemAt(4, stationList.contentY + 4)
        var step = (sample && sample.height > 0 ? sample.height : Style.space(36)) + stationList.spacing
        var maxY = Math.max(0, stationList.contentHeight - stationList.height)
        stationList.contentY = Math.max(0, Math.min(maxY, stationList.contentY + delta * step))
      }
      anchors.fill: parent
      implicitHeight: Style.space(720)
      blocked: nameFilter.editor.activeFocus || regionFilter.editor.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      // The catcher sees keys before a focused filter, and it does not use
      // Page Up, Page Down, Home, or End. Handle them here when the filter
      // does not already have the event.
      Component.onCompleted: {
        Keys.pressed.connect(function(event) {
          if (nameFilter.editor.activeFocus || regionFilter.editor.activeFocus) return
          root.handleFieldKey(event)
        })
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        anchors.fill: parent
        spacing: Style.space(8)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("panel.title")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("panel.source")
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          id: columns
          width: parent.width
          height: Math.max(0, parent.height - y)
          spacing: Style.space(16)

          Item {
            id: leftCol
            width: Style.space(320)
            height: parent.height

            BorderSurface {
              id: playerCard
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              // The card shares the top and bottom of the name and region filters.
              height: nameFilter.implicitHeight + stationColumn.spacing + regionFilter.implicitHeight
              radius: Style.cornerRadius
              color: "transparent"
              borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)
              padding: Style.space(8)

              Item {
                id: playerFace
                anchors.fill: parent
                anchors.leftMargin: playerCard.contentLeftInset
                anchors.rightMargin: playerCard.contentRightInset
                anchors.topMargin: playerCard.contentTopInset
                anchors.bottomMargin: playerCard.contentBottomInset

                Item {
                  id: playerIcon
                  width: Style.space(28)
                  height: Style.space(28)
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: width
                  implicitHeight: height

                  Loader {
                    id: playerLogo
                    anchors.fill: parent
                    active: root.playingIcon !== ""
                    sourceComponent: SizedImage {
                      anchors.fill: parent
                      asynchronous: true
                      url: root.playingIcon
                    }
                    readonly property bool shown: item && item.status === Image.Ready
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !playerLogo.shown
                    textFormat: Text.PlainText
                    text: root.radioGlyph
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                  }
                }

                Item {
                  id: playerNames
                  anchors.left: playerIcon.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: playButton.left
                  anchors.rightMargin: Style.space(8)
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  clip: true

                  Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)
                    visible: root.playingName !== ""

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      wrapMode: Text.Wrap
                      maximumLineCount: 2
                      elide: Text.ElideRight
                      text: root.playingStation && root.playingStation.name ? root.playingStation.name : root.playingName
                      color: root.playingTitleColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                    }

                    Text {
                      width: parent.width
                      visible: root.playingRegion !== ""
                      height: visible ? implicitHeight : 0
                      textFormat: Text.PlainText
                      wrapMode: Text.NoWrap
                      elide: Text.ElideRight
                      text: root.playingRegion
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.playingName === ""
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: strings.t("panel.playerIdle")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                  }
                }

                BorderSurface {
                  id: playButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  readonly property bool playable: root.playerActive || (root.selectedIndex >= 0 && root.selectedIndex < root.filtered.length)
                  readonly property string glyph: (!root.playerActive || root.paused) ? root.playGlyph : root.pauseGlyph
                  height: Math.min(playerFace.height, nameFilter.implicitHeight)
                  width: height
                  radius: width / 2
                  color: !playable ? Qt.alpha(Commons.Color.accent, 0.4)
                    : playMouse.pressed ? Qt.darker(Commons.Color.accent, 1.25)
                    : playMouse.containsMouse ? Qt.darker(Commons.Color.accent, 1.12)
                    : Commons.Color.accent
                  borderSpec: Border.none()

                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: playButton.glyph
                    color: playButton.playable ? "#000000" : Qt.rgba(0, 0, 0, 0.45)
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(playButton.height * 0.46)
                  }

                  MouseArea {
                    id: playMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: playButton.playable
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.togglePause()
                  }

                  PanelToolTip {
                    visible: playMouse.containsMouse
                    text: (!root.playerActive || root.paused) ? strings.t("panel.play") : strings.t("panel.pause")
                    fontFamily: root.fontFamily
                  }
                }
              }
            }

            Column {
              id: favColumn
              anchors.top: playerCard.bottom
              anchors.topMargin: Style.space(12)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(8)
              clip: true

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("panel.favorites")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: root.favorites.length === 0
          textFormat: Text.PlainText
          text: strings.t("panel.favoritesEmpty")
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: favoriteList
          width: parent.width
          visible: root.shownFavorites.length > 0
          height: visible ? Math.max(0, favColumn.height - y) : 0
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          spacing: Style.space(2)
          model: root.shownFavorites
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: CursorSurface {
            id: savedRow
            required property var modelData
            required property int index
            width: favoriteList.width
            height: root.favoriteEntryHeight
            implicitHeight: root.favoriteEntryHeight
            hasCursor: false
            current: modelData.id === root.playingId
            foreground: root.foreground
            fill: root.hoverFill
            currentFill: root.selectedFill

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleStation(savedRow.modelData)
            }

            Item {
              id: savedBody
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(4)
              implicitHeight: Math.max(savedIcon.implicitHeight, savedNames.implicitHeight, savedStar.implicitHeight)

              Item {
                id: savedIcon
                width: Style.space(28)
                height: Style.space(28)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: width
                implicitHeight: height

                Loader {
                  id: savedLogo
                  anchors.fill: parent
                  active: savedRow.modelData.icon !== ""
                  sourceComponent: SizedImage {
                    anchors.fill: parent
                    asynchronous: true
                    url: savedRow.modelData.icon
                  }
                  readonly property bool shown: item && item.status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  visible: !savedLogo.shown
                  textFormat: Text.PlainText
                  text: root.radioGlyph
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }
              }

              Column {
                id: savedNames
                anchors.left: savedIcon.right
                anchors.leftMargin: Style.space(8)
                anchors.right: savedStar.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: savedRow.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  visible: savedRow.modelData.region !== ""
                  height: visible ? implicitHeight : 0
                  text: savedRow.modelData.region
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              PanelActionButton {
                id: savedStar
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                z: 1
                iconText: root.starOnGlyph
                tooltipText: strings.t("panel.favoriteRemove")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.toggleFavorite(savedRow.modelData)
              }
            }
          }
        }
            }
          }

          Column {
            id: stationColumn
            width: parent.width - leftCol.width - columns.spacing
            height: parent.height
            spacing: Style.space(8)

            FilterField {
              id: nameFilter
              width: parent.width
              placeholder: strings.t("panel.filter")
              onEdited: function(value) { root.query = value }
            }

            FilterField {
              id: regionFilter
              width: parent.width
              placeholder: strings.t("panel.region")
              onEdited: function(value) { root.regionQuery = value }
            }

            Text {
              width: parent.width
              visible: root.statusText !== ""
              textFormat: Text.PlainText
              text: root.statusText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

        ListView {
          id: stationList
          width: parent.width
          height: Math.max(0, parent.height - y)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          maximumFlickVelocity: 7500
          flickDeceleration: 700
          spacing: Style.space(2)
          model: root.filtered
          currentIndex: root.selectedIndex
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          // A notch or a trackpad tick moves about three times as far as the
          // shell default, so a long station list does not crawl.
          WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(event) {
              var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 8
              if (dy === 0)
                return
              root.noteWheelScroll()
              var maxY = Math.max(0, stationList.contentHeight - stationList.height)
              stationList.contentY = Math.max(0, Math.min(maxY, stationList.contentY - dy * 3.4))
              event.accepted = true
            }
          }

          delegate: CursorSurface {
            id: row
            required property var modelData
            required property int index
            width: stationList.width
            height: root.stationEntryHeight
            implicitHeight: root.stationEntryHeight
            hasCursor: root.selectedIndex === index
            current: modelData.id === root.playingId
            foreground: root.foreground
            fill: root.hoverFill
            currentFill: root.selectedFill

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              // Scrolling moves rows under a still pointer. That is not a
              // mouse move, so it must not steal the keyboard highlight.
              onPositionChanged: function(mouse) {
                if (root.wheelScrolling) return
                if (pointerGate.moved(row, mouse)) root.selectedIndex = row.index
              }
              onClicked: root.toggleStation(row.modelData)
            }

            Item {
              id: rowBody
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(4)
              implicitHeight: Math.max(iconBox.implicitHeight, names.implicitHeight, starButton.implicitHeight)

              Item {
                id: iconBox
                width: Style.space(28)
                height: Style.space(28)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: width
                implicitHeight: height

                Loader {
                  id: logo
                  anchors.fill: parent
                  active: row.modelData.icon !== ""
                  sourceComponent: SizedImage {
                    anchors.fill: parent
                    asynchronous: true
                    url: row.modelData.icon
                  }
                  readonly property bool shown: item && item.status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  visible: !logo.shown
                  textFormat: Text.PlainText
                  text: root.radioGlyph
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }
              }

              Column {
                id: names
                anchors.left: iconBox.right
                anchors.leftMargin: Style.space(8)
                anchors.right: starButton.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: row.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  visible: row.modelData.region !== ""
                  height: visible ? implicitHeight : 0
                  text: row.modelData.region
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              PanelActionButton {
                id: starButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                z: 1
                iconText: root.isFavorite(row.modelData.id) ? root.starOnGlyph : root.starOffGlyph
                tooltipText: root.isFavorite(row.modelData.id) ? strings.t("panel.favoriteRemove") : strings.t("panel.favoriteAdd")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.toggleFavorite(row.modelData)
              }
            }
          }
        }
          }
        }
      }
    }
  }
}
