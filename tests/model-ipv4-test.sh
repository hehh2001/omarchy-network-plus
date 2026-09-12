#!/bin/bash

# The wired NIC list and the Wi-Fi IPv4 section share one row component, so the
# wording and the state they show are derived in Model.js. These cases pin that
# derivation without needing a network, a NIC, or a shell.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export PLUGIN_ROOT="$root"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v node >/dev/null || fail "node is available to run the model checks"

node <<'JS'
const path = require('path')
const Model = require(path.join(process.env.PLUGIN_ROOT, 'Model.js'))

let failed = false

function sameLine(actual, expected, description) {
  if (actual === expected) {
    console.log(`ok - ${description}`)
    return
  }
  console.error(`not ok - ${description}`)
  console.error(`expected: ${JSON.stringify(expected)}`)
  console.error(`actual:   ${JSON.stringify(actual)}`)
  failed = true
}

function isTrue(condition, description, detail) {
  if (condition) {
    console.log(`ok - ${description}`)
    return
  }
  console.error(`not ok - ${description}`)
  if (detail !== undefined) console.error(`actual: ${JSON.stringify(detail)}`)
  failed = true
}

// --- wired rows --------------------------------------------------------------

sameLine(Model.ipv4StateText('connected', true, false), 'Connected', 'a connected NIC reads Connected')
sameLine(Model.ipv4StateText('disconnected', true, false), 'Cable present', 'a NIC with a cable reads Cable present')
sameLine(Model.ipv4StateText('disconnected', false, false), 'Disconnected', 'a NIC without a cable reads Disconnected')
sameLine(Model.ipv4StateText('unavailable', false, false), 'No cable', 'an unavailable NIC reads No cable')
sameLine(Model.ipv4StateText('connecting', false, false), 'Connecting', 'a NIC coming up reads Connecting')

sameLine(Model.ipv4DhcpButtonText(true, false, false), 'Apply DHCP & connect', 'a connected NIC applies DHCP and connects')
sameLine(Model.ipv4DhcpButtonText(false, true, false), 'Apply DHCP & connect', 'a NIC with a cable applies DHCP and connects')
sameLine(Model.ipv4DhcpButtonText(false, false, false), 'Save DHCP', 'a NIC without a cable only saves DHCP')
sameLine(Model.ipv4ApplyingText(true, false, false), 'Applying…', 'an apply on a connected NIC reads Applying')
sameLine(Model.ipv4ApplyingText(false, true, false), 'Applying and connecting…', 'an apply on a cabled NIC connects')
sameLine(Model.ipv4ApplyingText(false, false, false), 'Saving…', 'an apply on a NIC without a cable only saves')
sameLine(Model.ipv4AppliedText(false, true, false), 'Applied', 'a cabled NIC is Applied')
sameLine(Model.ipv4AppliedText(false, false, false), 'Saved', 'a NIC without a cable is only Saved')

const wired = Model.wiredNicRow({
  device: 'enp9s0u2u1',
  carrier: true,
  state: 'connected',
  profile: 'Wired dock',
  method: 'manual',
  address: '10.0.0.5',
  prefix: '24',
  gateway: '10.0.0.1',
  dns: '1.1.1.1',
  liveIp: '10.0.0.5/24',
  liveGateway: '10.0.0.1'
})

isTrue(wired !== null, 'a wired row is built from helper output')
sameLine(wired.key, 'enp9s0u2u1', 'the wired row keys on the device name')
sameLine(wired.name, 'enp9s0u2u1', 'the wired row shows the device name')
sameLine(wired.kind, 'wired', 'the wired row knows it is wired')
sameLine(wired.stateText, 'Connected', 'the wired row carries its state text')
sameLine(wired.connected, true, 'the wired row carries the connected flag')
sameLine(wired.linkPresent, true, 'the wired row carries the carrier flag')
sameLine(wired.dhcpButtonText, 'Apply DHCP & connect', 'the wired row carries its DHCP action text')
sameLine(wired.appliedText, 'Applied', 'the wired row carries its applied text')
sameLine(wired.method, 'manual', 'the wired row keeps the saved mode')
sameLine(wired.address, '10.0.0.5', 'the wired row keeps the saved address')
sameLine(wired.liveIp, '10.0.0.5/24', 'the wired row keeps the live address')
sameLine(Model.wiredNicRow({ carrier: false, state: 'disconnected' }), null, 'a wired row needs a device name')
sameLine(Model.wiredNicRow(null), null, 'a wired row tolerates missing input')

// --- wifi rows ---------------------------------------------------------------

const wifi = Model.wifiIpv4Row({
  device: 'wlp5s0',
  uuid: '872f00a9-f933-4cae-ad6e-5fb8cb2a1d63',
  ssid: 'TVU-manage',
  state: 'connected',
  method: 'manual',
  address: '192.168.0.245',
  prefix: '24',
  gateway: '192.168.0.254',
  dns: '192.168.0.254',
  live_ip: '192.168.0.245',
  live_prefix: '24',
  live_gateway: '192.168.0.254'
})

isTrue(wifi !== null, 'a wifi row is built from helper output')
sameLine(wifi.key, '872f00a9-f933-4cae-ad6e-5fb8cb2a1d63', 'the wifi row keys on the profile UUID')
sameLine(wifi.name, 'TVU-manage', 'the wifi row shows the SSID')
sameLine(wifi.kind, 'wifi', 'the wifi row knows it is wireless')
sameLine(wifi.profile, 'TVU-manage', 'the wifi row names the profile after the SSID')
sameLine(wifi.liveIp, '192.168.0.245/24', 'the wifi row joins the live address and prefix')
sameLine(wifi.stateText, 'Connected', 'the wifi row carries its state text')
sameLine(wifi.linkPresent, true, 'a wifi row is always on a live link')
sameLine(wifi.dhcpButtonText, 'Apply DHCP & reconnect', 'the wifi row reconnects when applying DHCP')
sameLine(wifi.appliedText, 'Applied', 'the wifi row reports Applied while connected')

sameLine(Model.ipv4StateText('disconnected', true, true), 'Not connected', 'a wifi row without the network reads Not connected')

const wifiDhcp = Model.wifiIpv4Row({
  device: 'wlp5s0',
  uuid: 'uuid',
  ssid: 'Cafe',
  state: 'connected',
  method: 'auto',
  live_ip: '192.168.1.5',
  live_prefix: ''
})

sameLine(wifiDhcp.method, 'auto', 'a DHCP wifi row keeps the automatic mode')
sameLine(wifiDhcp.liveIp, '192.168.1.5', 'a wifi row without a prefix keeps the bare address')
sameLine(wifiDhcp.dhcpButtonText, 'Apply DHCP & reconnect', 'a DHCP wifi row offers to reapply DHCP')

const wifiOffline = Model.wifiIpv4Row({ uuid: 'uuid', ssid: 'Cafe', state: 'disconnected', method: 'manual' })
sameLine(wifiOffline.dhcpButtonText, 'Save DHCP', 'a wifi row that is not connected only saves DHCP')
sameLine(wifiOffline.appliedText, 'Saved', 'a wifi row that is not connected reports Saved')

sameLine(Model.wifiIpv4Row({ device: 'wlp5s0', ssid: 'Cafe' }), null, 'a wifi row needs a profile UUID')
sameLine(Model.wifiIpv4Row(null), null, 'a wifi row tolerates missing input')

if (failed) process.exit(1)
JS

pass "model ipv4 rows derive the wired and Wi-Fi wording and state"

printf '\nmodel ipv4 test: pass\n'
