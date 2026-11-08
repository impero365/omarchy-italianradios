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
// than a day. The left column is the player and favourites. The right column
// is the filters and the station list. A click asks radio-player to play the
// stream in one sandboxed mpv. The player pauses and resumes that stream.
Panel {
  id: root
  moduleName: "mattia.radio"
  ipcTarget: "mattia.radio"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

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
  readonly property string favouritesPath: stateDir !== "" ? stateDir + "/favourites.json" : ""
  readonly property string playerPath: {
    var text = Qt.resolvedUrl("radio-player").toString()
    if (text.indexOf("file://") !== 0) return ""
    var path = decodeURIComponent(text.slice(7))
    if (path.charAt(0) !== "/" || path.indexOf("..") !== -1 || /[\u0000-\u001F]/.test(path)) return ""
    return path
  }
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(foreground, Commons.Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(foreground, Commons.Color.accent) : "transparent"

  property var stations: []
  property double fetchedAt: 0
  property bool cacheReady: false
  property string query: ""
  property string regionQuery: ""
  property var favourites: []
  property bool favouritesReady: false
  property bool favouritesDirty: false
  property string pendingFavourites: ""
  readonly property var favouriteMark: {
    var mark = {}
    var rows = favourites
    for (var i = 0; i < rows.length; i++) mark[rows[i].id] = true
    return mark
  }
  readonly property var shownFavourites: Model.resolveFavourites(favourites, stations)
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

  function isFavourite(id) {
    return favouriteMark[id] === true
  }

  function toggleFavourite(station) {
    favouritesDirty = true
    favourites = Model.toggleFavourite(favourites, station)
    saveFavourites()
  }

  function saveFavourites() {
    if (favouritesPath === "") return
    pendingFavourites = Model.favouritesPayload(favourites)
    if (!stateMkdir.running) stateMkdir.running = true
  }

  function syncFavouriteSnapshots() {
    if (!favouritesReady || favourites.length === 0) return
    var next = Model.resolveFavourites(favourites, stations)
    if (Model.favouritesPayload(next) === Model.favouritesPayload(favourites)) return
    favourites = next
    saveFavourites()
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
    if (status.id) playingId = status.id
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

  function toggleStation(station) {
    if (!station) return
    if (station.id === playingId && playerActive) {
      togglePause()
      return
    }
    if (!Model.streamUrl(station.stream)) {
      playbackError = true
      playerReason = "playback"
      return
    }
    playbackError = false
    playerReason = ""
    paused = false
    playerActive = true
    playingId = station.id
    playingName = station.name
    runPlayer([playerPath, "play", station.id, station.name, station.stream])
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
  onStationsChanged: syncFavouriteSnapshots()
  onOpenedChanged: {
    if (!opened) return
    panel.ensureContent()
    refreshIfStale()
    Qt.callLater(refreshStatus)
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
    id: favouritesFile
    path: root.favouritesPath
    printErrors: false
    watchChanges: false
    onLoaded: {
      if (!root.favouritesDirty) root.favourites = Model.parseFavourites(text())
      root.favouritesReady = true
      root.syncFavouriteSnapshots()
    }
    onLoadFailed: {
      root.favouritesReady = true
      root.syncFavouriteSnapshots()
    }
  }

  Process {
    id: stateMkdir
    command: ["mkdir", "-p", root.stateDir]
    onExited: function(code) {
      if (code !== 0 || root.pendingFavourites === "" || root.favouritesPath === "") return
      favouritesFile.setText(root.pendingFavourites)
      root.pendingFavourites = ""
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
      playerAction.queued = null
      root.applyPlayerStatus(playerAction.output, code !== 0)
      if (queued) root.runPlayer(queued)
    }
  }

  Process {
    id: statusProc
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: statusProc.output = text
    }
    onExited: function(code) {
      if (!playerAction.running) root.applyPlayerStatus(statusProc.output, code !== 0)
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
              implicitHeight: playerRow.implicitHeight + Style.space(16)
              height: implicitHeight
              radius: Style.cornerRadius
              color: "transparent"
              borderSpec: Border.controlSpec("normal", root.foreground, Commons.Color.accent)
              padding: Style.space(8)

              Row {
                id: playerRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: playerCard.contentLeftInset
                anchors.rightMargin: playerCard.contentRightInset
                spacing: Style.space(8)

                Text {
                  width: Math.max(0, parent.width - playButton.width - parent.spacing)
                  wrapMode: Text.WordWrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.playingName === ""
                    ? strings.t("panel.playerIdle")
                    : (root.paused ? strings.t("panel.paused") : strings.t("panel.playing")).arg(root.playingName)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                PanelActionButton {
                  id: playButton
                  enabled: root.playerActive || (root.selectedIndex >= 0 && root.selectedIndex < root.filtered.length)
                  iconText: (!root.playerActive || root.paused) ? root.playGlyph : root.pauseGlyph
                  tooltipText: (!root.playerActive || root.paused) ? strings.t("panel.play") : strings.t("panel.pause")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.togglePause()
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
          text: strings.t("panel.favourites")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: root.favourites.length === 0
          textFormat: Text.PlainText
          text: strings.t("panel.favouritesEmpty")
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: favouriteList
          width: parent.width
          visible: root.shownFavourites.length > 0
          height: visible ? Math.max(0, favColumn.height - y) : 0
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          spacing: Style.space(2)
          model: root.shownFavourites
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: CursorSurface {
            id: savedRow
            required property var modelData
            required property int index
            width: favouriteList.width
            implicitHeight: savedBody.implicitHeight + Style.space(8)
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
                  text: savedRow.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: savedRow.modelData.region !== ""
                  textFormat: Text.PlainText
                  text: savedRow.modelData.region
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              PanelActionButton {
                id: savedStar
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                z: 1
                iconText: root.starOnGlyph
                tooltipText: strings.t("panel.favouriteRemove")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.toggleFavourite(savedRow.modelData)
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
            implicitHeight: rowBody.implicitHeight + Style.space(8)
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
                  text: row.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: row.modelData.region !== ""
                  height: visible ? implicitHeight : 0
                  textFormat: Text.PlainText
                  text: row.modelData.region
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              PanelActionButton {
                id: starButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                z: 1
                iconText: root.isFavourite(row.modelData.id) ? root.starOnGlyph : root.starOffGlyph
                tooltipText: root.isFavourite(row.modelData.id) ? strings.t("panel.favouriteRemove") : strings.t("panel.favouriteAdd")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.toggleFavourite(row.modelData)
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
