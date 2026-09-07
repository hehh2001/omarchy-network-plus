#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  code=$?
  if ((code != 0)); then
    printf '%s\n' '--- nmcli log ---' >&2
    cat "$tmp/nmcli.log" >&2 || true
    printf '%s\n' '--- mock state ---' >&2
    cat "$tmp/state" >&2 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"

printf 'auto\nauto\n192.168.1.77/24\nyes\n' >"$tmp/state"
: >"$tmp/nmcli.log"

cat >"$tmp/bin/nmcli" <<'EOF'
#!/bin/bash
set -euo pipefail

mapfile -t state <"$NM_STATE_FILE"
stored=${state[0]}
applied=${state[1]}
address=${state[2]}
connected=${state[3]}
joined=" $* "
printf 'call %s\n' "$*" >>"$NM_LOG"

save() {
  printf '%s\n%s\n%s\n%s\n' "$stored" "$applied" "$address" "$connected" >"$NM_STATE_FILE"
}

if [[ $joined == *" DEVICE,TYPE,STATE device status "* ]]; then
  printf 'lo:ethernet:%s\n' "$([[ $connected == yes ]] && echo connected || echo disconnected)"
elif [[ $joined == *" -g GENERAL.CON-UUID device show lo "* ]]; then
  [[ $connected == yes ]] && echo '11111111-1111-1111-1111-111111111111'
elif [[ $joined == *" -g connection.id connection show uuid "* ]]; then
  echo 'Wired test'
elif [[ $joined == *" -g ipv4.method connection show uuid "* ]]; then
  echo "$stored"
elif [[ $joined == *" -g IP4.ADDRESS device show lo "* ]]; then
  [[ $connected == yes ]] && echo "$address"
elif [[ $joined == *" -g DHCP4.OPTION device show lo "* ]]; then
  [[ $connected == yes && $applied == auto ]] && echo 'ip_address = 192.168.1.77'
elif [[ $joined == *" connection modify uuid "* ]]; then
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ ${args[i]} == ipv4.method ]]; then stored=${args[i + 1]}; fi
    if [[ ${args[i]} == ipv4.addresses ]]; then address=${args[i + 1]}; fi
  done
  save
  printf 'modify %s\n' "$stored" >>"$NM_LOG"
elif [[ $joined == *" connection down uuid "* ]]; then
  connected=no
  save
  echo down >>"$NM_LOG"
elif [[ $joined == *" connection up uuid "* ]]; then
  connected=yes
  applied=$stored
  [[ $stored == auto ]] && address='192.168.1.77/24'
  save
  echo up >>"$NM_LOG"
elif [[ $joined == *" device reapply lo "* ]]; then
  applied=$stored
  save
  echo reapply >>"$NM_LOG"
fi
EOF

cat >"$tmp/bin/cat" <<'EOF'
#!/bin/bash
if [[ ${1:-} == /sys/class/net/lo/carrier ]]; then
  echo 1
else
  exec /usr/bin/cat "$@"
fi
EOF

chmod +x "$tmp/bin/nmcli" "$tmp/bin/cat"
export NM_STATE_FILE="$tmp/state"
export NM_LOG="$tmp/nmcli.log"

PATH="$tmp/bin:$PATH" "$root/scripts/omarchy-network-eth-config" set lo manual 10.0.0.5 24 10.0.0.1
grep -qx down "$NM_LOG"
grep -qx up "$NM_LOG"
mapfile -t state <"$NM_STATE_FILE"
[[ ${state[0]} == manual && ${state[1]} == manual && ${state[2]} == 10.0.0.5/24 && ${state[3]} == yes ]]

: >"$NM_LOG"
PATH="$tmp/bin:$PATH" "$root/scripts/omarchy-network-eth-config" set lo manual 10.0.0.6 24 10.0.0.1
grep -qx reapply "$NM_LOG"
! grep -qx down "$NM_LOG"
! grep -qx up "$NM_LOG"
mapfile -t state <"$NM_STATE_FILE"
[[ ${state[0]} == manual && ${state[1]} == manual && ${state[2]} == 10.0.0.6/24 && ${state[3]} == yes ]]

: >"$NM_LOG"
PATH="$tmp/bin:$PATH" "$root/scripts/omarchy-network-eth-config" set lo dhcp
grep -qx down "$NM_LOG"
grep -qx up "$NM_LOG"
mapfile -t state <"$NM_STATE_FILE"
[[ ${state[0]} == auto && ${state[1]} == auto && ${state[2]} == 192.168.1.77/24 && ${state[3]} == yes ]]

echo 'network switch test: pass'
