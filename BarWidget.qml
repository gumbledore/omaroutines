import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry: one glyph, one badge, and the owner of the data poll. Everything
// shown here or in the panel comes from `oma-schedule list --json`; the widget
// re-runs it when the store changes or a minute passes and the panel binds to
// the parsed result (no second poll). The panel is loaded as soon as the bar
// attaches, so `oma-schedule show-overlay` (shell summon → open()) works
// without the panel ever having been clicked.
BarWidget {
  id: root
  moduleName: "kmg.oma-claude-schedule"

  readonly property string homePath: Quickshell.env("HOME")
  readonly property string cliPath: homePath + "/.local/bin/oma-schedule"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (homePath + "/.local/state"))
    + "/oma-schedule"

  // Parsed `list --json`.
  property var tasks: []
  property int badge: 0
  property int enabledCount: 0
  property string tooltip: "Claude Schedule"
  property bool cliOk: false

  // Popout contract the bar's summon/activePopout coordinator uses.
  property var panelItem: null
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false
  function open() { if (panelItem) panelItem.open() }
  function close() { if (panelItem) panelItem.close() }
  function togglePanel() { if (panelItem) panelItem.toggle() }
  function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A change that lands while a poll is running must not be lost (the sweep
  // often writes twice within 100 ms), so one re-run is queued.
  property bool refreshPending: false
  function refresh() {
    if (jsonProc.running) { root.refreshPending = true; return }
    jsonProc.running = true
  }

  function reset() {
    root.tasks = []
    root.badge = 0
    root.enabledCount = 0
    root.tooltip = "Claude Schedule"
    root.cliOk = false
  }

  function update(raw) {
    var data = ({})
    try { data = JSON.parse(String(raw || "{}")) } catch (e) { data = ({}) }
    root.tasks = Array.isArray(data.tasks) ? data.tasks : []
    root.badge = Number(data.badge || 0)
    root.enabledCount = Number(data.enabled || 0)
    root.tooltip = String(data.tooltip || "Claude Schedule")
    root.cliOk = Array.isArray(data.tasks)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    panelItem = target
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: refresh()

  // The panel is a layer-shell window, which needs a bar to anchor to (and a
  // compositor to exist at all — the headless smoke test never sets `bar`).
  Loader {
    id: panelLoader
    active: root.bar !== null
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // A run finalizing touches only runs.json, so both files are watched.
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
      if (root.refreshPending) { root.refreshPending = false; Qt.callLater(root.refresh) }
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
    onPressed: function (b) {
      if (b === Qt.LeftButton) root.togglePanel()
      else if (b === Qt.RightButton) root.refresh()
    }
  }
}
