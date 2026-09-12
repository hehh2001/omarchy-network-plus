function parseNetworkStatus(raw) {
  var parts = String(raw || "disconnected\t\t\t").replace(/\r?\n+$/, "").split("\t")
  return {
    kind: parts[0] || "disconnected",
    label: parts[1] || "",
    signalStrength: parts[2] ? parseInt(parts[2], 10) : -1,
    frequency: parts[3] || ""
  }
}

function wifiIconFor(strength) {
  var icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
  var index = Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))
  return icons[index]
}

function connectionIcon(kind, signalStrength) {
  if (kind === "wifi") return wifiIconFor(signalStrength)
  if (kind === "ethernet") return "󰈀"
  return "󰤮"
}

function formatHeaderSpeed(mbps) {
  var v = parseInt(mbps, 10)
  if (!v || v < 0) return ""
  if (v >= 1000) return (v / 1000).toFixed(v % 1000 === 0 ? 0 : 1) + "gbit"
  return v + "mbit"
}

function formatHeaderFreq(mhz) {
  var v = parseFloat(mhz)
  if (!v) return ""

  if (v >= 2400 && v < 2500) return "2.4ghz"
  if (v >= 4900 && v < 5925) return "5ghz"
  if (v >= 5925 && v < 7125) return "6ghz"
  if (v >= 57000 && v < 71000) return "60ghz"

  var ghz = v / 1000
  return ghz.toFixed(ghz % 1 === 0 ? 0 : 1) + "ghz"
}

// Wi-Fi band state belongs in the selector section, not beside the hero name.
// Ethernet has no equivalent selector, so keep its negotiated link speed here.
function headerDetail(info) {
  var value = info || {}
  if (value.type === "ethernet") return formatHeaderSpeed(value.speed || "")
  return ""
}

function bandLabel(band) {
  if (band === "auto") return "Auto"
  if (!band) return ""
  return band + "ghz"
}

// Under Automatic the pills are hidden, so the header carries the live band
// instead -- "WI-FI BAND: 2.4GHZ". Once a band is pinned the pills are on
// screen and say it themselves, so the header drops back to a plain label.
function bandSectionTitle(selected, current) {
  if (selected !== "auto") return "WI-FI BAND"

  var label = bandLabel(current)
  if (label === "") return "WI-FI BAND"

  return "WI-FI BAND: " + label.toUpperCase()
}

function bandTooltip(band) {
  if (band === "auto") return "Let Wi-Fi pick the band"
  if (!band) return ""
  return "Stay on " + bandLabel(band)
}

function parseBandStatus(raw) {
  var next = parseKeyValue(raw)
  var tokens = String(next.available || "").split(" ")
  var available = []

  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i] !== "") available.push(tokens[i])
  }

  return {
    band: next.band || "",
    selected: next.selected || "auto",
    available: available
  }
}

function decodeIwSsid(value) {
  var raw = String(value || "")

  try {
    var encoded = ""

    for (var i = 0; i < raw.length; i++) {
      if (raw[i] === "\\" && raw[i + 1] === "x" && /^[0-9a-f]{2}$/i.test(raw.substring(i + 2, i + 4))) {
        var hex = raw.substring(i + 2, i + 4)
        var byte = parseInt(hex, 16)
        encoded += byte < 32 || byte === 127 ? encodeURIComponent(raw.substring(i, i + 4)) : "%" + hex
        i += 3
      } else {
        encoded += encodeURIComponent(raw[i])
      }
    }

    return decodeURIComponent(encoded)
  } catch (error) {
    return raw
  }
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var idx = line.indexOf("\t")
    if (idx === -1) continue
    var key = line.substring(0, idx)
    var value = line.substring(idx + 1)
    next[key] = key === "ssid" ? decodeIwSsid(value) : value.trim()
  }
  return next
}

function throughputState(previous, next, now) {
  var prev = previous || {}
  var sample = next || {}
  var iface = sample.iface || ""
  var rx = parseFloat(sample.rx_bytes || "0")
  var tx = parseFloat(sample.tx_bytes || "0")
  var previousTime = Number(prev.prevSampleTime || 0)

  if (iface !== (prev.prevIface || "") || previousTime === 0) {
    return {
      prevIface: iface,
      prevRxBytes: rx,
      prevTxBytes: tx,
      prevSampleTime: now,
      downloadRate: 0,
      uploadRate: 0
    }
  }

  var downloadRate = Number(prev.downloadRate || 0)
  var uploadRate = Number(prev.uploadRate || 0)
  var dt = now - previousTime
  if (dt > 0) {
    downloadRate = Math.max(0, (rx - Number(prev.prevRxBytes || 0)) / dt)
    uploadRate = Math.max(0, (tx - Number(prev.prevTxBytes || 0)) / dt)
  }

  return {
    prevIface: iface,
    prevRxBytes: rx,
    prevTxBytes: tx,
    prevSampleTime: now,
    downloadRate: downloadRate,
    uploadRate: uploadRate
  }
}

function pingSampleValue(raw) {
  var value = parseFloat(raw)
  if (!isFinite(value) || value < 0) return null
  return value
}

function appendPingSample(samples, raw, limit) {
  var values = Array.isArray(samples) ? samples.slice() : []

  values.push(pingSampleValue(raw))
  while (values.length > limit) values.shift()

  return values
}

function averagePingLatency(samples, limit) {
  var values = Array.isArray(samples) ? samples : []
  var sampleLimit = Math.max(1, parseInt(limit, 10) || values.length || 1)
  var total = 0
  var count = 0

  for (var i = Math.max(0, values.length - sampleLimit); i < values.length; i++) {
    var value = values[i]
    if (typeof value !== "number" || !isFinite(value) || value < 0) continue
    total += value
    count++
  }

  return count > 0 ? total / count : -1
}

function pingPacketLossPercent(samples) {
  var values = Array.isArray(samples) ? samples : []
  if (values.length === 0) return 0

  var lost = 0
  for (var i = 0; i < values.length; i++) {
    if (values[i] === null) lost++
  }

  return Math.round((lost / values.length) * 100)
}

function formatPacketLoss(percent, hasSamples) {
  if (hasSamples === false) return "--"

  var value = parseInt(percent, 10)
  if (!value || value < 0) return "0%"
  return value + "%"
}

function pingLatencyState(previous, next, limit, averageLimit) {
  var prev = previous || {}
  var sample = next || {}
  var iface = sample.iface || ""
  var window = Math.max(1, parseInt(limit, 10) || 5)
  var averageWindow = Math.max(1, parseInt(averageLimit, 10) || window)
  var reset = iface === "" || iface !== (prev.pingIface || "")
  var routerSamples = reset ? [] : prev.routerPingSamples
  var internetSamples = reset ? [] : prev.internetPingSamples

  routerSamples = sample.router_ping_ms === undefined ? [] : appendPingSample(routerSamples, sample.router_ping_ms, window)
  internetSamples = sample.internet_ping_ms === undefined ? [] : appendPingSample(internetSamples, sample.internet_ping_ms, window)

  return {
    pingIface: iface,
    routerPingSamples: routerSamples,
    internetPingSamples: internetSamples,
    routerPingLatency: averagePingLatency(routerSamples, averageWindow),
    internetPingLatency: averagePingLatency(internetSamples, averageWindow),
    internetPingPacketLoss: pingPacketLossPercent(internetSamples)
  }
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n < 1024) return Math.round(n) + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
  return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

// `hasSamples` false means no probe has come back yet, which is different from
// a probe that timed out. The rows stay mounted through that gap and read "--"
// so the grid doesn't reflow a second after the panel opens.
function formatPingLatency(ms, hasSamples) {
  if (hasSamples === false) return "--"

  var value = parseFloat(ms)
  if (!isFinite(value) || value < 0) return "Timeout"
  return value.toFixed(value > 0 && value < 10 ? 1 : 0) + " ms"
}

// --- Public (egress) address ------------------------------------------------
// scripts/omarchy-network-public-ip prints the bare address, but the value is
// formatted here so a failed lookup can never be mistaken for one: the row has
// to read "--"/"Checking…"/"Unavailable" rather than adopt whatever a captive
// portal or an error path happened to write on stdout.

// The bare dotted quad, or "" when the text is not one. Leading zeroes are
// tolerated (they are still the same octet) but anything that is not four
// in-range decimal octets -- an error page, a blank answer, an IPv6 address --
// is rejected.
function publicIpAddress(raw) {
  var text = String(raw || "").replace(/\r?\n+$/, "").trim()
  var parts = text.split(".")

  if (parts.length !== 4) return ""

  for (var i = 0; i < parts.length; i++) {
    if (!/^\d{1,3}$/.test(parts[i])) return ""
    if (parseInt(parts[i], 10) > 255) return ""
  }

  return text
}

// The value the details grid renders. An address always wins, so the row keeps
// showing what it knows while a later re-check is in flight. Without one,
// "Checking…" is a lookup in progress, "Unavailable" is a lookup that came
// back empty, and "--" is a lookup that has not run yet -- the same placeholder
// the ping and transfer rows use while they wait for their first sample.
function publicIpText(address, busy, failed) {
  var value = publicIpAddress(address)
  if (value !== "") return value
  if (busy) return "Checking…"
  if (failed) return "Unavailable"
  return "--"
}

function wifiRow(network) {
  if (!network) return null
  // Primitives only: rows become list-model data, so a WifiNetwork here puts a
  // live QObject wrapper in every delegate's var property. NetworkManager churn
  // (scans, AP removals) can destroy the object while a delegate is still
  // incubating, which segfaults quickshell in wrap_slowPath on the dangling
  // wrapper. Callers that need the object resolve it via networkForSsid().
  return {
    connected: !!network.connected,
    known: !!network.known,
    ssid: network.name || "",
    signal: Math.round((network.signalStrength || 0) * 100),
    security: network.security
  }
}

function sortWifiRows(rows) {
  var nets = Array.isArray(rows) ? rows.slice() : []
  nets.sort(function(a, b) {
    if (a.connected !== b.connected) return a.connected ? -1 : 1
    if (a.known !== b.known) return a.known ? -1 : 1
    return b.signal - a.signal
  })
  return nets
}

function wifiSectionTitle(wifiNetworks, index) {
  var networks = Array.isArray(wifiNetworks) ? wifiNetworks : []
  if (index < 0 || index >= networks.length) return ""

  var net = networks[index]
  if (!net) return ""

  if (net.known && index === 0) return "KNOWN NETWORKS"
  if (!net.known && (index === 0 || (networks[index - 1] && networks[index - 1].known))) return "OTHER NETWORKS"
  return ""
}

// OWE (Enhanced Open) encrypts traffic without authenticating the user, so it
// has no credentials to collect. The panel's lock is a credentials-required
// affordance, so OWE should neither show it nor open its attached prompt.
function requiresCredentials(security, openSecurity, oweSecurity) {
  // Only explicit passwordless types bypass the prompt. Unknown security
  // stays credentialed as the conservative fallback.
  return security !== openSecurity && security !== oweSecurity
}

function canForgetNetwork(network) {
  return !!(network && network.known && !network.connected)
}

// The password arrives on stdin and reaches nmcli through the scriptable
// `connection edit` editor -- argv is world-readable in /proc, so the secret
// must never be an argument (printf is a bash builtin, so no process spawns
// with it either).
var enterpriseConnectScript =
  "u=$(uuidgen); IFS= read -r pw;" +
  " nmcli connection add type wifi con-name \"$1\" ssid \"$1\" connection.uuid \"$u\"" +
  " wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2" +
  " 802-1x.identity \"$2\" 802-1x.auth-timeout 8 >/dev/null" +
  " && printf 'set 802-1x.password %s\\nsave\\nquit\\n' \"$pw\" | nmcli connection edit uuid \"$u\" >/dev/null" +
  " && nmcli connection up uuid \"$u\"" +
  " || { nmcli connection delete uuid \"$u\" >/dev/null 2>&1; false; }"

// Hidden-SSID connect. SSID is argv[1]; the passphrase (if any) arrives on
// stdin so it never appears in argv. An empty password means an open hidden
// network, so no wifi-sec section is created.
var hiddenConnectScript =
  "u=$(uuidgen); IFS= read -r pw;" +
  " nmcli connection delete id \"$1\" >/dev/null 2>&1 || true;" +
  " if [[ -n $pw ]]; then" +
  "   nmcli connection add type wifi con-name \"$1\" ssid \"$1\" 802-11-wireless.hidden yes" +
  "     wifi-sec.key-mgmt wpa-psk connection.uuid \"$u\" >/dev/null" +
  "     && printf 'set wifi-sec.psk %s\\nsave\\nquit\\n' \"$pw\" | nmcli connection edit uuid \"$u\" >/dev/null;" +
  " else" +
  "   nmcli connection add type wifi con-name \"$1\" ssid \"$1\" 802-11-wireless.hidden yes connection.uuid \"$u\" >/dev/null;" +
  " fi" +
  " && nmcli connection up uuid \"$u\"" +
  " || { nmcli connection delete uuid \"$u\" >/dev/null 2>&1; false; }"

function networkFailureReason(reason, needsCredentials, reasons) {
  var r = reasons || {}
  if (needsCredentials && reason === r.NoSecrets) return "Passphrase required"
  if (needsCredentials && reason === r.WifiAuthTimeout) return "Wrong password"
  if (reason === r.WifiNetworkLost) return "Network lost"
  if (reason === r.WifiClientDisconnected) return "Disconnected"
  if (reason === r.WifiClientFailed) return "Connection failed"
  return "Failed to connect"
}

// Whether a failed connect should reopen the passphrase prompt. NoSecrets
// means credentials are missing only for a network that actually uses them.
// An auth timeout on such a network means the saved passphrase is wrong (the
// same profile a first failed attempt leaves behind as "known"), so the user
// needs a chance to re-enter it -- connectWithPsk overwrites the stored PSK on
// submit.
function shouldRepromptPassphrase(reason, needsCredentials, reasons) {
  var r = reasons || {}
  if (!needsCredentials) return false
  return reason === r.NoSecrets || reason === r.WifiAuthTimeout
}

// --- IPv4 configuration rows -------------------------------------------------
// A wired NIC and the connected Wi-Fi network are configured through the same
// row, so the wording and the derived state live here instead of in the QML:
// wired rows answer to carrier, wireless rows only exist while the network is
// connected. Both builders return null when there is nothing to configure.

function ipv4StateText(state, linkPresent, wireless) {
  if (state === "connected") return "Connected"
  if (state === "connecting") return "Connecting"

  if (wireless) {
    if (state === "disconnected") return "Not connected"
    if (state) return state.charAt(0).toUpperCase() + state.slice(1)
    return "Unknown"
  }

  if (state === "unavailable") return "No cable"
  if (state === "disconnected") return linkPresent ? "Cable present" : "Disconnected"
  if (state) return state.charAt(0).toUpperCase() + state.slice(1)
  return "Unknown"
}

function ipv4DhcpButtonText(connected, linkPresent, wireless) {
  if (wireless) return connected ? "Apply DHCP & reconnect" : "Save DHCP"
  return (connected || linkPresent) ? "Apply DHCP & connect" : "Save DHCP"
}

function ipv4ApplyingText(connected, linkPresent, wireless) {
  if (connected) return "Applying…"
  if (wireless) return "Saving…"
  return linkPresent ? "Applying and connecting…" : "Saving…"
}

// "Saved" is the honest word when nothing is up to apply it to: the profile is
// written and takes effect on the next connect.
function ipv4AppliedText(connected, linkPresent, wireless) {
  return (wireless ? connected : linkPresent) ? "Applied" : "Saved"
}

function wiredNicRow(raw) {
  var row = raw || {}
  if (!row.device) return null

  var carrier = !!row.carrier
  var connected = row.state === "connected"

  return {
    key: row.device,
    name: row.device,
    kind: "wired",
    device: row.device,
    state: row.state || "",
    connected: connected,
    linkPresent: carrier,
    stateText: ipv4StateText(row.state, carrier, false),
    dhcpButtonText: ipv4DhcpButtonText(connected, carrier, false),
    applyingText: ipv4ApplyingText(connected, carrier, false),
    appliedText: ipv4AppliedText(connected, carrier, false),
    profile: row.profile || "",
    method: row.method || "auto",
    address: row.address || "",
    prefix: row.prefix || "",
    gateway: row.gateway || "",
    dns: row.dns || "",
    liveIp: row.liveIp || "",
    liveGateway: row.liveGateway || ""
  }
}

// `fields` is the key/value output of scripts/omarchy-network-wifi-ip show.
function wifiIpv4Row(fields) {
  var row = fields || {}
  if (!row.uuid) return null

  var connected = row.state === "connected"
  var live = String(row.live_ip || "")
  if (live !== "" && String(row.live_prefix || "") !== "") live += "/" + row.live_prefix

  return {
    key: row.uuid,
    name: row.ssid || row.device || row.uuid,
    kind: "wifi",
    device: row.device || "",
    state: row.state || "",
    connected: connected,
    // Wi-Fi has no cable to miss: the network is either the active one or it is
    // not offered at all.
    linkPresent: true,
    stateText: ipv4StateText(row.state, true, true),
    dhcpButtonText: ipv4DhcpButtonText(connected, true, true),
    applyingText: ipv4ApplyingText(connected, true, true),
    appliedText: ipv4AppliedText(connected, true, true),
    profile: row.ssid || "",
    method: row.method || "auto",
    address: row.address || "",
    prefix: row.prefix || "",
    gateway: row.gateway || "",
    dns: row.dns || "",
    liveIp: live,
    liveGateway: row.live_gateway || ""
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseNetworkStatus: parseNetworkStatus,
    wifiIconFor: wifiIconFor,
    connectionIcon: connectionIcon,
    formatHeaderSpeed: formatHeaderSpeed,
    formatHeaderFreq: formatHeaderFreq,
    headerDetail: headerDetail,
    bandLabel: bandLabel,
    bandSectionTitle: bandSectionTitle,
    bandTooltip: bandTooltip,
    parseBandStatus: parseBandStatus,
    decodeIwSsid: decodeIwSsid,
    parseKeyValue: parseKeyValue,
    throughputState: throughputState,
    pingLatencyState: pingLatencyState,
    pingPacketLossPercent: pingPacketLossPercent,
    formatPacketLoss: formatPacketLoss,
    formatBytes: formatBytes,
    formatRate: formatRate,
    formatPingLatency: formatPingLatency,
    publicIpAddress: publicIpAddress,
    publicIpText: publicIpText,
    ipv4StateText: ipv4StateText,
    ipv4DhcpButtonText: ipv4DhcpButtonText,
    ipv4ApplyingText: ipv4ApplyingText,
    ipv4AppliedText: ipv4AppliedText,
    wiredNicRow: wiredNicRow,
    wifiIpv4Row: wifiIpv4Row,
    wifiRow: wifiRow,
    sortWifiRows: sortWifiRows,
    wifiSectionTitle: wifiSectionTitle,
    requiresCredentials: requiresCredentials,
    canForgetNetwork: canForgetNetwork,
    enterpriseConnectScript: enterpriseConnectScript,
    hiddenConnectScript: hiddenConnectScript,
    networkFailureReason: networkFailureReason,
    shouldRepromptPassphrase: shouldRepromptPassphrase
  }
}
