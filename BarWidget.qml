import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One glyph, one badge. Everything shown here is computed by
// `oma-schedule list --json` (badge / enabled / tooltip); the widget only
// polls it when the store changes or a minute passes.
BarWidget {
  id: root
  moduleName: "kmg.oma-claude-schedule"

  readonly property string homePath: Quickshell.env("HOME")
  readonly property string cliPath: homePath + "/.local/bin/oma-schedule"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (homePath + "/.local/state"))
    + "/oma-schedule"

  property int badge: 0
  property int enabledCount: 0
  property string tooltip: "Claude Schedule"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!jsonProc.running) jsonProc.running = true
  }

  function reset() {
    root.badge = 0
    root.enabledCount = 0
    root.tooltip = "Claude Schedule"
  }

  function update(raw) {
    var data = ({})
    try { data = JSON.parse(String(raw || "{}")) } catch (e) { data = ({}) }
    root.badge = Number(data.badge || 0)
    root.enabledCount = Number(data.enabled || 0)
    root.tooltip = String(data.tooltip || "Claude Schedule")
  }

  Component.onCompleted: refresh()

  // No IpcHandler: the overlay owns the plugin id as an IPC target. A run
  // finalizing touches only runs.json, so both files are watched.
  FileView {
    path: root.stateDir + "/tasks.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  FileView {
    path: root.stateDir + "/runs.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: jsonProc
    command: [root.cliPath, "list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.update(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.reset()
    }
  }

  BarIconButton {
    id: button
    bar: root.bar
    active: root.badge > 0
    useActiveColor: true
    text: root.badge > 0 ? "󰃰 " + root.badge : "󰃰"
    tooltipText: root.tooltip
    dimmed: root.enabledCount === 0
    onPressed: Quickshell.execDetached([root.cliPath, "show-overlay"])
  }
}
