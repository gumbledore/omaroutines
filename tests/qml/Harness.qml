import QtQuick
import Quickshell
import qs.Commons

// Headless smoke test root (tests/test_qml_smoke.py). Loads the real
// BarWidget.qml without a bar (so its layer-shell panel stays unloaded — no
// PanelWindow backend exists offscreen), waits for it to parse the fake
// `oma-schedule list --json`, then compile-checks every other QML file and
// reports on stdout. Exit code 0 = pass.
ShellRoot {
  id: root

  readonly property string pluginDir: "file://" + Quickshell.env("OMA_SCHEDULE_PLUGIN_DIR")
  property bool done: false

  function finish(code) {
    if (root.done) return
    root.done = true
    console.log(code === 0 ? "SMOKE PASS" : "SMOKE FAIL " + code)
    Qt.exit(code)
  }

  // Files that only fail because no window backend exists offscreen.
  function compileOk(rel) {
    var c = Qt.createComponent(root.pluginDir + "/" + rel)
    if (c.status !== Component.Error) return true
    var err = c.errorString()
    if (rel === "Panel.qml" && /No PanelWindow backend/.test(err)) return true
    console.log("COMPILE ERROR " + rel + ": " + err)
    return false
  }

  // Stand-in for Panel.qml (needs a window backend): just what the rows bind to.
  QtObject {
    id: fakePanel
    property var tasks: []
    property bool opened: false
    property bool actionBusy: false
    property string armedRemove: ""
    property var rowErrors: ({})
    property string cliPath: "oma-schedule"
    property color fg: "white"
    property color muted: "gray"
    property color accent: "blue"
    property color urgent: "red"
    property string fontFamily: "monospace"
    function isExpanded(name) { return false }
    function setMap(m, k, v) {}
    function runAction(name, args) {}
    function toggleExpanded(name) {}
    function trigger(name) {}
    function removeClicked(name) {}
    function openLog(p) {}
  }

  // Instantiate TaskRow (and a RunRow off it) per task and report the
  // Attach/Resume contract so a binding typo cannot hide behind a clean compile.
  function rowsOk(tasks) {
    var tc = Qt.createComponent(root.pluginDir + "/panel/TaskRow.qml")
    var rc = Qt.createComponent(root.pluginDir + "/panel/RunRow.qml")
    if (tc.status === Component.Error || rc.status === Component.Error) return false
    for (var i = 0; i < tasks.length; i++) {
      var t = tc.createObject(holder, { panel: fakePanel, task: tasks[i] })
      if (!t) { console.log("ROW ERROR TaskRow " + tasks[i].name + ": " + tc.errorString()); return false }
      console.log("TASKROW " + t.name + " herdr=" + t.lastHerdr + " blocked=" + t.lastBlocked
        + " canResume=" + t.canResume + " tip=" + t.resumeTooltip(t.lastRun))
      if (tasks[i].last_run) {
        var r = rc.createObject(holder, { row: t, run: tasks[i].last_run })
        if (!r) { console.log("ROW ERROR RunRow " + tasks[i].name + ": " + rc.errorString()); return false }
        console.log("RUNROW " + t.name + " herdr=" + r.herdr + " blocked=" + r.blocked + " canResume=" + r.canResume)
      }
    }
    return true
  }
  Item { id: holder; width: 600; height: 400 }

  Loader {
    id: widget
    source: root.pluginDir + "/BarWidget.qml"
    onStatusChanged: {
      if (status === Loader.Error) { console.log("COMPILE ERROR BarWidget.qml"); root.finish(2) }
    }
  }

  Timer {
    interval: 50
    repeat: true
    running: true
    onTriggered: {
      var w = widget.item
      if (!w || !w.cliOk) return
      console.log("TASKS " + w.tasks.length)
      console.log("TOOLTIP " + w.tooltip)
      console.log("BADGE " + w.badge)
      var ok = true
      var files = ["Panel.qml", "panel/TaskRow.qml", "panel/RunRow.qml"]
      for (var i = 0; i < files.length; i++) ok = root.compileOk(files[i]) && ok
      ok = root.rowsOk(w.tasks) && ok
      root.finish(ok ? 0 : 3)
    }
  }

  Timer { interval: 10000; running: true; onTriggered: { console.log("TIMEOUT waiting for list --json"); root.finish(4) } }
}
