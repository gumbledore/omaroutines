pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "panel" as SchedulePanel

// Bar-anchored task list (spec: .scratch/oma-schedule-panel/spec.md). The
// widget owns the `list --json` poll; this file holds the window, the shared
// one-at-a-time action loop, and expansion state. Rows are keyed by task name
// so refreshes update in place.
Panel {
  id: root
  moduleName: "kmg.oma-claude-schedule"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Color.muted

  readonly property string cliPath: hostWidget ? hostWidget.cliPath : ""
  readonly property var tasks: hostWidget ? hostWidget.tasks : []
  readonly property string summary: hostWidget ? hostWidget.tooltip : "Claude Schedule"
  readonly property bool cliOk: hostWidget ? hostWidget.cliOk : false
  readonly property int badge: hostWidget ? hostWidget.badge : 0
  readonly property var scheduleSettings: hostWidget ? hostWidget.scheduleSettings : ({})
  readonly property var agentKinds: hostWidget ? hostWidget.agentKinds : []
  readonly property string execution: String(scheduleSettings.execution || "headless")
  readonly property string defaultAgent: scheduleSettings.agent ? String(scheduleSettings.agent) : "no agent"
  property bool configMenuVisible: false

  property var expanded: ({})      // task name -> true
  property var rowErrors: ({})     // task name -> stderr of the last failed action
  property string armedRemove: ""  // task name awaiting the second Remove click
  property string timerStatus: ""
  property bool addFormVisible: false
  readonly property string addKey: "+add"  // rowErrors key for the add form ('+' is not a valid task name)
  readonly property string tasksPath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/oma-schedule/tasks.json"
  readonly property string settingsPath: scheduleSettings.path ? String(scheduleSettings.path)
    : (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/oma-schedule/settings.json"

  function setMap(name, key, value) {
    var next = {}
    var cur = root[name]
    for (var k in cur) next[k] = cur[k]
    if (value === undefined) delete next[key]; else next[key] = value
    root[name] = next
  }

  function isExpanded(name) { return root.expanded[name] === true }
  function toggleExpanded(name) { setMap("expanded", name, isExpanded(name) ? undefined : true) }

  function refresh() {
    if (hostWidget) hostWidget.refresh()
    timerProc.running = true
  }

  // ---- actions: one CLI call at a time, reload on exit, stderr inline -----
  readonly property bool actionBusy: actionProc.running
  property string actionTask: ""

  function runAction(name, args) {
    if (actionProc.running) return false
    root.actionTask = name
    root.setMap("rowErrors", name, undefined)
    actionProc.command = [root.cliPath].concat(args)
    actionProc.running = true
    return true
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        var msg = String(actionErr.text || "").trim() || ("exit " + exitCode)
        root.setMap("rowErrors", root.actionTask, msg)
      } else if (root.actionTask === root.addKey) {
        addForm.clear()
        root.addFormVisible = false
      }
      root.actionTask = ""
      root.refresh()
    }
  }

  function expandHome(p) {
    var s = String(p || "").trim()
    return s.indexOf("~") === 0 ? Quickshell.env("HOME") + s.substring(1) : s
  }

  // "run as" choices: follow settings, force herdr, or pin an installed kind
  // (a non-claude kind implies herdr, the only backend that runs it).
  readonly property var agentChoices: [{ value: "default", label: "default agent" }, { value: "herdr", label: "herdr" }]
    .concat(root.agentKinds.map(function (k) { return { value: "agent:" + k, label: k } }))

  function submitAdd() {
    var args = ["add", addForm.name.trim(), "--prompt", addForm.prompt, "--cwd", root.expandHome(addForm.cwd),
      "--schedule", addForm.schedule.trim() || "manual", "--worktree", addForm.worktree ? "true" : "false"]
    if (addForm.permissionMode.trim() !== "") args.push("--permission-mode", addForm.permissionMode.trim())
    var choice = addForm.agentChoice
    if (choice === "herdr") args.push("--execution", "herdr")
    else if (choice.indexOf("agent:") === 0) {
      var kind = choice.substring(6)
      args.push("--agent", kind)
      if (kind !== "claude") args.push("--execution", "herdr")
    }
    root.runAction(root.addKey, args)
  }

  // Both files are the CLI's; hand edits to tasks.json skip validation and
  // next_due recomputation, settings.json is re-merged on every read.
  function openConfig(path) {
    root.configMenuVisible = false
    Quickshell.execDetached(["omarchy-launch-config-editor", String(path)])
  }

  // A run can take minutes and must outlive this process handle (and a shell
  // restart), so trigger is detached; the row flips to running on reload.
  function trigger(name) {
    root.setMap("rowErrors", name, undefined)
    Quickshell.execDetached([root.cliPath, "trigger", name])
    reloadSoon.restart()
  }

  Timer { id: reloadSoon; interval: 400; onTriggered: root.refresh() }

  function openLog(path) { if (path) Quickshell.execDetached(["xdg-open", String(path)]) }

  Timer { id: disarmTimer; interval: 6000; onTriggered: root.armedRemove = "" }
  function removeClicked(name) {
    if (root.armedRemove !== name) { root.armedRemove = name; disarmTimer.restart(); return }
    root.armedRemove = ""
    disarmTimer.stop()
    root.setMap("expanded", name, undefined)
    root.runAction(name, ["rm", name])
  }

  // ---- footer: sweep timer -------------------------------------------------
  Process {
    id: timerProc
    command: ["systemctl", "--user", "show", "oma-schedule-sweep.timer",
      "-p", "ActiveState", "-p", "NextElapseUSecRealtime"]
    stdout: StdioCollector { id: timerOut; waitForEnd: true }
    onExited: function (exitCode) {
      var out = String(timerOut.text || "")
      var active = /ActiveState=active/.test(out)
      var m = out.match(/NextElapseUSecRealtime=.*?(\d\d:\d\d):\d\d/)
      root.timerStatus = active
        ? "sweep timer active" + (m ? " · next " + m[1] : "")
        : "sweep timer inactive — run install.sh"
    }
  }

  // ---- worktree pruning on open ------------------------------------------
  // Merged worktrees carry nothing the repo lacks, so they go without asking;
  // the header names them for a few seconds.
  property string pruneNote: ""
  Process {
    id: pruneProc
    command: [root.cliPath, "prune"]
    stdout: StdioCollector { id: pruneOut; waitForEnd: true }
    onExited: function (exitCode) {
      var n = String(pruneOut.text || "").split("\n").filter(function (l) { return l.indexOf("pruned: ") === 0 }).length
      if (n > 0) { root.pruneNote = "pruned " + n + " merged worktree" + (n === 1 ? "" : "s"); pruneNoteTimer.restart() }
      root.refresh()
    }
  }
  Timer { id: pruneNoteTimer; interval: 5000; onTriggered: root.pruneNote = "" }

  onOpenedChanged: {
    root.armedRemove = ""
    if (root.opened) {
      root.refresh()
      if (!pruneProc.running) pruneProc.running = true
    }
  }

  // ================================================================== UI
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(600))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Math.round(panel.screenH * 0.6))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
    }

    ColumnLayout {
      id: column
      anchors.fill: parent
      spacing: Style.space(6)

      // ---------------------------------------------------------------- header
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          text: "󰃰"
          color: root.badge > 0 ? root.urgent : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          RowLayout {
            spacing: Style.space(8)
            Text {
              text: "Claude Schedule"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            // backend + default agent every non-pinned task resolves to
            Rectangle {
              implicitWidth: modeText.implicitWidth + Style.space(8)
              implicitHeight: modeText.implicitHeight + Style.space(2)
              radius: height / 2
              readonly property color tone: root.execution === "herdr" ? root.accent : root.muted
              color: Util.alpha(tone, 0.18)
              border.width: 1
              border.color: tone
              Text {
                id: modeText
                anchors.centerIn: parent
                text: root.execution + " · " + root.defaultAgent
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              MouseArea { id: modeArea; anchors.fill: parent; hoverEnabled: true }
              PanelToolTip {
                visible: modeArea.containsMouse
                text: (root.execution === "herdr" ? "Runs are live agents in the hidden oma-schedule herdr session"
                  : "Runs are claude -p (headless)") + "\nchange: oma-schedule settings set execution herdr|headless"
                fontFamily: root.fontFamily
              }
            }
          }
          Text {
            Layout.fillWidth: true
            text: root.pruneNote !== "" ? root.summary + "  ·  " + root.pruneNote : root.summary
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        PanelActionButton {
          iconText: "󰑐"
          tooltipText: "Refresh"
          onClicked: root.refresh()
        }
        PanelActionButton {
          iconText: "󰐕"
          tooltipText: root.addFormVisible ? "Hide add form" : "Add a task"
          onClicked: root.addFormVisible = !root.addFormVisible
        }
        PanelActionButton {
          iconText: "󰒓"
          tooltipText: root.configMenuVisible ? "Hide" : "Open settings.json / tasks.json"
          onClicked: root.configMenuVisible = !root.configMenuVisible
        }
      }

      // ------------------------------------------------------- config menu
      RowLayout {
        visible: root.configMenuVisible
        Layout.fillWidth: true
        spacing: Style.space(6)
        Item { Layout.fillWidth: true }
        Button { text: "settings.json"; iconText: "󰒓"; iconSize: Style.font.caption; fontSize: Style.font.caption; tooltipText: root.settingsPath; onClicked: root.openConfig(root.settingsPath) }
        Button { text: "tasks.json"; iconText: "󰈙"; iconSize: Style.font.caption; fontSize: Style.font.caption; tooltipText: root.tasksPath; onClicked: root.openConfig(root.tasksPath) }
      }

      // ----------------------------------------------------------- add form
      ColumnLayout {
        id: addForm
        visible: root.addFormVisible
        Layout.fillWidth: true
        spacing: Style.space(4)

        readonly property string name: nameField.text
        readonly property string prompt: promptField.text
        readonly property string cwd: cwdField.text
        readonly property string schedule: scheduleField.text
        readonly property string permissionMode: permField.text
        property bool worktree: true
        property string agentChoice: "default"
        readonly property bool complete: nameField.text.trim() !== "" && promptField.text.trim() !== "" && cwdField.text.trim() !== ""
        readonly property string error: root.rowErrors[root.addKey] || ""

        function clear() {
          nameField.text = ""; promptField.text = ""; cwdField.text = ""
          scheduleField.text = "manual"; permField.text = ""; addForm.worktree = true
          addForm.agentChoice = "default"
        }
        function submit() { if (addForm.complete && !root.actionBusy) root.submitAdd() }

        onVisibleChanged: if (visible) nameField.forceActiveFocus()

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          TextField { id: nameField; Layout.preferredWidth: Style.space(160); placeholderText: "name"; font.family: root.fontFamily; onAccepted: addForm.submit() }
          TextField { id: cwdField; Layout.fillWidth: true; placeholderText: "cwd, e.g. ~/Nucleus/rad-onc"; font.family: root.fontFamily; onAccepted: addForm.submit() }
        }
        TextField { id: promptField; Layout.fillWidth: true; placeholderText: "prompt"; font.family: root.fontFamily; onAccepted: addForm.submit() }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          Text { text: "run as"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          // Flow, not ButtonGroup (a Row): with many kinds installed the
          // chips must wrap instead of widening the panel.
          Flow {
            Layout.fillWidth: true
            spacing: Style.space(4)
            Repeater {
              model: root.agentChoices
              delegate: Button {
                required property var modelData
                text: modelData.label
                selected: modelData.value === addForm.agentChoice
                bordered: true
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: addForm.agentChoice = modelData.value
              }
            }
          }
        }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          TextField { id: scheduleField; Layout.preferredWidth: Style.space(160); text: "manual"; placeholderText: "schedule (systemd calendar) or manual"; font.family: root.fontFamily; onAccepted: addForm.submit() }
          TextField { id: permField; Layout.fillWidth: true; placeholderText: "permission mode (optional)"; font.family: root.fontFamily; onAccepted: addForm.submit() }
          Text { text: "worktree"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          ToggleSwitch { checked: addForm.worktree; trackHeight: Style.space(14); foreground: root.fg; accent: root.accent; onToggled: addForm.worktree = !addForm.worktree }
          Button { text: "Add"; fontSize: Style.font.caption; enabled: addForm.complete && !root.actionBusy; onClicked: addForm.submit() }
        }
        Text {
          visible: addForm.error !== ""
          Layout.fillWidth: true
          text: "✗ " + addForm.error
          color: root.urgent
          wrapMode: Text.Wrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setMap("rowErrors", root.addKey, undefined) }
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      // ------------------------------------------------------------- task list
      Text {
        visible: root.tasks.length === 0
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        Layout.bottomMargin: Style.space(8)
        text: root.cliOk
          ? "No tasks yet. Add one from a terminal:\n  oma-schedule add <name> --prompt \"…\" --cwd <repo> --schedule \"Mon *-*-* 09:00\""
          : "oma-schedule is not responding — run install.sh, then refresh."
        color: root.muted
        wrapMode: Text.Wrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      ListView {
        id: list
        visible: root.tasks.length > 0
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: Math.min(contentHeight, Style.space(120))
        implicitHeight: contentHeight
        clip: true
        spacing: Style.space(2)
        cacheBuffer: 10000
        boundsBehavior: Flickable.StopAtBounds
        model: root.tasks

        ScrollBar.vertical: ScrollBar {
          policy: ScrollBar.AsNeeded
          implicitWidth: Style.space(6)
          contentItem: Rectangle {
            implicitWidth: Style.space(6)
            implicitHeight: Style.space(6)
            radius: width / 2
            color: Util.alpha(root.fg, 0.45)
          }
        }

        delegate: SchedulePanel.TaskRow {
          required property var modelData
          width: list.width - Style.space(8)
          panel: root
          task: modelData
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      // ---------------------------------------------------------------- footer
      Text {
        Layout.fillWidth: true
        text: root.timerStatus
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
