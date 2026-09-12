#!/bin/bash

# The public (egress) address is the one detail in this panel that comes from
# outside the machine, so its contract is pinned here: which address is
# accepted, what happens when a provider is down or answers with a login page,
# and when the panel is allowed to ask. curl is stubbed, so this runs anywhere,
# needs no network, and cannot leak the machine's real address into a log.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  code=$?
  if ((code != 0)); then
    printf '%s\n' '--- curl log ---' >&2
    cat "$tmp/curl.log" >&2 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

: >"$tmp/curl.log"
export CURL_LOG="$tmp/curl.log"

cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
set -u

# Log enough to prove what was asked and how: the URL is the last argument, and
# the flags matter because an unbounded or IPv6 answer would describe a
# different egress than the row is claiming.
url=${!#}
printf 'args %s\n' "$*" >>"$CURL_LOG"
printf 'url %s\n' "$url" >>"$CURL_LOG"

mode=${CURL_MODE:-ok}

if [[ $mode == first-down && $url == *ipify* ]]; then
  exit 22
fi

case $mode in
  portal) printf '%s' '<html><body>Sign in to Wi-Fi</body></html>' ;;
  out-of-range) printf '%s' '999.1.1.1' ;;
  empty) ;;
  broken) exit 22 ;;
  *) printf '%s' "${CURL_ANSWER:-203.0.113.9}" ;;
esac
EOF
chmod +x "$tmp/bin/curl"

run_helper() {
  PATH="$tmp/bin:$PATH" "$root/scripts/omarchy-network-public-ip" "$@"
}

reset_curl() {
  : >"$tmp/curl.log"
  export CURL_MODE=$1
  export CURL_ANSWER=${2:-203.0.113.9}
}

# ------------------------------------------------------------ the answer ------

reset_curl ok
output=$(run_helper)
[[ $output == "203.0.113.9" ]] || fail "the helper prints the bare address" "$output"
pass "the helper prints the bare public address"

reset_curl ok $'  203.0.113.9 \n'
output=$(run_helper)
[[ $output == "203.0.113.9" ]] || fail "surrounding whitespace does not reach the panel" "$output"
pass "surrounding whitespace is trimmed"

grep -q -- '-4' "$tmp/curl.log" || fail "the lookup asks for the IPv4 egress"
grep -q -- '--max-time' "$tmp/curl.log" || fail "the lookup is bounded in time"
grep -q -- '--connect-timeout' "$tmp/curl.log" || fail "the connection attempt is bounded in time"
pass "the lookup is IPv4-only and cannot outlive the panel"

# A provider being down must not cost the row its value: anything else that
# answers is good enough.
reset_curl first-down 198.51.100.7
output=$(run_helper)
[[ $output == "198.51.100.7" ]] || fail "a dead provider falls through to the next one" "$output"
grep -q 'api.ipify.org' "$tmp/curl.log" || fail "the first provider is tried"
grep -q 'ifconfig.me' "$tmp/curl.log" || fail "the second provider is tried"
pass "a dead provider falls through to the next one"

# --------------------------------------------------- what is not an answer ----

for mode in portal out-of-range empty broken; do
  reset_curl "$mode"
  if output=$(run_helper 2>"$tmp/stderr"); then
    fail "$mode is not reported as a public address" "$output"
  fi
  [[ -z $output ]] || fail "$mode prints nothing on stdout" "$output"
  [[ -s "$tmp/stderr" ]] || fail "$mode explains itself on stderr"
  pass "$mode is refused instead of being shown as an address"
done

# A login page answers every provider the same way, so the failure has to be
# one failure and not a value from the last provider that replied.
reset_curl portal
if run_helper >/dev/null 2>&1; then
  fail "a captive portal is never mistaken for an address"
fi
[[ $(grep -c '^url ' "$tmp/curl.log") -eq 3 ]] \
  || fail "every provider is asked before giving up" "$(cat "$tmp/curl.log")"
pass "every provider is asked before the lookup gives up"

# --------------------------------------------------------- model contract ----

command -v node >/dev/null || fail "node is available to run the model checks"

PLUGIN_ROOT="$root" node <<'JS'
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

// The script's stdout is the only source, and it has to survive a trailing
// newline without carrying one into the row.
sameLine(Model.publicIpAddress('203.0.113.9\n'), '203.0.113.9', 'a trailing newline is not part of the address')
sameLine(Model.publicIpAddress('  198.51.100.7  '), '198.51.100.7', 'surrounding spaces are not part of the address')

// Anything that is not a bare in-range dotted quad is not an address -- least
// of all a captive portal's login page or an IPv6 answer.
sameLine(Model.publicIpAddress('<html><body>Sign in</body></html>'), '', 'a login page is not an address')
sameLine(Model.publicIpAddress('999.1.1.1'), '', 'an out-of-range octet is not an address')
sameLine(Model.publicIpAddress('2001:db8::1'), '', 'an IPv6 answer is not an IPv4 address')
sameLine(Model.publicIpAddress('192.168.0.'), '', 'a truncated address is not an address')
sameLine(Model.publicIpAddress(''), '', 'no answer reads empty')

// The display ladder: a known address wins over a re-check, and each "nothing
// yet" state is distinguishable from a failed lookup.
sameLine(Model.publicIpText('203.0.113.9', true, false), '203.0.113.9', 'a known address survives a re-check in flight')
sameLine(Model.publicIpText('203.0.113.9', false, true), '203.0.113.9', 'a known address is not hidden by a later failure')
sameLine(Model.publicIpText('', true, false), 'Checking…', 'a first lookup in flight reads as checking')
sameLine(Model.publicIpText('', false, true), 'Unavailable', 'a lookup that came back empty says so')
sameLine(Model.publicIpText('', false, false), '--', 'a lookup that has not run reads as a placeholder')

process.exit(failed ? 1 : 0)
JS

# --------------------------------------------------------- panel contract ----

panel=$root/Panel.qml

grep -q 'readonly property string publicIpScript' "$panel" \
  || fail "the panel owns the public IP helper"
pass "the panel looks the address up through the plugin's own helper"

grep -q 'id: publicIpProc' "$panel" || fail "the panel runs the helper"
awk '/id: publicIpProc/,/^  }/' "$panel" | grep -q 'command: \[root.publicIpScript\]' \
  || fail "the lookup process runs the helper"
grep -q 'root.updatePublicIp(text)' "$panel" \
  || fail "the panel parses the helper's answer through the model"
pass "the panel reads the helper's answer"

grep -q 'text: root.publicIpDisplay' "$panel" \
  || fail "the details grid shows the public address"
grep -q 'copyable: root.publicIp !== ""' "$panel" \
  || fail "the public address is copyable once there is one"
pass "the details grid shows and copies the public address"

# The grid's closing pair: the gateway probe the status helper has always
# collected is shown next to the egress address, which is the comparison that
# makes a tunnel visible.
grep -q 'text: "Router"' "$panel" \
  || fail "the router probe is shown beside the public address"
grep -q 'root.formatRouterLatency()' "$panel" \
  || fail "the router row reads the gateway probe the helper already collects"
pass "the closing pair shows the router probe beside the egress address"

# The row exists to answer "what is my egress right now", so a stale address is
# worse than an honest blank.
grep -q 'root.publicIp = ""' "$panel" \
  || fail "a failed lookup does not leave the previous address on screen"
pass "a failed lookup clears the address instead of showing a stale one"

# Refresh policy: on open, on an interface change, and on a slow tick -- but
# never during a link change, when the answer would describe the link that is
# going away.
grep -q 'id: publicIpPoll' "$panel" || fail "the panel re-checks the address"
awk '/id: publicIpPoll/,/^  }/' "$panel" | grep -q 'interval: 60000' \
  || fail "the re-check is slow enough not to hammer the provider"
awk '/id: publicIpPoll/,/^  }/' "$panel" | grep -q 'running: root.opened$' \
  || fail "the re-check only runs while the panel is open"
pass "the address is re-checked on a slow tick while the panel is open"

awk '/function refreshPublicIp/,/^  }/' "$panel" | grep -q 'if (!root.opened) return' \
  || fail "a closed panel never looks the address up"
awk '/function refreshPublicIp/,/^  }/' "$panel" | grep -q 'if (root.ipv4ApplyBusy || root.bandBusy) return' \
  || fail "a lookup is skipped while the link is changing"
awk '/function refreshPublicIp/,/^  }/' "$panel" | grep -q 'if (publicIpProc.running) return' \
  || fail "two lookups never overlap"
pass "the lookup is skipped while closed and while the link is changing"

grep -q 'root.publicIpIface' "$panel" \
  || fail "the panel watches the active interface for a reason to re-check"
awk '/target: root$/,/^  }/' "$panel" | grep -q 'function onInfoChanged' \
  || fail "the interface change is seen through the details sample"
pass "a changed interface re-checks the address"

awk '/onTextKey/,/^      }/' "$panel" | grep -q 'root.refreshPublicIp()' \
  || fail "the refresh shortcut re-checks the address too"
pass "the keyboard refresh re-checks the address"

printf '\npublic ip test: pass\n'
