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
  readonly property color doneColor: "#3ea34d"
  property var downloads: []
  property var finished: []
  property bool telegramRunning: true
  property bool hasLoadedOnce: false
  property var snapshot: ({})
  property var sizeCache: ({})
  property real lastLookupAttempt: 0
  property string lookupStatus: ""
  readonly property real combinedSpeedBps: Model.totalSpeed(root.downloads)

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

          // Only treat a vanished path as "finished" while Telegram is
          // confirmed still running - if Telegram itself quit, every path
          // vanishes at once and that's not a completion, just the app closing.
          if (root.telegramRunning) {
            var justFinished = Model.diffFinished(root.snapshot, parsed.downloads || [])
            if (justFinished.length > 0) {
              var now = Date.now()
              var updatedFinished = root.finished.slice()
              for (var i = 0; i < justFinished.length; i++) {
                updatedFinished.push({
                  path: justFinished[i].path, name: justFinished[i].name,
                  size: justFinished[i].size, finishedAt: now
                })
                Quickshell.execDetached([
                  "omarchy-notification-send", "--app-name", "Downloads", "-g", "󰇚",
                  justFinished[i].name, "Finished downloading"
                ])
              }
              root.finished = updatedFinished
            }
          }

          var merged = Model.mergeSnapshot(root.snapshot, parsed.downloads || [], Date.now(), root.sizeCache)
          root.downloads = merged.rows
          root.snapshot = merged.snapshot
          root.hasLoadedOnce = true
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

  // Prunes "just finished" rows ~4s after they complete (see scanProc above)
  // so a fast download doesn't just flicker away unnoticed.
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      var kept = root.finished.filter(function (f) { return now - f.finishedAt < 4000 })
      if (kept.length !== root.finished.length) root.finished = kept
    }
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

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
          meta: root.downloads.length + " active" + (root.combinedSpeedBps > 0
            ? ("  ·  " + Model.formatSpeed(root.combinedSpeedBps) + " combined")
            : "")
          foreground: root.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.finished
            delegate: FinishedRow {
              required property var modelData
              width: parent.width
              download: modelData
              foreground: root.foreground
              doneColor: root.doneColor
            }
          }

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
            visible: !root.hasLoadedOnce
            width: parent.width
            textFormat: Text.PlainText
            text: "Checking Telegram…"
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: root.hasLoadedOnce && root.downloads.length === 0 && root.finished.length === 0
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
  // bytes-so-far/total/speed/ETA line. Click reveals the file's folder.
  component DownloadRow: BorderSurface {
    id: downloadRow
    property var download: null
    property color foreground: Color.foreground
    readonly property bool hasPercent: !!download && download.percent !== null

    implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX
    radius: Style.cornerRadius
    color: mouse.containsMouse ? Style.controlFill(false, true, downloadRow.foreground, Color.accent) : "transparent"
    borderSpec: Border.none()

    Behavior on color { ColorAnimation { duration: 100 } }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (!downloadRow.download) return
        var dir = downloadRow.download.path.substring(0, downloadRow.download.path.lastIndexOf("/"))
        Quickshell.execDetached(["xdg-open", dir])
      }
    }

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

        // Percent and dot share this same centered spot and cross-fade
        // between each other (rather than snapping via `visible`) for when
        // a file's total size arrives mid-download. The pulse animation
        // lives on the dot's own opacity, one level in, so it doesn't fight
        // the crossfade's Behavior for control of the same property.
        Text {
          id: percentText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: downloadRow.hasPercent ? (downloadRow.download.percent + "%") : ""
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
          font.bold: true
          opacity: downloadRow.hasPercent ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 200 } }
        }

        Item {
          id: dotFade
          anchors.centerIn: parent
          width: Style.space(8)
          height: width
          opacity: downloadRow.hasPercent ? 0 : 1
          Behavior on opacity { NumberAnimation { duration: 200 } }

          Rectangle {
            id: dot
            anchors.fill: parent
            radius: width / 2
            color: Color.accent

            SequentialAnimation on opacity {
              running: !downloadRow.hasPercent
              loops: Animation.Infinite
              NumberAnimation { from: 1.0; to: 0.3; duration: 700 }
              NumberAnimation { from: 0.3; to: 1.0; duration: 700 }
            }
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

        // Height stays reserved either way so a file's total arriving
        // mid-download (dis/appearing fill) never shifts the row's height -
        // only its own opacity/width animate.
        Item {
          width: parent.width
          height: Style.space(3)
          opacity: downloadRow.hasPercent ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 200 } }

          Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Qt.darker(downloadRow.foreground, 3.0)
          }

          Rectangle {
            height: parent.height
            radius: height / 2
            color: Color.accent
            width: downloadRow.hasPercent ? parent.width * (downloadRow.download.percent / 100) : 0
            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
          }
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

  // A download that just completed: shown for ~4s (see the prune Timer
  // above) instead of vanishing the instant its fd closes, so a fast
  // download doesn't flicker away unnoticed. Same layout as DownloadRow's
  // stat/name/detail columns, swapping the percent/dot for a checkmark and
  // the speed/ETA line for a plain final size.
  component FinishedRow: BorderSurface {
    id: finishedRow
    property var download: null
    property color foreground: Color.foreground
    property color doneColor: "#3ea34d"

    implicitHeight: finishedContent.implicitHeight + Style.spacing.rowPaddingX
    radius: Style.cornerRadius
    // Tinted with doneColor rather than Color.accent on hover, so a finished
    // row reads as distinctly "done" even before its checkmark registers.
    color: finishedMouse.containsMouse ? Style.controlFill(false, true, finishedRow.foreground, finishedRow.doneColor) : "transparent"
    borderSpec: Border.none()

    Behavior on color { ColorAnimation { duration: 100 } }

    MouseArea {
      id: finishedMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (!finishedRow.download) return
        var dir = finishedRow.download.path.substring(0, finishedRow.download.path.lastIndexOf("/"))
        Quickshell.execDetached(["xdg-open", dir])
      }
    }

    Row {
      id: finishedContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.spacing.sm

      Item {
        id: finishedStat
        width: Style.space(56)
        height: checkText.implicitHeight
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: checkText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "✓"
          color: finishedRow.doneColor
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }
      }

      Column {
        width: parent.width - finishedStat.width - parent.spacing
        spacing: Style.spacing.xs
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: finishedRow.download ? finishedRow.download.name : ""
          color: finishedRow.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: finishedRow.download ? ("Finished · " + Model.formatBytes(finishedRow.download.size)) : ""
          color: finishedRow.doneColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
