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

  // `row` can go null while this delegate outlives its task row during a
  // refresh; bindings read these guarded copies instead of `row.*`.
  readonly property color fg: row ? row.fg : "transparent"
  readonly property color muted: row ? row.muted : "transparent"
  readonly property color accent: row ? row.accent : "transparent"
  readonly property color urgent: row ? row.urgent : "transparent"
  readonly property string fontFamily: row ? row.fontFamily : ""
  readonly property int capSize: row ? row.capSize : 0
  readonly property bool anyBusy: row ? row.anyBusy : false

  readonly property bool running: run.status === "running"
  readonly property bool herdr: run.backend === "herdr"
  readonly property bool blocked: run.reason === "blocked"
  // Resume (headless: claude --resume) or Attach (herdr: open the pane)
  readonly property bool canResume: !running && (herdr ? run.pane_available === true : run.session_available === true)
  readonly property bool hasLog: run.log_path !== null && run.log_path !== undefined

  spacing: Style.space(6)

  Text {
    text: "#" + runRow.run.id
    color: runRow.muted
    font.family: runRow.fontFamily
    font.pixelSize: runRow.capSize
    Layout.preferredWidth: Style.space(28)
  }
  Text {
    text: runRow.run.status + (runRow.run.reason ? " · " + runRow.run.reason : "")
    color: Format.statusColor(runRow.run.status, runRow.accent, runRow.urgent, runRow.muted)
    font.family: runRow.fontFamily
    font.pixelSize: runRow.capSize
    font.bold: runRow.run.status === "failure"
    Layout.preferredWidth: Style.space(runRow.run.reason ? 100 : 48)
  }
  Text {
    Layout.fillWidth: true
    text: runRow.run.trigger + "  ·  " + Format.when(runRow.run.start)
      + (runRow.running ? "  →  …" : "  →  " + Format.clock(runRow.run.end) + " (" + Format.duration(runRow.run.start, runRow.run.end) + ")")
    color: runRow.fg
    font.family: runRow.fontFamily
    font.pixelSize: runRow.capSize
    elide: Text.ElideRight
  }
  Text {
    visible: runRow.run.worktree_path !== null && runRow.run.worktree_path !== undefined
    text: "worktree"
    color: runRow.accent
    font.family: runRow.fontFamily
    font.pixelSize: runRow.capSize
    font.italic: true
    MouseArea { id: wtArea; anchors.fill: parent; hoverEnabled: true }
    PanelToolTip { visible: wtArea.containsMouse; text: String(runRow.run.worktree_path || ""); fontFamily: runRow.fontFamily }
  }
  PanelActionButton {
    iconText: "󰆍"
    size: Style.space(18)
    fontSize: runRow.capSize
    foreground: runRow.blocked && runRow.canResume ? runRow.urgent : runRow.muted
    hoverColor: runRow.blocked ? runRow.urgent : runRow.accent
    enabled: runRow.canResume && !runRow.anyBusy
    tooltipText: runRow.row ? runRow.row.resumeTooltip(runRow.run) : ""
    onClicked: runRow.row.act([runRow.herdr ? "attach" : "resume", String(runRow.run.id), "--terminal"])
  }
  PanelActionButton {
    iconText: "󰈙"
    size: Style.space(18)
    fontSize: runRow.capSize
    foreground: runRow.muted
    hoverColor: runRow.accent
    enabled: runRow.hasLog
    tooltipText: runRow.hasLog ? "Open captured output" : "Log file is gone"
    onClicked: runRow.row.panel.openLog(runRow.run.log_path)
  }
}
