// Model.js — helpers for the Downloads bar widget.
// Data comes from bin/scan_downloads.py, which lists Telegram Desktop's
// currently-open-for-write files (see that script's header for why: no
// download API, no temp-file extension). Shape per row: { path, name, size }.
// Telegram never writes a file's total size to disk, so a real percentage
// needs bin/lookup_sizes.py's Telegram-search-based size cache (keyed by
// filename) - merged in here as `sizeCache: { [name]: bytes }`. A row whose
// name isn't in the cache yet just shows bytes-so-far and speed.

var UNITS = ["B", "KB", "MB", "GB", "TB"]

// Bytes -> "612 MB" / "1.2 GB". One decimal once past KB, none for bytes.
function formatBytes(n) {
  n = Number(n) || 0
  var i = 0
  while (n >= 1024 && i < UNITS.length - 1) { n /= 1024; i++ }
  return (i === 0 ? String(Math.round(n)) : n.toFixed(1)) + " " + UNITS[i]
}

// Bytes/sec -> "3.4 MB/s", or "" when there's nothing meaningful to show yet.
function formatSpeed(bytesPerSec) {
  if (!bytesPerSec || bytesPerSec <= 0) return ""
  return formatBytes(bytesPerSec) + "/s"
}

// Combines the previous poll's snapshot ({ [path]: { size, ts } }) with a
// fresh scan_downloads.py result to produce the row list the panel renders
// plus the snapshot to keep for the next tick. A path missing from `current`
// (finished or cancelled — indistinguishable from this data source) is just
// dropped; a path new this tick has no speed yet (needs two samples).
// `sizeCache` (optional, { [name]: totalBytes }) fills in `totalSize` and
// `percent` when lookup_sizes.py has already found this file's total.
function mergeSnapshot(previous, current, nowMs, sizeCache) {
  previous = previous || {}
  sizeCache = sizeCache || {}
  var rows = []
  var nextSnapshot = {}
  for (var i = 0; i < current.length; i++) {
    var row = current[i]
    var prev = previous[row.path]
    var bytesPerSec = 0
    if (prev && nowMs > prev.ts) {
      bytesPerSec = Math.max(0, (row.size - prev.size) / ((nowMs - prev.ts) / 1000))
    }
    var totalSize = sizeCache[row.name] || null
    var percent = totalSize ? Math.min(100, Math.round((row.size / totalSize) * 100)) : null
    rows.push({
      path: row.path, name: row.name, size: row.size, bytesPerSec: bytesPerSec,
      totalSize: totalSize, percent: percent
    })
    nextSnapshot[row.path] = { size: row.size, ts: nowMs }
  }
  return { rows: rows, snapshot: nextSnapshot }
}

// Raw shape written by lookup_sizes.py's cache file: { [name]: { size,
// cachedAt } }. Flattens to { [name]: bytes } for mergeSnapshot, dropping
// not-yet-found entries (size: null).
function parseSizeCache(raw) {
  var cache
  try { cache = JSON.parse(raw || "{}") } catch (e) { return {} }
  var out = {}
  for (var name in cache) {
    if (cache[name] && cache[name].size != null) out[name] = cache[name].size
  }
  return out
}

// Seconds remaining at the current speed -> "2m 14s" / "45s", or "" when
// there's not enough information (no total size yet, or stalled).
function formatEta(row) {
  if (!row || !row.totalSize || !row.bytesPerSec) return ""
  var remaining = row.totalSize - row.size
  if (remaining <= 0) return ""
  var seconds = Math.round(remaining / row.bytesPerSec)
  var m = Math.floor(seconds / 60)
  var s = seconds % 60
  return m > 0 ? (m + "m " + s + "s") : (s + "s")
}
