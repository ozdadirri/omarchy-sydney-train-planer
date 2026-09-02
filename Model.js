// Pure helpers for the Sydney Train Planner plugin. No QML imports here so the
// file can be unit-reasoned in isolation; all formatting that needs the shell
// locale (Qt.formatTime) is done by the caller and passed back in.
//
// Data comes from the TfNSW Trip Planner "rapidJSON" API:
//   stop_finder  -> locations[]
//   trip         -> journeys[].legs[]
//   coord        -> locations[] (nearest stops to a point)

var API_BASE = "https://api.transport.nsw.gov.au/v1/tp"

// ---- URL builders -----------------------------------------------------------

function stopFinderUrl(query) {
  return API_BASE + "/stop_finder"
    + "?outputFormat=rapidJSON"
    + "&type_sf=any"
    + "&name_sf=" + encodeURIComponent(String(query || "").trim())
    + "&coordOutputFormat=EPSG:4326"
    + "&TfNSWSF=true"
}

// A location is either a stop id ("200080") or a raw coordinate in TfNSW's
// "<lon>:<lat>:EPSG:4326" form (used for "current location"). The latter needs
// type_*=coord instead of type_*=any.
function isCoordId(id) {
  return /:EPSG:4326$/i.test(String(id || ""))
}

function coordId(lat, lon) {
  return lon + ":" + lat + ":EPSG:4326"
}

function tripUrl(originId, destinationId, yyyymmdd, hhmm) {
  var oType = isCoordId(originId) ? "coord" : "any"
  var dType = isCoordId(destinationId) ? "coord" : "any"
  return API_BASE + "/trip"
    + "?outputFormat=rapidJSON"
    + "&coordOutputFormat=EPSG:4326"
    + "&depArrMacro=dep"
    + "&itdDate=" + encodeURIComponent(yyyymmdd)
    + "&itdTime=" + encodeURIComponent(hhmm)
    + "&type_origin=" + oType + "&name_origin=" + encodeURIComponent(originId)
    + "&type_destination=" + dType + "&name_destination=" + encodeURIComponent(destinationId)
    + "&calcNumberOfTrips=6"
    + "&TfNSWTR=true"
    + "&version=10.2.1.42"
}

// curl argv shared by every request. `-fsS` = fail on HTTP error, silent,
// still show errors. Short timeouts keep a flaky network from wedging the UI.
function curlArgs(url, apiKey, maxSeconds) {
  return [
    "curl", "-fsS",
    "--max-time", String(maxSeconds || 8),
    "-H", "Authorization: apikey " + String(apiKey || ""),
    url
  ]
}

// ---- stop_finder ----------------------------------------------------------

// -> [{ id, name, disassembledName, type, isBest }]
function parseStopFinder(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var locs = data.locations || []
    var out = []
    for (var i = 0; i < locs.length; i++) {
      var l = locs[i]
      if (!l || !l.id) continue
      // Keep transit stops and places; drop bare street/address rows which
      // cannot seed a trip request.
      var t = String(l.type || "")
      if (t === "street" || t === "singlehouse" || t === "poiHierarchy") continue
      out.push({
        id: String(l.id),
        name: String(l.name || l.disassembledName || ""),
        disassembledName: String(l.disassembledName || l.name || ""),
        type: t,
        isBest: l.isBest === true,
        modes: Array.isArray(l.productClasses) ? l.productClasses.slice() : []
      })
    }
    // Best match first, then stops before coordinates/places.
    out.sort(function(a, b) {
      if (a.isBest !== b.isBest) return a.isBest ? -1 : 1
      var as = a.type === "stop" ? 0 : 1
      var bs = b.type === "stop" ? 0 : 1
      return as - bs
    })
    return out.slice(0, 8)
  } catch (e) {
    return []
  }
}

// ---- trip ---------------------------------------------------------------

var MODE_LABELS = {
  "1": "Train", "2": "Metro", "4": "Light Rail", "5": "Bus",
  "7": "Coach", "9": "Ferry", "11": "School Bus", "99": "Walk", "100": "Walk"
}

function isTransitLeg(leg) {
  if (!leg || !leg.transportation) return false
  var cls = leg.transportation.product ? leg.transportation.product.class : undefined
  return cls !== undefined && cls !== 99 && cls !== 100
}

function legTime(point, kind) {
  if (!point) return null
  var est = kind === "dep" ? point.departureTimeEstimated : point.arrivalTimeEstimated
  var plan = kind === "dep" ? point.departureTimePlanned : point.arrivalTimePlanned
  return { estimated: est || plan || null, planned: plan || est || null }
}

function minutesBetween(aIso, bIso) {
  if (!aIso || !bIso) return null
  var a = new Date(aIso).getTime()
  var b = new Date(bIso).getTime()
  if (isNaN(a) || isNaN(b)) return null
  return Math.round((b - a) / 60000)
}

function platformOf(point) {
  if (!point) return ""
  var p = point.properties || {}
  // Prefer the human name ("Platform 16") over the internal code ("CE16").
  var raw = p.plannedPlatformName || p.platformName || p.stoppingPointPlanned || ""
  var m = String(raw).match(/Platform\s+([0-9A-Za-z]+)/i)
  if (m) return m[1]
  if (raw) return String(raw)
  m = String(point.disassembledName || "").match(/Platform\s+([0-9A-Za-z]+)/i)
  return m ? m[1] : ""
}

function lineLabel(leg) {
  var tr = leg.transportation || {}
  return String(tr.disassembledName || tr.number || tr.name || "").trim()
}

function modeLabel(leg) {
  if (!isTransitLeg(leg)) return "Walk"
  var cls = leg.transportation.product ? leg.transportation.product.class : undefined
  return MODE_LABELS[String(cls)] || "Service"
}

function stopName(point) {
  if (!point) return ""
  return String(point.name || point.disassembledName || "")
}

// One row per leg of the journey (walk legs included), for the tap-to-expand
// detail view: line/mode, origin/destination stop names, platforms and
// estimated times, plus the wait between this leg's arrival and the next
// leg's departure at an interchange (null on the final leg).
function legDetails(legs) {
  var out = []
  for (var i = 0; i < legs.length; i++) {
    var leg = legs[i]
    var dep = legTime(leg.origin, "dep")
    var arr = legTime(leg.destination, "arr")
    var next = legs[i + 1]
    var waitMin = next ? minutesBetween(arr.estimated, legTime(next.origin, "dep").estimated) : null
    out.push({
      isTransit: isTransitLeg(leg),
      mode: modeLabel(leg),
      line: lineLabel(leg),
      originName: stopName(leg.origin),
      originPlatform: platformOf(leg.origin),
      depEstimated: dep.estimated,
      depPlanned: dep.planned,
      destName: stopName(leg.destination),
      destPlatform: platformOf(leg.destination),
      arrEstimated: arr.estimated,
      arrPlanned: arr.planned,
      durationMin: minutesBetween(dep.estimated, arr.estimated),
      waitMin: (waitMin !== null && waitMin >= 0) ? waitMin : null
    })
  }
  return out
}

// -> [{ depEstimated, depPlanned, arrEstimated, arrPlanned, durationMin,
//       delayMin, changes, platform, lines:[..], modes:[..],
//       originName, destName, legs:[..] }]
function parseTrip(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var journeys = data.journeys || []
    var out = []
    for (var i = 0; i < journeys.length; i++) {
      var legs = (journeys[i] && journeys[i].legs) || []
      if (!legs.length) continue

      var transit = legs.filter(isTransitLeg)
      var first = transit.length ? transit[0] : legs[0]
      var last = transit.length ? transit[transit.length - 1] : legs[legs.length - 1]

      var dep = legTime(first.origin, "dep")
      var arr = legTime(last.destination, "arr")

      var lines = []
      var modes = []
      for (var j = 0; j < transit.length; j++) {
        var lbl = lineLabel(transit[j])
        if (lbl) lines.push(lbl)
        var cls = transit[j].transportation.product ? transit[j].transportation.product.class : undefined
        var ml = MODE_LABELS[String(cls)] || "Service"
        if (modes.indexOf(ml) === -1) modes.push(ml)
      }

      if (!transit.length && !modes.length) modes.push("Walk")

      out.push({
        depEstimated: dep.estimated,
        depPlanned: dep.planned,
        arrEstimated: arr.estimated,
        arrPlanned: arr.planned,
        durationMin: minutesBetween(dep.estimated, arr.estimated),
        delayMin: minutesBetween(dep.planned, dep.estimated) || 0,
        changes: Math.max(0, transit.length - 1),
        platform: platformOf(first.origin),
        lines: lines,
        modes: modes,
        originName: String((first.origin && (first.origin.name || first.origin.disassembledName)) || ""),
        destName: String((last.destination && (last.destination.name || last.destination.disassembledName)) || ""),
        legs: legDetails(legs)
      })
    }
    // API usually returns them ordered, but be defensive.
    out.sort(function(a, b) {
      return new Date(a.depEstimated).getTime() - new Date(b.depEstimated).getTime()
    })
    return out
  } catch (e) {
    return []
  }
}

// ---- bar pill ---------------------------------------------------------------

// Compact "leaves in N" string for the next journey, relative to `now`.
function countdownLabel(trip, now) {
  if (!trip || !trip.depEstimated) return ""
  var mins = Math.round((new Date(trip.depEstimated).getTime() - now.getTime()) / 60000)
  if (mins < 0) return "now"
  if (mins === 0) return "now"
  if (mins < 60) return mins + "′"          // 6′
  var h = Math.floor(mins / 60)
  return h + "h" + (mins % 60) + "′"
}

function delayLabel(trip) {
  if (!trip || !trip.delayMin) return ""
  if (trip.delayMin > 0) return "+" + trip.delayMin
  return String(trip.delayMin)
}

// "on-time" | "late" | "early" | "unknown" — drives the pill colour.
function punctuality(trip) {
  if (!trip || trip.delayMin === null || trip.delayMin === undefined) return "unknown"
  if (trip.delayMin >= 2) return "late"
  if (trip.delayMin <= -2) return "early"
  return "on-time"
}

// ---- config file ----------------------------------------------------------

function normalizeConfig(obj) {
  var c = (obj && typeof obj === "object") ? obj : {}
  return {
    apiKey: String(c.apiKey || ""),
    origin: {
      id: String((c.origin && c.origin.id) || ""),
      name: String((c.origin && c.origin.name) || "")
    },
    destination: {
      id: String((c.destination && c.destination.id) || ""),
      name: String((c.destination && c.destination.name) || "")
    }
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    stopFinderUrl: stopFinderUrl, tripUrl: tripUrl,
    isCoordId: isCoordId, coordId: coordId,
    curlArgs: curlArgs, parseStopFinder: parseStopFinder,
    parseTrip: parseTrip,
    countdownLabel: countdownLabel, delayLabel: delayLabel,
    punctuality: punctuality, normalizeConfig: normalizeConfig,
    minutesBetween: minutesBetween
  }
}
