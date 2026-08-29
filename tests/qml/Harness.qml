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
      root.finish(ok ? 0 : 3)
    }
  }

  Timer { interval: 10000; running: true; onTriggered: { console.log("TIMEOUT waiting for list --json"); root.finish(4) } }
}
