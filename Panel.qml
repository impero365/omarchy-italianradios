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
// than a day. A click plays the station with mpv on the default audio device.
Panel {
  id: root
  moduleName: "mattia.radio"
  ipcTarget: "mattia.radio"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string radioGlyph: "󰐹"
  readonly property string cacheDir: {
    var home = String(Quickshell.env("HOME") || "")
    if (!home || /[\u0000-\u001F]/.test(home)) return ""
    return home + "/.cache/mattia.radio"
  }
  readonly property string cachePath: cacheDir !== "" ? cacheDir + "/stations.json" : ""
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
  property int selectedIndex: 0
  property bool fetchBusy: false
  property bool loadFailed: false
  property int hostIndex: 0
  property bool fetchHandled: false
  property string pendingCache: ""

  property string playingId: ""
  property string playingName: ""
  property var pendingCommand: null
  property bool stopRequested: false
  property bool playbackError: false
  property bool mpvOk: true
  property bool mpvChecked: false

  readonly property var filtered: Model.filterStations(stations, query, regionQuery)
  readonly property string statusText: {
    if (fetchBusy && stations.length === 0) return strings.t("panel.loading")
    if (loadFailed && stations.length === 0) return strings.t("panel.failed")
    if (stations.length > 0 && filtered.length === 0) return strings.t("panel.none")
    if (playbackError && !mpvOk) return strings.t("panel.noPlayer")
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
    if (event.key === Qt.Key_Down) {
      moveCursor(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      moveCursor(-1)
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
    var count = filtered.length
    if (count === 0) {
      selectedIndex = -1
      return
    }
    if (selectedIndex < 0) selectedIndex = delta > 0 ? 0 : count - 1
    else selectedIndex = Math.max(0, Math.min(count - 1, selectedIndex + delta))
  }

  function activateCursor() {
    if (selectedIndex < 0 || selectedIndex >= filtered.length) return
    toggleStation(filtered[selectedIndex])
  }

  function toggleStation(station) {
    if (!station) return
    if (station.id === playingId && player.running) {
      stopPlayback()
      return
    }
    var command = Model.playerCommand(station.stream, station.name)
    if (!command.length || (mpvChecked && !mpvOk)) {
      playbackError = true
      return
    }
    playbackError = false
    pendingCommand = { command: command, id: station.id, name: station.name }
    if (player.running) {
      stopRequested = true
      player.running = false
    } else {
      startPending()
    }
  }

  function startPending() {
    var next = pendingCommand
    pendingCommand = null
    if (!next) return
    player.command = next.command
    playingId = next.id
    playingName = next.name
    stopRequested = false
    player.running = true
  }

  function stopPlayback() {
    pendingCommand = null
    playingId = ""
    playingName = ""
    playbackError = false
    if (!player.running) return
    stopRequested = true
    player.running = false
  }

  onQueryChanged: selectedIndex = filtered.length > 0 ? 0 : -1
  onRegionQueryChanged: selectedIndex = filtered.length > 0 ? 0 : -1
  onFilteredChanged: {
    if (selectedIndex >= filtered.length) selectedIndex = filtered.length > 0 ? 0 : -1
  }
  onOpenedChanged: {
    if (!opened) return
    panel.ensureContent()
    refreshIfStale()
    if (!mpvChecked && !mpvCheck.running) mpvCheck.running = true
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

  Process {
    id: mpvCheck
    command: ["mpv", "--version"]
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.mpvChecked = true
      root.mpvOk = code === 0
    }
  }

  Process {
    id: player
    onExited: function(code) {
      if (root.pendingCommand) {
        root.startPending()
        return
      }
      if (root.stopRequested) {
        root.stopRequested = false
        return
      }
      root.playingId = ""
      root.playingName = ""
      if (code !== 0) root.playbackError = true
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.radioGlyph
    tooltipText: root.tooltipText
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(panel.loadedContent ? panel.loadedContent.implicitHeight : Style.space(480))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias filterField: filterField
      anchors.fill: parent
      implicitHeight: Style.space(480)
      blocked: filterField.activeFocus || regionField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
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

        TextField {
          id: filterField
          width: parent.width
          placeholderText: strings.t("panel.filter")
          foreground: root.foreground
          accent: Commons.Color.accent
          font.family: root.fontFamily
          onTextChanged: root.query = text
          Keys.onPressed: function(event) { root.handleFieldKey(event) }
        }

        TextField {
          id: regionField
          width: parent.width
          placeholderText: strings.t("panel.region")
          foreground: root.foreground
          accent: Commons.Color.accent
          font.family: root.fontFamily
          onTextChanged: root.regionQuery = text
          Keys.onPressed: function(event) { root.handleFieldKey(event) }
        }

        Row {
          width: parent.width
          visible: root.playingName !== ""
          spacing: Style.space(8)

          Text {
            width: Math.max(0, parent.width - stopButton.width - parent.spacing)
            height: stopButton.implicitHeight
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: strings.t("panel.playing").arg(root.playingName)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          PanelActionButton {
            id: stopButton
            iconText: "󰓛"
            tooltipText: strings.t("panel.stop")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.stopPlayback()
          }
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
          spacing: Style.space(2)
          model: root.filtered
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

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
              onContainsMouseChanged: if (containsMouse) root.selectedIndex = row.index
              onClicked: root.toggleStation(row.modelData)
            }

            Item {
              id: rowBody
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              implicitHeight: Math.max(iconBox.implicitHeight, names.implicitHeight)

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
                anchors.right: parent.right
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
            }
          }
        }
      }
    }
  }
}
