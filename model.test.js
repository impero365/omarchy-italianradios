const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("./Model.js")

const UUID = "044acc55-255b-4382-af22-ccf28445bb3e"
const MARKUP = '<img src="https://example.invalid/tracker">'

function station(overrides) {
  return Object.assign({
    stationuuid: UUID,
    name: "\tRadio Capital",
    countrycode: "IT",
    lastcheckok: 1,
    state: "Lazio",
    url: "http://example.test/capital",
    url_resolved: "https://example.test/capital",
    favicon: "https://www.capital.it/favicon.ico"
  }, overrides || {})
}

test("markup-shaped names, regions, and icons never become display text or urls", function() {
  assert.equal(Model.plainName(MARKUP), "")
  assert.equal(Model.iconUrl('https://a.favicon.im/x?larger=true" alt="x" loading="lazy" />'), "")
  assert.equal(Model.tooltipText(MARKUP, "Italian radios", "Playing %1"), "Italian radios")
  assert.equal(Model.tooltipText("Radio Capital", "Italian radios", "Playing %1"), "Playing Radio Capital")

  var parsed = Model.parseDirectory(JSON.stringify([
    station({ name: MARKUP, state: MARKUP, favicon: MARKUP }),
    station({
      stationuuid: "11111111-1111-1111-1111-111111111111",
      name: "Radio Capital",
      state: MARKUP,
      favicon: "https://cdn.example.test/logo.png"
    })
  ]))
  assert.equal(parsed.length, 1)
  assert.equal(parsed[0].name, "Radio Capital")
  assert.equal(parsed[0].region, "")
  assert.equal(parsed[0].icon, "https://cdn.example.test/logo.png")
  assert.equal(JSON.stringify(parsed).indexOf("example.invalid"), -1)
  assert.equal(JSON.stringify(parsed).indexOf("<"), -1)
})

test("directory rows keep an italian stream, a region, and an https icon", function() {
  var parsed = Model.parseDirectory(JSON.stringify([
    station(),
    station({ countrycode: "FR", stationuuid: "22222222-2222-2222-2222-222222222222" }),
    station({ lastcheckok: 0, stationuuid: "33333333-3333-3333-3333-333333333333", name: "Broken" }),
    station({
      stationuuid: "44444444-4444-4444-4444-444444444444",
      name: "File radio",
      url: "file:///tmp/secret",
      url_resolved: "file:///tmp/secret"
    }),
    { name: "not an object" }
  ]))
  assert.equal(parsed.length, 1)
  assert.equal(parsed[0].name, "Radio Capital")
  assert.equal(parsed[0].region, "Lazio")
  assert.equal(parsed[0].stream, "https://example.test/capital")
  assert.equal(parsed[0].icon, "https://www.capital.it/favicon.ico")
  assert.equal(Model.parseDirectory("").length, 0)
  assert.equal(Model.parseDirectory("x".repeat(Model.BODY_LIMIT + 1)).length, 0)
  assert.equal(Model.iconUrl("http://cdn.example.test/logo.png"), "")
  assert.equal(Model.streamUrl("https://user:pass@example.test/a"), "")
})

test("name filter ignores case and italian accents", function() {
  var list = Model.parseDirectory(JSON.stringify([
    station({ name: "Città Radio", stationuuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }),
    station({ name: "Radio Capital", stationuuid: UUID })
  ]))
  assert.deepEqual(Model.filterStations(list, "citta").map(function(row) { return row.name }), ["Città Radio"])
  assert.deepEqual(Model.filterStations(list, "CAPITAL").map(function(row) { return row.name }), ["Radio Capital"])
  assert.equal(Model.filterStations(list, MARKUP).length, 0)
  assert.equal(Model.filterStations(list, "").length, 2)
})

test("region filter matches the stored region and combines with the name", function() {
  var list = Model.parseDirectory(JSON.stringify([
    station({ name: "Radio Capital", state: "Lazio" }),
    station({
      name: "Città Radio",
      state: "Toscana",
      stationuuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    }),
    station({
      name: "Radio Senza Regione",
      state: "",
      stationuuid: "cccccccc-cccc-cccc-cccc-cccccccccccc"
    }),
    station({
      name: "Südtirol Radio",
      state: "Trentino-Alto Adige/Südtirol",
      stationuuid: "dddddddd-dddd-dddd-dddd-dddddddddddd"
    })
  ]))
  assert.deepEqual(Model.filterStations(list, "", "lazio").map(function(row) { return row.name }), ["Radio Capital"])
  assert.deepEqual(Model.filterStations(list, "", "sudtirol").map(function(row) { return row.name }), ["Südtirol Radio"])
  assert.deepEqual(Model.filterStations(list, "radio", "toscana").map(function(row) { return row.name }), ["Città Radio"])
  assert.equal(Model.filterStations(list, "", MARKUP).length, 0)
  assert.equal(Model.filterStations(list, "radio", "").length, 4)
})

test("player status accepts one status object and drops anything else", function() {
  var status = Model.parsePlayerStatus(JSON.stringify({
    running: true,
    paused: false,
    idle: false,
    starting: false,
    error: false,
    id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    name: "Radio Capital",
    reason: ""
  }))
  assert.equal(status.name, "Radio Capital")
  assert.equal(status.running, true)
  assert.equal(status.idle, false)
  assert.equal(Model.parsePlayerStatus('{"running":true,"name":"<img>"}'), null)
  assert.equal(Model.parsePlayerStatus('{"running":true,"reason":"shell"}'), null)
  assert.equal(Model.parsePlayerStatus("not json"), null)
  assert.equal(Model.parsePlayerStatus(""), null)
})

test("directory fetches are fixed argv, not a shell", function() {
  var fetch = Model.fetchCommand(0)
  assert.equal(fetch[0], "curl")
  assert.equal(fetch[fetch.length - 1], "https://de1.api.radio-browser.info/json/stations/search?countrycode=IT&hidebroken=true&order=name&limit=2500")
  assert.ok(fetch.indexOf("--max-filesize") !== -1)
  assert.equal(Model.fetchCommand(1)[Model.fetchCommand(1).length - 1].indexOf("https://de2.api.radio-browser.info/"), 0)
  assert.equal(Model.fetchCommand(2).length, 0)
  assert.equal(Model.fetchCommand("https://evil.example/").length, 0)
})

test("favourites keep the user's order and prefer a live directory row", function() {
  var liveId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  var goneId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  var saved = [
    {
      id: goneId,
      name: "Gone Radio",
      region: "Lazio",
      stream: "https://old.example.test/gone",
      icon: ""
    },
    {
      id: liveId,
      name: "Old Name",
      region: "",
      stream: "https://old.example.test/live",
      icon: ""
    },
    {
      id: goneId,
      name: "Duplicate",
      region: "",
      stream: "https://old.example.test/dup",
      icon: ""
    },
    {
      id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
      name: MARKUP,
      region: "Lazio",
      stream: "javascript:alert(1)",
      icon: ""
    }
  ]
  var stored = Model.parseFavourites(Model.favouritesPayload(saved))
  assert.deepEqual(stored.map(function(row) { return row.id }), [goneId, liveId])

  var directory = Model.parseDirectory(JSON.stringify([
    station({
      stationuuid: liveId,
      name: "Live Name",
      state: "Toscana",
      url_resolved: "https://live.example.test/stream"
    })
  ]))
  var resolved = Model.resolveFavourites(stored, directory)
  assert.equal(resolved[0].stream, "https://old.example.test/gone")
  assert.equal(resolved[1].name, "Live Name")
  assert.equal(resolved[1].region, "Toscana")
  assert.equal(resolved[1].stream, "https://live.example.test/stream")

  var removed = Model.toggleFavourite(stored, directory[0])
  assert.deepEqual(removed.map(function(row) { return row.id }), [goneId])
  var added = Model.toggleFavourite(removed, directory[0])
  assert.equal(added[0].id, liveId)
  assert.equal(added[0].name, "Live Name")
  assert.equal(added[0].stream, "https://live.example.test/stream")
  assert.equal(added.length, 2)
  assert.equal(Model.toggleFavourite(added, { id: "nope", name: "X", stream: "file:///tmp/x" }).length, 2)

  var many = []
  for (var n = 0; n < Model.FAVOURITE_CAP + 5; n++) {
    many.push({
      id: "dddddddd-dddd-dddd-dddd-" + String(100000000000 + n),
      name: "Station " + n,
      region: "",
      stream: "https://example.test/" + n,
      icon: ""
    })
  }
  assert.equal(Model.parseFavourites(JSON.stringify({ stations: many })).length, Model.FAVOURITE_CAP)
  assert.equal(Model.parseFavourites("not json").length, 0)
})

test("a saved list is checked again and expires after a day", function() {
  var payload = Model.cachePayload([
    {
      id: UUID,
      name: "Radio Capital",
      region: "Lazio",
      stream: "https://example.test/capital",
      icon: "https://cdn.example.test/logo.png"
    },
    {
      id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      name: MARKUP,
      region: "Lazio",
      stream: "javascript:alert(1)",
      icon: "https://cdn.example.test/logo.png"
    }
  ], 1000)
  var cached = Model.parseCache(payload)
  assert.equal(cached.stations.length, 1)
  assert.equal(cached.stations[0].stream, "https://example.test/capital")
  assert.equal(Model.cacheIsStale(cached.fetchedAt, cached.fetchedAt + Model.CACHE_MAX_AGE_MS + 1), true)
  assert.equal(Model.cacheIsStale(cached.fetchedAt, cached.fetchedAt + 1000), false)
  assert.equal(Model.cacheIsStale(0, 1000), true)
})
