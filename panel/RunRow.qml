pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Format.js" as Format

// One entry of a task's run history (from `log <task> --json`).
RowLayout {
  id: runRow

  required property var row
  required property var run

  readonly property bool running: run.status === "running"
  readonly property bool canResume: !running && run.session_available === true
  readonly property bool hasLog: run.log_path !== null && run.log_path !== undefined

  spacing: Style.space(6)

  Text {
    text: "#" + runRow.run.id
    color: runRow.row.muted
    font.family: runRow.row.fontFamily
    font.pixelSize: runRow.row.capSize
    Layout.preferredWidth: Style.space(28)
  }
  Text {
    text: runRow.run.status
    color: Format.statusColor(runRow.run.status, runRow.row.accent, runRow.row.urgent, runRow.row.muted)
    font.family: runRow.row.fontFamily
    font.pixelSize: runRow.row.capSize
    font.bold: runRow.run.status === "failure"
    Layout.preferredWidth: Style.space(48)
  }
  Text {
    Layout.fillWidth: true
    text: runRow.run.trigger + "  ·  " + Format.when(runRow.run.start)
      + (runRow.running ? "  →  …" : "  →  " + Format.clock(runRow.run.end) + " (" + Format.duration(runRow.run.start, runRow.run.end) + ")")
    color: runRow.row.fg
    font.family: runRow.row.fontFamily
    font.pixelSize: runRow.row.capSize
    elide: Text.ElideRight
  }
  Text {
    visible: runRow.run.worktree_path !== null && runRow.run.worktree_path !== undefined
    text: "worktree"
    color: runRow.row.accent
    font.family: runRow.row.fontFamily
    font.pixelSize: runRow.row.capSize
    font.italic: true
    MouseArea { id: wtArea; anchors.fill: parent; hoverEnabled: true }
    PanelToolTip { visible: wtArea.containsMouse; text: String(runRow.run.worktree_path || ""); fontFamily: runRow.row.fontFamily }
  }
  PanelActionButton {
    iconText: "󰆍"
    size: Style.space(18)
    fontSize: runRow.row.capSize
    foreground: runRow.row.muted
    hoverColor: runRow.row.accent
    enabled: runRow.canResume && !runRow.row.anyBusy
    tooltipText: runRow.row.resumeTooltip(runRow.run)
    onClicked: runRow.row.act(["resume", String(runRow.run.id), "--terminal"])
  }
  PanelActionButton {
    iconText: "󰈙"
    size: Style.space(18)
    fontSize: runRow.row.capSize
    foreground: runRow.row.muted
    hoverColor: runRow.row.accent
    enabled: runRow.hasLog
    tooltipText: runRow.hasLog ? "Open captured output" : "Log file is gone"
    onClicked: runRow.row.panel.openLog(runRow.run.log_path)
  }
}
