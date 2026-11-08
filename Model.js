// Pure helpers for the Italian radio panel. Directory text is untrusted:
// names that contain markup are dropped, and only http(s) stream URLs and
// https image icons are kept. Playback is an argv array, never a shell line.

var BODY_LIMIT = 4000000
var STATION_CAP = 2500
var SCAN_CAP = 3000
var NAME_LIMIT = 80
var REGION_LIMIT = 48
var URL_LIMIT = 500
var CACHE_MAX_AGE_MS = 24 * 60 * 60 * 1000

var DIRECTORY_HOSTS = [
  "https://de1.api.radio-browser.info",
  "https://de2.api.radio-browser.info"
]

var SEARCH_PATH = "/json/stations/search?countrycode=IT&hidebroken=true&order=name&limit=2500"

var ACCENT_FROM = "àáâäãåèéêëìíîïòóôöõùúûüýÿñç"
var ACCENT_TO = "aaaaaaeeeeiiiiooooouuuuyync"

function plainName(value, maxLen) {
  var limit = maxLen || NAME_LIMIT
  var s = String(value == null ? "" : value)
  s = s.replace(/[\u0000-\u001F\u007F]/g, " ")
  s = s.replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  if (!s || s.indexOf("<") !== -1 || s.indexOf(">") !== -1) return ""
  if (s.length > limit) s = s.slice(0, limit).replace(/\s+$/g, "")
  return s
}

function fold(value) {
  var s = String(value == null ? "" : value).toLowerCase()
  var out = ""
  for (var i = 0; i < s.length; i++) {
    var ch = s.charAt(i)
    var idx = ACCENT_FROM.indexOf(ch)
    out += idx >= 0 ? ACCENT_TO.charAt(idx) : ch
  }
  return out
}

function foldQuery(value) {
  var raw = String(value == null ? "" : value)
  if (raw.indexOf("<") !== -1 || raw.indexOf(">") !== -1) return null
  var s = fold(raw).replace(/[\u0000-\u001F\u007F]/g, " ").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  if (!s) return ""
  if (s.length > NAME_LIMIT) s = s.slice(0, NAME_LIMIT)
  return s
}

function httpUrl(value, httpsOnly) {
  var s = String(value == null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (s.length < 12 || s.length > URL_LIMIT) return ""
  if (/[\u0000-\u001F\u007F\s<>"'\\]/.test(s)) return ""
  var match = /^(https?):\/\/([^\/?#]+)([^]*)$/i.exec(s)
  if (!match) return ""
  if (httpsOnly && match[1].toLowerCase() !== "https") return ""
  var host = match[2]
  if (host.indexOf("@") !== -1 || host.indexOf("..") !== -1) return ""
  var named = /^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$/.test(host)
  var v6 = /^\[[0-9A-Fa-f:.]+\](?::[0-9]{1,5})?$/.test(host)
  if (!named && !v6) return ""
  return s
}

function streamUrl(value) {
  return httpUrl(value, false)
}

function iconUrl(value) {
  var s = httpUrl(value, true)
  if (!s) return ""
  var path = s.split("?")[0].split("#")[0].toLowerCase()
  if (!/\.(png|jpe?g|webp|gif|ico|svg)$/.test(path)) return ""
  return s
}

function stationId(value) {
  var s = String(value == null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s)) return ""
  return s.toLowerCase()
}

function acceptStation(fields) {
  if (!fields) return null
  var id = stationId(fields.id)
  var name = plainName(fields.name, NAME_LIMIT)
  var stream = streamUrl(fields.stream)
  if (!id || !name || !stream) return null
  return {
    id: id,
    name: name,
    region: plainName(fields.region, REGION_LIMIT),
    stream: stream,
    icon: iconUrl(fields.icon)
  }
}

function sortStations(list) {
  return list.slice().sort(function(a, b) {
    var left = fold(a.name)
    var right = fold(b.name)
    if (left < right) return -1
    if (left > right) return 1
    if (a.id < b.id) return -1
    if (a.id > b.id) return 1
    return 0
  })
}

function fromApiItem(item) {
  if (!item || typeof item !== "object") return null
  if (String(item.countrycode || "").toUpperCase() !== "IT") return null
  if (item.lastcheckok === 0 || item.lastcheckok === false) return null
  var stream = streamUrl(item.url_resolved) || streamUrl(item.url)
  return acceptStation({
    id: item.stationuuid,
    name: item.name,
    region: item.state,
    stream: stream,
    icon: item.favicon
  })
}

function collect(rawItems, pick) {
  var list = []
  var seen = {}
  var scan = Math.min(rawItems.length, SCAN_CAP)
  for (var i = 0; i < scan && list.length < STATION_CAP; i++) {
    var station = pick(rawItems[i])
    if (!station || seen[station.id]) continue
    seen[station.id] = true
    list.push(station)
  }
  return sortStations(list)
}

function parseDirectory(raw) {
  var text = String(raw || "")
  if (!text || text.length > BODY_LIMIT) return []
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return []
  }
  if (!Array.isArray(data)) return []
  return collect(data, fromApiItem)
}

function parseCache(raw) {
  var text = String(raw || "")
  if (!text || text.length > BODY_LIMIT) return { fetchedAt: 0, stations: [] }
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { fetchedAt: 0, stations: [] }
  }
  if (!data || typeof data !== "object" || !Array.isArray(data.stations)) return { fetchedAt: 0, stations: [] }
  var fetchedAt = Number(data.fetchedAt)
  if (!isFinite(fetchedAt) || fetchedAt < 0) fetchedAt = 0
  var stations = collect(data.stations, function(item) {
    return acceptStation(item)
  })
  return { fetchedAt: fetchedAt, stations: stations }
}

function cachePayload(stations, fetchedAt) {
  var clean = collect(stations || [], function(item) { return acceptStation(item) })
  if (!clean.length) return ""
  var when = Number(fetchedAt)
  if (!isFinite(when) || when < 0) when = 0
  return JSON.stringify({ fetchedAt: when, stations: clean })
}

function cacheIsStale(fetchedAt, now) {
  var then = Number(fetchedAt)
  var clock = Number(now)
  if (!isFinite(then) || then <= 0 || !isFinite(clock)) return true
  var age = clock - then
  if (age < -5 * 60 * 1000) return true
  return age > CACHE_MAX_AGE_MS
}

function filterStations(list, nameQuery, regionQuery) {
  var src = list || []
  var name = foldQuery(nameQuery)
  var region = foldQuery(regionQuery)
  if (name === null || region === null) return []
  if (!name && !region) {
    var copy = []
    for (var i = 0; i < src.length; i++) copy.push(src[i])
    return copy
  }
  var nameNeedle = name ? fold(name) : ""
  var regionNeedle = region ? fold(region) : ""
  var out = []
  for (var j = 0; j < src.length; j++) {
    if (nameNeedle && fold(src[j].name).indexOf(nameNeedle) === -1) continue
    if (regionNeedle && fold(src[j].region).indexOf(regionNeedle) === -1) continue
    out.push(src[j])
  }
  return out
}

function directoryUrl(hostIndex) {
  var idx = Number(hostIndex)
  if (!isFinite(idx) || idx < 0 || idx >= DIRECTORY_HOSTS.length) return ""
  return DIRECTORY_HOSTS[idx] + SEARCH_PATH
}

function fetchCommand(hostIndex) {
  var url = directoryUrl(hostIndex)
  if (!url) return []
  return [
    "curl", "-fsS",
    "--max-time", "20",
    "--max-filesize", String(BODY_LIMIT),
    "-A", "mattia.radio/1.0",
    "-H", "Accept: application/json",
    url
  ]
}

function playerCommand(stream, title) {
  var url = streamUrl(stream)
  if (!url) return []
  var args = [
    "mpv",
    "--no-video",
    "--no-terminal",
    "--force-window=no",
    "--no-input-default-bindings",
    "--really-quiet"
  ]
  var name = plainName(title, NAME_LIMIT)
  if (name) args.push("--force-media-title=" + name)
  args.push("--", url)
  return args
}

function tooltipText(playingName, idleLabel, playingLabel) {
  var name = plainName(playingName, NAME_LIMIT)
  if (!name) return String(idleLabel || "")
  return String(playingLabel || "").replace("%1", name)
}

if (typeof module !== "undefined") {
  module.exports = {
    BODY_LIMIT: BODY_LIMIT,
    STATION_CAP: STATION_CAP,
    CACHE_MAX_AGE_MS: CACHE_MAX_AGE_MS,
    plainName: plainName,
    foldQuery: foldQuery,
    streamUrl: streamUrl,
    iconUrl: iconUrl,
    parseDirectory: parseDirectory,
    parseCache: parseCache,
    cachePayload: cachePayload,
    cacheIsStale: cacheIsStale,
    filterStations: filterStations,
    directoryUrl: directoryUrl,
    fetchCommand: fetchCommand,
    playerCommand: playerCommand,
    tooltipText: tooltipText
  }
}
