#!/bin/bash

# The Wi-Fi IPv4 helper is what the panel's "WI-FI IPV4" section drives, so its
# contract is pinned here: which network it reports, what it writes into the
# NetworkManager profile, and how it applies the change. A method switch has to
# reactivate the connection (a reapply can leave the old address active), while
# an address change inside manual mode must stay associated and reapply.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  code=$?
  if ((code != 0)); then
    printf '%s\n' '--- nmcli log ---' >&2
    cat "$tmp/nmcli.log" >&2 || true
    printf '%s\n' '--- profile state ---' >&2
    cat "$tmp/state" >&2 || true
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

# name / ssid / method / addresses / gateway / dns / live address / active
profile_state() {
  printf 'TVU-manage\nTVU-manage\n%s\n%s\n%s\n%s\n%s\n%s\n' "$@"
}
profile_state auto "" "" "" "192.168.0.245/24" yes >"$tmp/state"
: >"$tmp/nmcli.log"

cat >"$tmp/bin/nmcli" <<'EOF'
#!/bin/bash
set -euo pipefail

mapfile -t state <"$NM_STATE_FILE"
name=${state[0]}
ssid=${state[1]}
method=${state[2]}
addresses=${state[3]}
gateway=${state[4]}
dns=${state[5]}
live=${state[6]}
active=${state[7]}

joined=" $* "
printf 'call %s\n' "$*" >>"$NM_LOG"

save() {
  printf '%s\n' "$name" "$ssid" "$method" "$addresses" "$gateway" "$dns" "$live" "$active" >"$NM_STATE_FILE"
}

if [[ $joined == *" -t -f DEVICE,TYPE,STATE device status "* ]]; then
  # Only report the Wi-Fi device while a Wi-Fi network is in use; NM_WIFI_DEVICE=off
  # models a machine that is not connected to Wi-Fi at all.
  [[ ${NM_WIFI_DEVICE:-on} == on ]] || exit 0
  if [[ $active == yes ]]; then printf 'wlp5s0:wifi:connected\n'; else printf 'wlp5s0:wifi:disconnected\n'; fi
  exit 0
fi

if [[ $joined == *" -g GENERAL.CON-UUID device show wlp5s0 "* ]]; then
  [[ $active == yes ]] && echo "$NM_UUID"
  exit 0
fi

if [[ $joined == *" -g connection.type connection show uuid "* ]]; then
  uuid=${@: -1}
  [[ $uuid == "$NM_UUID" ]] && echo 802-11-wireless || echo 802-3-ethernet
  exit 0
fi

if [[ $joined == *" -g 802-11-wireless.ssid connection show uuid "* ]]; then
  echo "$ssid"
  exit 0
fi

if [[ $joined == *" -g ipv4.method connection show uuid "* ]]; then
  echo "$method"
  exit 0
fi

if [[ $joined == *" -g ipv4.addresses connection show uuid "* ]]; then
  [[ -n $addresses ]] && echo "$addresses"
  exit 0
fi

if [[ $joined == *" -g ipv4.gateway connection show uuid "* ]]; then
  [[ -n $gateway ]] && echo "$gateway"
  exit 0
fi

if [[ $joined == *" -g ipv4.dns connection show uuid "* ]]; then
  [[ -n $dns ]] && echo "$dns"
  exit 0
fi

if [[ $joined == *" -g IP4.ADDRESS device show wlp5s0 "* ]]; then
  [[ $active == yes && -n $live ]] && echo "$live"
  exit 0
fi

if [[ $joined == *" -g IP4.GATEWAY device show wlp5s0 "* ]]; then
  [[ $active == yes && -n $gateway ]] && echo "$gateway"
  exit 0
fi

if [[ $joined == *" -g DHCP4.OPTION device show wlp5s0 "* ]]; then
  [[ $active == yes && $method == auto ]] && echo 'ip_address = 192.168.0.245'
  exit 0
fi

if [[ $joined == *" connection modify uuid "* ]]; then
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
      ipv4.method) method=${args[i + 1]} ;;
      ipv4.addresses) addresses=${args[i + 1]} ;;
      ipv4.gateway) gateway=${args[i + 1]} ;;
      ipv4.dns) dns=${args[i + 1]} ;;
    esac
  done
  # Writing the profile is not the applied state: NM keeps running the previous
  # configuration until the connection is reapplied or reactivated.
  save
  printf -- '---\n' >>"$NM_LOG"
  exit 0
fi

if [[ $joined == *" connection down uuid "* ]]; then
  active=no
  save
  echo down >>"$NM_LOG"
  exit 0
fi

if [[ $joined == *" connection up uuid "* ]]; then
  active=yes
  live=''
  [[ $method == manual ]] && live=$addresses
  [[ $method == auto ]] && live='192.168.0.245/24'
  save
  echo up >>"$NM_LOG"
  exit 0
fi

if [[ $joined == *" device reapply wlp5s0 "* ]]; then
  if [[ ${NM_REAPPLY_NOOP:-no} == no ]]; then
    live=''
    [[ $method == manual ]] && live=$addresses
    [[ $method == auto ]] && live='192.168.0.245/24'
  fi
  save
  echo reapply >>"$NM_LOG"
  exit 0
fi

exit 0
EOF
chmod +x "$tmp/bin/nmcli"

export NM_STATE_FILE="$tmp/state"
export NM_LOG="$tmp/nmcli.log"
export NM_UUID=872f00a9-f933-4cae-ad6e-5fb8cb2a1d63

run_helper() {
  PATH="$tmp/bin:$PATH" "$root/scripts/omarchy-network-wifi-ip" "$@"
}

reset_profile() {
  profile_state "$@" >"$tmp/state"
  : >"$tmp/nmcli.log"
}

# The stub logs each nmcli call on one line, so a modify reads as a single
# argument list with the values in it.
modify_line() {
  grep -m1 ' connection modify uuid ' "$tmp/nmcli.log" || true
}

# ------------------------------------------------------------------- show --

reset_profile auto "" "" "" "192.168.0.245/24" yes
output=$(run_helper show)
[[ $output == *$'uuid\t872f00a9-f933-4cae-ad6e-5fb8cb2a1d63'* ]] \
  || fail "wifi ip show reports the connected profile" "$output"
[[ $output == *$'ssid\tTVU-manage'* ]] \
  || fail "wifi ip show reports the SSID" "$output"
[[ $output == *$'method\tauto'* && $output == *$'live_ip\t192.168.0.245'* ]] \
  || fail "wifi ip show reports DHCP and the live address" "$output"
pass "wifi ip show reports the connected network and its live IPv4 state"

reset_profile manual "10.0.0.5/24" "10.0.0.1" "1.1.1.1" "10.0.0.5/24" yes
output=$(run_helper show)
[[ $output == *$'method\tmanual'* && $output == *$'address\t10.0.0.5'* && $output == *$'prefix\t24'* ]] \
  || fail "wifi ip show reports a saved static address" "$output"
[[ $output == *$'gateway\t10.0.0.1'* && $output == *$'dns\t1.1.1.1'* ]] \
  || fail "wifi ip show reports the saved gateway and DNS" "$output"
pass "wifi ip show reports the saved static configuration"

export NM_WIFI_DEVICE=off
output=$(run_helper show)
unset NM_WIFI_DEVICE
[[ -z $output ]] \
  || fail "wifi ip show stays silent when no Wi-Fi network is in use" "$output"
pass "wifi ip show stays silent when no Wi-Fi network is in use"

# ---------------------------------------------------------- dhcp -> manual --

reset_profile auto "" "" "" "192.168.0.245/24" yes
run_helper set "$NM_UUID" manual 192.168.0.245 24 192.168.0.254 192.168.0.254 >/dev/null

modify=$(modify_line)
[[ $modify == *" ipv4.method manual "* ]] \
  || fail "wifi ip set manual switches the profile to manual" "$modify"
[[ $modify == *" ipv4.addresses 192.168.0.245/24 "* ]] \
  || fail "wifi ip set manual writes the static address" "$modify"
[[ $modify == *" ipv4.gateway 192.168.0.254 "* && $modify == *" ipv4.dns 192.168.0.254 "* ]] \
  || fail "wifi ip set manual writes the gateway and DNS" "$modify"
[[ $modify == *" ipv4.ignore-auto-dns yes"* ]] \
  || fail "wifi ip set manual stops DHCP from overriding the static DNS" "$modify"
grep -qx down "$tmp/nmcli.log" || fail "wifi ip set manual reactivates instead of reapplying"
grep -qx up "$tmp/nmcli.log" || fail "wifi ip set manual brings the network back up"
mapfile -t state <"$tmp/state"
[[ ${state[2]} == manual && ${state[6]} == 192.168.0.245/24 && ${state[7]} == yes ]] \
  || fail "wifi ip set manual leaves the network connected on the new address" "${state[*]}"
pass "wifi ip set manual switches DHCP to a static address and reactivates the network"

# ------------------------------------------------ manual -> manual (reapply) --

reset_profile manual "10.0.0.5/24" "10.0.0.1" "" "10.0.0.5/24" yes
run_helper set "$NM_UUID" manual 10.0.0.6 24 10.0.0.1 >/dev/null
grep -qx reapply "$tmp/nmcli.log" || fail "wifi ip set manual reapplies an in-place change"
! grep -qx down "$tmp/nmcli.log" \
  || fail "wifi ip set manual keeps the Wi-Fi association when only the address changes"
mapfile -t state <"$tmp/state"
[[ ${state[3]} == 10.0.0.6/24 && ${state[6]} == 10.0.0.6/24 ]] \
  || fail "wifi ip set manual applies the new address" "${state[*]}"
pass "wifi ip set manual reapplies an address change without reassociating"

# ------------------------------------------------- a reapply that does not take --

reset_profile manual "10.0.0.5/24" "10.0.0.1" "" "10.0.0.5/24" yes
export NM_REAPPLY_NOOP=yes
run_helper set "$NM_UUID" manual 10.0.0.7 24 10.0.0.1 >/dev/null
unset NM_REAPPLY_NOOP
grep -qx up "$tmp/nmcli.log" \
  || fail "wifi ip set manual falls back to reactivation when reapply does not take effect"
mapfile -t state <"$tmp/state"
[[ ${state[6]} == 10.0.0.7/24 ]] \
  || fail "wifi ip set manual lands on the requested address after the fallback" "${state[*]}"
pass "wifi ip set manual does not report success from a reapply that did not take effect"

# ---------------------------------------------------------- manual -> dhcp --

reset_profile manual "10.0.0.5/24" "10.0.0.1" "1.1.1.1" "10.0.0.5/24" yes
run_helper set "$NM_UUID" dhcp >/dev/null
modify=$(modify_line)
[[ $modify == *" ipv4.method auto "* ]] \
  || fail "wifi ip set dhcp switches the profile back to automatic" "$modify"
# Cleared values arrive as empty arguments, which the single-line log shows as
# a doubled space before the next key.
[[ $modify == *" ipv4.addresses  ipv4.gateway "* ]] \
  || fail "wifi ip set dhcp clears the static address" "$modify"
[[ $modify == *" ipv4.gateway  ipv4.dns "* ]] \
  || fail "wifi ip set dhcp clears the static gateway" "$modify"
[[ $modify == *" ipv4.ignore-auto-dns no"* ]] \
  || fail "wifi ip set dhcp lets DHCP supply DNS again" "$modify"
grep -qx down "$tmp/nmcli.log" || fail "wifi ip set dhcp reactivates the network"
grep -qx up "$tmp/nmcli.log" || fail "wifi ip set dhcp brings the network back up"
mapfile -t state <"$tmp/state"
[[ ${state[2]} == auto && ${state[6]} == 192.168.0.245/24 ]] \
  || fail "wifi ip set dhcp obtains a DHCP lease again" "${state[*]}"
pass "wifi ip set dhcp switches back to DHCP and re-leases"

# --------------------------------------------------------- network not in use --

reset_profile manual "10.0.0.5/24" "10.0.0.1" "" "10.0.0.5/24" no
run_helper set "$NM_UUID" dhcp >/dev/null
! grep -qx down "$tmp/nmcli.log" || fail "wifi ip set dhcp does not touch a network that is not in use"
! grep -qx up "$tmp/nmcli.log" || fail "wifi ip set dhcp does not activate a network that is not in use"
mapfile -t state <"$tmp/state"
[[ ${state[2]} == auto ]] \
  || fail "wifi ip set dhcp still saves the profile of a network that is not in use" "${state[*]}"
pass "wifi ip set dhcp saves the profile of a network that is not in use"

# ------------------------------------------------------------ argument guards --

reset_profile auto "" "" "" "192.168.0.245/24" yes
if run_helper set "$NM_UUID" manual >/dev/null 2>&1; then
  fail "wifi ip set manual without an address is refused"
fi
! grep -q ' connection modify uuid ' "$tmp/nmcli.log" \
  || fail "wifi ip set manual without an address writes nothing"
! grep -qx down "$tmp/nmcli.log" \
  || fail "wifi ip set manual without an address does not touch the running network"
pass "wifi ip set manual without an address is refused before anything is written"

if run_helper set not-a-uuid dhcp >/dev/null 2>&1; then
  fail "wifi ip set refuses a profile that is not Wi-Fi"
fi
pass "wifi ip set refuses a profile that is not Wi-Fi"

# ------------------------------------------------------------ panel contract --

panel=$root/Panel.qml

grep -q 'readonly property bool hasWifiIpv4: wifiIpv4 !== null' "$panel" \
  || fail "panel offers the Wi-Fi IPv4 section only while a network is in use"

grep -q 'visible: root.hasWifiIpv4' "$panel" \
  || fail "panel hides the Wi-Fi IPv4 section with the same switch"
pass "panel gates the Wi-Fi IPv4 section on the connected network"

grep -q 'function updateWifiIpv4(raw)' "$panel" \
  || fail "panel parses the helper's output into the Wi-Fi row"
grep -q 'Model.wifiIpv4Row(Model.parseKeyValue(raw))' "$panel" \
  || fail "panel builds the Wi-Fi row from the helper's key/value output"
pass "panel builds the Wi-Fi row from the helper's output"

# A Wi-Fi reactivation drops the connection for a few seconds. A poller that
# stopped with it would leave the section gone for good -- this is the bug the
# section once had.
grep -q 'id: wifiIpPoll' "$panel" \
  || fail "panel polls the Wi-Fi IPv4 state"
awk '/id: wifiIpPoll/,/^  }/' "$panel" | grep -q 'running: root.opened$' \
  || fail "the Wi-Fi IPv4 poller keeps running while the panel is open, not only while a network is reported"
pass "the Wi-Fi IPv4 poller survives a reactivation"

grep -q 'onApplied:' "$panel" \
  || fail "panel refreshes the Wi-Fi row after an apply"
grep -q 'root.refreshWifiIpv4(true)' "$panel" \
  || fail "panel reloads the Wi-Fi row's saved state after an apply"
pass "panel reloads the Wi-Fi row after an apply"

grep -q 'function infoSignature()' "$root/Ipv4ConfigRow.qml" \
  || fail "the shared row can tell a saved change from a draft"
grep -q 'if (draftDirty || editing || busy) return' "$root/Ipv4ConfigRow.qml" \
  || fail "the shared row never overwrites a draft with a saved change"
grep -q 'text: Model.ipv4ModeLabel(ipv4Row.manualMode, ipv4Row.manualSaved)' "$root/Ipv4ConfigRow.qml" \
  || fail "the mode header states the saved mode, not a staged flip"
pass "the shared row follows saved changes and protects drafts"

printf '\nwifi ipv4 test: pass\n'
