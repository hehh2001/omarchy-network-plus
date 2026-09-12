#!/bin/bash

# The wired NIC section must only exist while a real, attached NIC does. These
# cases pin the two ways that promise broke in the field:
#   - NetworkManager still lists a device whose hardware is gone
#   - Apple T2 Macs always expose a virtual "Apple T2 Controller" Ethernet
#     gadget, which reports carrier=1 and never passes traffic
# plus the panel side: the section is gated on the helper's list, and a NIC that
# disappears takes its uncommitted draft state with it.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
  code=$?
  if ((code != 0)); then
    printf '%s\n' '--- helper output for both fixtures ---' >&2
    cat "$tmp/out-all" "$tmp/out-none" >&2 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/sys/class/net" "$tmp/devices"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# ---------------------------------------------------------------- fixtures --

# A real USB Ethernet adapter (the dock NIC) with hardware behind it.
nic_dir=$tmp/sys/class/net/enp9s0u2u1
mkdir -p "$nic_dir" "$tmp/devices/pci0000:00/0000:00:14.0/usb9/9-2/9-2:1.0"
printf '1\n' >"$nic_dir/carrier"
ln -s "$tmp/devices/pci0000:00/0000:00:14.0/usb9/9-2/9-2:1.0" "$nic_dir/device"
printf '0bda\n' >"$tmp/devices/pci0000:00/0000:00:14.0/usb9/9-2/idVendor"
printf '8153\n' >"$tmp/devices/pci0000:00/0000:00:14.0/usb9/9-2/idProduct"

# Apple T2 bridge Ethernet: alive, carrier=1, on the T2's virtual USB bus.
t2_dir=$tmp/sys/class/net/enp4s0f1u1
mkdir -p "$t2_dir" "$tmp/devices/pci0000:00/0000:04:00.1/t2bce_core/t2bce_core/t2bce_vhci/usb7/7-1/7-1:1.0"
printf '1\n' >"$t2_dir/carrier"
ln -s "$tmp/devices/pci0000:00/0000:04:00.1/t2bce_core/t2bce_core/t2bce_vhci/usb7/7-1/7-1:1.0" "$t2_dir/device"
printf '05ac\n' >"$tmp/devices/pci0000:00/0000:04:00.1/t2bce_core/t2bce_core/t2bce_vhci/usb7/7-1/idVendor"
printf '8233\n' >"$tmp/devices/pci0000:00/0000:04:00.1/t2bce_core/t2bce_core/t2bce_vhci/usb7/7-1/idProduct"

# The same gadget on a kernel that does not name the bus path t2bce*: the USB
# descriptors alone have to be enough to spot it.
t2_alt_dir=$tmp/sys/class/net/t2nic0
mkdir -p "$t2_alt_dir" "$tmp/devices/usb8/8-1/8-1:1.0"
printf '1\n' >"$t2_alt_dir/carrier"
ln -s "$tmp/devices/usb8/8-1/8-1:1.0" "$t2_alt_dir/device"
printf '05ac\n' >"$tmp/devices/usb8/8-1/idVendor"
printf '8233\n' >"$tmp/devices/usb8/8-1/idProduct"

# An adapter that was unplugged: NetworkManager still has the device, but the
# kernel interface has no device behind it any more (dangling symlink).
ghost_dir=$tmp/sys/class/net/enp0s0
mkdir -p "$ghost_dir"
printf '0\n' >"$ghost_dir/carrier"
ln -s "$tmp/devices/gone-enp0s0/0-1:1.0" "$ghost_dir/device"

# A link with no device node of its own. Thunderbolt IP links look like this
# and are real wired links, so they must survive the hardware check.
mkdir -p "$tmp/sys/class/net/thunderbolt0"
printf '1\n' >"$tmp/sys/class/net/thunderbolt0/carrier"

# A virtual link that NetworkManager reports as a bridge, not as Ethernet.
mkdir -p "$tmp/sys/class/net/br0"
printf '1\n' >"$tmp/sys/class/net/br0/carrier"

# A real NIC that NetworkManager explicitly does not manage.
unm_dir=$tmp/sys/class/net/unm0
mkdir -p "$unm_dir" "$tmp/devices/usb5/5-1/5-1:1.0"
printf '1\n' >"$unm_dir/carrier"
ln -s "$tmp/devices/usb5/5-1/5-1:1.0" "$unm_dir/device"

cat >"$tmp/bin/nmcli" <<'EOF'
#!/bin/bash

# Only the fields the helper asks for, from a fixed inventory: one managed dock
# NIC bound to a saved profile, a Thunderbolt IP link, the devices that must
# never reach the panel, and one unmanaged NIC.
joined=" $* "

if [[ $joined == *" -t -f DEVICE,TYPE,STATE device status "* ]]; then
  printf '%s\n' "${NM_DEVICES}"
  exit 0
fi

if [[ $joined == *" -g UUID,TYPE connection show "* ]]; then
  printf 'd726899a-216d-3027-ab9d-cda18f141137:802-3-ethernet\n'
  exit 0
fi

if [[ $joined == *" -g GENERAL.CON-UUID device show enp9s0u2u1 "* ]]; then
  printf 'd726899a-216d-3027-ab9d-cda18f141137\n'
  exit 0
fi

if [[ $joined == *" -g connection.interface-name connection show uuid "* ]]; then
  printf 'enp9s0u2u1\n'
  exit 0
fi

if [[ $joined == *" -g connection.id connection show uuid "* ]]; then
  printf 'Wired dock\n'
  exit 0
fi

if [[ $joined == *" -g connection.autoconnect connection show uuid "* ]]; then
  printf 'yes\n'
  exit 0
fi

if [[ $joined == *" -g ipv4.method connection show uuid "* ]]; then
  printf 'auto\n'
  exit 0
fi

exit 0
EOF
chmod +x "$tmp/bin/nmcli"

export NM_DEVICES
export OMARCHY_NET_SYSFS="$tmp/sys/class/net"

run_list() {
  PATH="$tmp/bin:$PATH" "$root/scripts/omarchy-network-eth-config" list
}

# ------------------------------------------------- both fixtures' device list --
NM_DEVICES=$'enp9s0u2u1:ethernet:connected\n'
NM_DEVICES+=$'enp4s0f1u1:ethernet:disconnected\n'
NM_DEVICES+=$'t2nic0:ethernet:disconnected\n'
NM_DEVICES+=$'enp0s0:ethernet:disconnected\n'
NM_DEVICES+=$'thunderbolt0:ethernet:connected\n'
NM_DEVICES+=$'br0:bridge:connected\n'
NM_DEVICES+=$'unm0:ethernet:unmanaged\n'
NM_DEVICES+=$'wlp5s0:wifi:connected\n'

output=$(run_list)
printf '%s\n' "$output" >"$tmp/out-all"

[[ $output == *$'enp9s0u2u1\t1\tconnected\tWired dock\tauto'* ]] \
  || fail "wired NIC detection lists a real attached NIC with its profile" "output: $output"
pass "wired NIC detection lists a real attached NIC with its profile"

[[ $output != *enp4s0f1u1* ]] \
  || fail "wired NIC detection drops the Apple T2 bridge Ethernet" "output: $output"
pass "wired NIC detection drops the Apple T2 bridge Ethernet"

[[ $output != *t2nic0* ]] \
  || fail "wired NIC detection drops the T2 gadget identified by USB descriptors" "output: $output"
pass "wired NIC detection drops the T2 gadget identified by USB descriptors"

[[ $output != *enp0s0* ]] \
  || fail "wired NIC detection drops a device whose hardware was unplugged" "output: $output"
pass "wired NIC detection drops a device whose hardware was unplugged"

[[ $output == *thunderbolt0* ]] \
  || fail "wired NIC detection keeps a real link that has no device node" "output: $output"
pass "wired NIC detection keeps a real link that has no device node"

[[ $output != *br0* ]] \
  || fail "wired NIC detection skips non-Ethernet device types" "output: $output"
pass "wired NIC detection skips non-Ethernet device types"

[[ $output != *unm0* ]] \
  || fail "wired NIC detection skips unmanaged devices" "output: $output"
pass "wired NIC detection skips unmanaged devices"

[[ $(grep -c $'\t' <<<"$output") -eq 2 ]] \
  || fail "wired NIC detection lists exactly the attached NICs" "output: $output"
pass "wired NIC detection lists exactly the attached NICs"

# ------------------------------------------------- no NIC attached at all --
NM_DEVICES=$'enp4s0f1u1:ethernet:disconnected\n'
NM_DEVICES+=$'wlp5s0:wifi:connected\n'

output=$(run_list)
printf '%s\n' "$output" >"$tmp/out-none"

[[ -z $output ]] \
  || fail "wired NIC detection emits nothing when only the T2 gadget is present" "output: $output"
pass "wired NIC detection emits nothing when only the T2 gadget is present"

# ------------------------------------------------------------ panel contract --
panel=$root/Panel.qml

grep -q 'readonly property bool hasWiredNics: wiredDevices.length > 0' "$panel" \
  || fail "panel derives the wired section from the helper's NIC list"
pass "panel derives the wired section from the helper's NIC list"

[[ $(grep -c 'visible: root.hasWiredNics' "$panel") -eq 2 ]] \
  || fail "panel hides the separator and the section together when no NIC is attached"
pass "panel hides the separator and the section together when no NIC is attached"

grep -q 'function reconcileWiredState(rows)' "$panel" \
  || fail "panel reconciles panel-local state with the NICs that still exist"
pass "panel reconciles panel-local state with the NICs that still exist"

grep -q 'reconcileWiredState(rows)' "$panel" \
  || fail "panel runs the reconciliation on every wired refresh"
pass "panel runs the reconciliation on every wired refresh"

printf '\nwired NIC detection test: pass\n'
