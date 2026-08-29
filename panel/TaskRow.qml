pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Format.js" as Format

// One task: a dense summary line with its actions, expandable to the run
// history. Everything rendered comes from `panel.tasks[i]` (list --json) and,
// while expanded, this row's own `log <task> --json` process.
Item {
  id: row

  required property var panel
  required property var task

  readonly property string name: task.name
  readonly property var lastRun: task.last_run || null
  readonly property string lastStatus: lastRun ? String(lastRun.status) : ""
  readonly property bool running: lastStatus === "running"
  readonly property bool enabled: task.enabled === true
  readonly property bool backlog: task.backlog_since !== null && task.backlog_since !== undefined
  readonly property bool expanded: panel.isExpanded(name)
  readonly property bool anyBusy: panel.actionBusy
  readonly property bool armed: panel.armedRemove === name
  readonly property string error: panel.rowErrors[name] || ""
  readonly property bool canResume: lastRun !== null && !running && lastRun.session_available === true

  readonly property color fg: panel.fg
  readonly property color muted: panel.muted
  readonly property color accent: panel.accent
  readonly property color urgent: panel.urgent
  readonly property string fontFamily: panel.fontFamily
  readonly property int capSize: Style.font.caption
  readonly property int bodySize: Style.font.bodySmall

  property var history: []

  implicitHeight: body.implicitHeight + Style.space(6)

  function act(args) { panel.runAction(name, args) }

  function resumeTooltip(run) {
    if (!run) return "No run yet"
    if (run.status === "running") return "Still running"
    if (run.session_available !== true) return "Session no longer available"
    return "Resume run #" + run.id + " in a terminal"
  }

  // History is fetched only while the panel is open and this row is
  // expanded, and again on every refresh of the task list.
  function loadHistory() {
    if (!row.expanded || !row.panel.opened || historyProc.running) return
    historyProc.running = true
  }
  onExpandedChanged: loadHistory()
  Connections {
    target: row.panel
    function onTasksChanged() { row.loadHistory() }
    function onOpenedChanged() { row.loadHistory() }
  }

  Process {
    id: historyProc
    command: [row.panel.cliPath, "log", row.name, "--json"]
    stdout: StdioCollector { id: historyOut; waitForEnd: true }
    onExited: function (exitCode) {
      var list = []
      try { list = JSON.parse(String(historyOut.text || "[]")) } catch (e) { list = [] }
      row.history = Array.isArray(list) ? list : []
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: row.expanded ? Util.alpha(row.fg, 0.06)
         : row.lastStatus === "failure" || row.backlog ? Util.alpha(row.urgent, 0.10) : "transparent"
    border.width: row.expanded ? 1 : 0
    border.color: Util.alpha(row.fg, 0.15)
  }

  ColumnLayout {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(3)
    spacing: Style.space(4)

    // ------------------------------------------------------------ summary line
    RowLayout {
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(4)
      spacing: Style.space(6)

      ToggleSwitch {
        checked: row.enabled
        busy: row.anyBusy
        trackHeight: Style.space(14)
        foreground: row.fg
        accent: row.accent
        onToggled: row.act([row.enabled ? "disable" : "enable", row.name])
      }

      Text {
        Layout.preferredWidth: Style.space(130)
        text: row.name
        color: nameArea.containsMouse ? row.accent : row.fg
        opacity: row.enabled ? 1 : 0.6
        font.family: row.fontFamily
        font.pixelSize: row.bodySize
        font.bold: true
        elide: Text.ElideMiddle
        MouseArea {
          id: nameArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: row.panel.toggleExpanded(row.name)
        }
      }

      Text {
        Layout.fillWidth: true
        text: row.task.schedule === "manual" ? "manual"
          : row.task.schedule + (row.enabled ? "  →  " + row.task.next_due_text : "")
        color: row.muted
        font.family: row.fontFamily
        font.pixelSize: row.capSize
        elide: Text.ElideRight
      }

      // last-run chip
      Rectangle {
        visible: row.lastRun !== null
        implicitWidth: chip.implicitWidth + Style.space(8)
        implicitHeight: chip.implicitHeight + Style.space(2)
        radius: height / 2
        readonly property color tone: Format.statusColor(row.lastStatus, row.accent, row.urgent, row.muted)
        color: Util.alpha(tone, 0.18)
        border.width: 1
        border.color: tone
        RowLayout {
          id: chip
          anchors.centerIn: parent
          spacing: Style.space(3)
          Text {
            visible: row.running
            text: "󰑐"
            color: row.accent
            font.family: row.fontFamily
            font.pixelSize: row.capSize
            RotationAnimation on rotation { from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: row.running }
          }
          Text {
            text: !row.lastRun ? ""
              : row.running ? "running since " + Format.clock(row.lastRun.start)
              : row.lastStatus + " " + Format.clock(row.lastRun.end) + " · " + row.lastRun.trigger
            color: row.fg
            font.family: row.fontFamily
            font.pixelSize: row.capSize
          }
        }
      }

      // kept (unmerged) worktrees awaiting review; pruned on panel open once merged
      Text {
        visible: Number(row.task.worktrees || 0) > 0
        text: row.task.worktrees + " worktree" + (row.task.worktrees === 1 ? "" : "s")
        color: row.muted
        font.family: row.fontFamily
        font.pixelSize: row.capSize
        font.italic: true
      }

      // backlog pill
      RowLayout {
        visible: row.backlog
        spacing: Style.space(2)
        Text {
          text: "missed since " + Format.clock(row.task.backlog_since)
          color: row.urgent
          font.family: row.fontFamily
          font.pixelSize: row.capSize
        }
        Button { text: "Run"; fontSize: row.capSize; enabled: !row.anyBusy; tooltipText: "Run the backlog once (backlog-catchup)"; onClicked: row.act(["backlog", "run", row.name]) }
        Button { text: "Skip"; fontSize: row.capSize; enabled: !row.anyBusy; tooltipText: "Skip the missed runs"; onClicked: row.act(["backlog", "skip", row.name]) }
      }

      PanelActionButton {
        iconText: "󰐊"
        size: Style.space(20)
        fontSize: row.capSize
        foreground: row.muted
        hoverColor: row.accent
        enabled: !row.running
        tooltipText: row.running ? "Already running" : "Trigger now"
        onClicked: row.panel.trigger(row.name)
      }
      PanelActionButton {
        iconText: "󰆍"
        size: Style.space(20)
        fontSize: row.capSize
        foreground: row.muted
        hoverColor: row.accent
        enabled: row.canResume && !row.anyBusy
        tooltipText: row.resumeTooltip(row.lastRun)
        onClicked: row.act(["resume", String(row.lastRun.id), "--terminal"])
      }
      Button {
        iconText: "󰆴"
        text: row.armed ? "Remove?" : ""
        iconSize: row.capSize
        fontSize: row.capSize
        foreground: row.armed ? row.urgent : row.muted
        horizontalPadding: Style.space(4)
        verticalPadding: Style.space(2)
        enabled: !row.anyBusy
        tooltipText: row.armed ? "Click again to remove" : "Remove task (click twice)"
        onClicked: row.panel.removeClicked(row.name)
      }
    }

    Text {
      visible: row.error !== ""
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(6)
      text: "✗ " + row.error
      color: row.urgent
      wrapMode: Text.Wrap
      font.family: row.fontFamily
      font.pixelSize: row.capSize
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: row.panel.setMap("rowErrors", row.name, undefined) }
    }

    // --------------------------------------------------------------- expanded
    ColumnLayout {
      visible: row.expanded
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(6)
      Layout.rightMargin: Style.space(6)
      Layout.bottomMargin: Style.space(4)
      spacing: Style.space(2)

      Text {
        Layout.fillWidth: true
        text: row.task.cwd + (row.task.worktree ? "  ·  worktree" : "  ·  no worktree")
          + (row.task.permission_mode ? "  ·  " + row.task.permission_mode : "")
        color: row.muted
        font.family: row.fontFamily
        font.pixelSize: row.capSize
        elide: Text.ElideMiddle
      }

      // Prompts can be pages long: wrapped, capped at ~10 lines, scrollable.
      Flickable {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(promptText.implicitHeight, promptText.font.pixelSize * 1.4 * 10)
        contentHeight: promptText.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Text {
          id: promptText
          width: parent.width
          text: row.task.prompt
          color: row.fg
          opacity: 0.8
          wrapMode: Text.Wrap
          font.family: row.fontFamily
          font.pixelSize: row.capSize
        }
      }
      Text {
        visible: row.history.length === 0
        text: historyProc.running ? "Loading…" : "No runs yet"
        color: row.muted
        font.family: row.fontFamily
        font.pixelSize: row.capSize
        font.italic: true
      }
      Repeater {
        model: row.history
        delegate: RunRow {
          required property var modelData
          Layout.fillWidth: true
          row: row
          run: modelData
        }
      }
    }
  }
}
