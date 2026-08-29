.pragma library

// Presentation helpers shared by the panel rows. Epochs come from the CLI.

function when(epoch) {
  if (!epoch) return "-"
  return Qt.formatDateTime(new Date(Number(epoch) * 1000), "ddd d MMM HH:mm")
}

function clock(epoch) {
  if (!epoch) return "-"
  return Qt.formatDateTime(new Date(Number(epoch) * 1000), "HH:mm")
}

function duration(start, end) {
  if (!start || !end) return ""
  var s = Math.max(0, Number(end) - Number(start))
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m " + (s % 60) + "s"
  return Math.floor(m / 60) + "h " + (m % 60) + "m"
}

function statusColor(status, accent, urgent, muted) {
  if (status === "failure") return urgent
  if (status === "running") return accent
  return muted
}
