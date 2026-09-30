import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Downloads widget: bar icon + click-to-open popup listing files Telegram
// Desktop is currently downloading, with a real percentage when known.
//
// Telegram exposes no download API and writes straight into the final
// target path with no temp extension, so bin/scan_downloads.py infers active
// downloads from /proc (O_WRONLY fds outside Telegram's own data dir) —
// giving bytes-so-far and a speed derived from size deltas between polls,
// but no total size. For a real percentage, bin/lookup_sizes.py finds each
// file's total via Telegram's own global search (matching by filename) and
// caches it to disk; this panel just reads that cache. Until a file's total
// is known (or if Telegram login hasn't been set up — see
// bin/telegram_login.py), its row falls back to a pulsing dot instead of a
// percentage.
Panel {
  id: root
  moduleName: "home.downloads"
  manageIpc: false

  readonly property string scriptPath: "/home/pc/.config/omarchy/plugins/home.downloads/bin/scan_downloads.py"
  readonly property string lookupScriptPath: "/home/pc/.config/omarchy/plugins/home.downloads/bin/lookup_sizes.py"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  property var downloads: []
  property bool telegramRunning: true
  property var snapshot: ({})
  property var sizeCache: ({})
  property real lastLookupAttempt: 0
  property string lookupStatus: ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!scanProc.running) {
      scanProc.command = ["python3", root.scriptPath]
      scanProc.running = true
    }
  }

  // Kicks off a size lookup for any downloading file whose total isn't
  // cached yet. Rate-limited client-side so a stuck "not logged in"/
  // "not configured" result doesn't reconnect to Telegram every 3s tick.
  function maybeLookupSizes() {
    if (lookupProc.running || Date.now() - root.lastLookupAttempt < 15000) return
    var names = []
    for (var i = 0; i < root.downloads.length; i++) {
      var name = root.downloads[i].name
      if (root.downloads[i].totalSize == null && names.indexOf(name) === -1) names.push(name)
    }
    if (names.length === 0) return
    root.lastLookupAttempt = Date.now()
    lookupProc.command = ["python3", root.lookupScriptPath].concat(names)
    lookupProc.running = true
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      id: scanStdout
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          root.telegramRunning = !!parsed.telegramRunning
          var merged = Model.mergeSnapshot(root.snapshot, parsed.downloads || [], Date.now(), root.sizeCache)
          root.downloads = merged.rows
          root.snapshot = merged.snapshot
          root.maybeLookupSizes()
        } catch (e) { /* leave last-known state on a bad tick */ }
      }
    }
  }

  // lookup_sizes.py writes straight to sizeCacheFile's path; that FileView's
  // watchChanges picks up the new totals from there. This stdout is only
  // read for its {"error": ...} case, to surface a setup hint in the panel.
  Process {
    id: lookupProc
    stdout: StdioCollector {
      id: lookupStdout
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "").trim() || "{}")
          root.lookupStatus = parsed.error || ""
        } catch (e) { /* ignore */ }
        sizeCacheFile.reload()
      }
    }
  }

  FileView {
    id: sizeCacheFile
    path: Quickshell.env("HOME") + "/.local/share/omarchy-downloads/sizes-cache.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.sizeCache = Model.parseSizeCache(text())
    onLoadFailed: root.sizeCache = {}
  }

  Component.onCompleted: root.refresh()

  // Not gated by root.opened — the bar badge should reflect live download
  // count even with the panel closed, and the script only reads /proc.
  Timer {
    interval: 3000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Icon {
        anchors.centerIn: parent
        iconSize: Style.space(11)
        color: root.foreground
        activeCount: root.downloads.length
      }
    }
    onPressed: function (buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(420))

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: flick.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Downloads"
          meta: root.downloads.length + " active"
          foreground: root.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.downloads
            delegate: DownloadRow {
              required property var modelData
              width: parent.width
              download: modelData
              foreground: root.foreground
            }
          }

          Text {
            visible: root.downloads.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: root.telegramRunning ? "No active downloads." : "Telegram isn't running."
            wrapMode: Text.WordWrap
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }
        }

        // Setup hint: only shown once a lookup has actually been attempted
        // and failed, so a fresh install isn't nagging before the user has
        // even had a chance to run telegram_login.py.
        Text {
          visible: root.lookupStatus !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.lookupStatus === "not logged in"
            ? "Run telegram_login.py once to unlock real percentages."
            : "Add your api_id/api_hash to telegram.json for real percentages."
          wrapMode: Text.WordWrap
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // One in-progress download: a big percentage (once lookup_sizes.py has
  // found the total) or a pulsing dot in its place, plus filename and a
  // bytes-so-far/total/speed/ETA line.
  component DownloadRow: BorderSurface {
    id: downloadRow
    property var download: null
    property color foreground: Color.foreground
    readonly property bool hasPercent: !!download && download.percent !== null

    implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX
    radius: Style.cornerRadius
    color: "transparent"
    borderSpec: Border.none()

    Row {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.spacing.sm

      Item {
        id: stat
        width: Style.space(56)
        height: Math.max(percentText.implicitHeight, dot.height)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: percentText
          visible: downloadRow.hasPercent
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: downloadRow.hasPercent ? (downloadRow.download.percent + "%") : ""
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }

        Rectangle {
          id: dot
          visible: !downloadRow.hasPercent
          width: Style.space(8)
          height: width
          radius: width / 2
          color: Color.accent
          anchors.centerIn: parent

          SequentialAnimation on opacity {
            running: dot.visible
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 0.3; duration: 700 }
            NumberAnimation { from: 0.3; to: 1.0; duration: 700 }
          }
        }
      }

      Column {
        width: parent.width - stat.width - parent.spacing
        spacing: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: downloadRow.download ? downloadRow.download.name : ""
          color: downloadRow.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: {
            if (!downloadRow.download) return ""
            var d = downloadRow.download
            var size = d.totalSize ? (Model.formatBytes(d.size) + " / " + Model.formatBytes(d.totalSize)) : Model.formatBytes(d.size)
            var speed = Model.formatSpeed(d.bytesPerSec)
            return speed ? (size + "  ·  " + speed) : size
          }
          color: Qt.darker(downloadRow.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          readonly property string eta: downloadRow.download ? Model.formatEta(downloadRow.download) : ""
          visible: eta !== ""
          textFormat: Text.PlainText
          width: parent.width
          text: eta + " left"
          color: Qt.darker(downloadRow.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
