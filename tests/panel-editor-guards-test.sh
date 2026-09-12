#!/bin/bash

# Three guards that the panel has to keep, each of which was broken once:
#
#  1. The key dispatcher runs with Keys.BeforeItem priority, so every inline
#     editor (the wireless passphrase, the hidden-network form, the IPv4
#     address fields) has to be announced to it. Unannounced, an editor is
#     typed into *and* acted on -- "w" switched the radio off mid-SSID, "r"
#     refreshed the panel, and space/Enter/j/k/h/l never reached the field.
#  2. refresh() is reached from the shortcuts and from every finished Wi-Fi
#     action, so it must not restart the IPv4 list processes behind the draft
#     guards: a rebuilt Repeater delegate silently drops an uncommitted
#     DHCP/static toggle or a half-typed address.
#  3. An IPv4 apply that succeeds is followed by a reload of the very row that
#     reports it, which has to keep the "Applied"/"Saved" line long enough to
#     be read -- and must never show it against a configuration it did not
#     describe.
#
# These are wiring checks, so they read the sources rather than run the panel.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
panel=$root/Panel.qml
row=$root/Ipv4ConfigRow.qml

fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

section() {
  awk -v start="$1" -v end="$2" '$0 ~ start, $0 ~ end' "$3"
}

# ------------------------------------------- 1. inline editors own the keys ---

grep -q 'blocked: root.passwordSsid !== "" || root.inlineEditorFocused' "$panel" \
  || fail "the key dispatcher stands down while an inline editor holds the keyboard"
grep -q 'inlineEditorFocused: panelEditorsFocused.length > 0' "$panel" \
  || fail "the panel tracks the editors that hold the keyboard"
pass "the key dispatcher stands down while an inline editor holds the keyboard"

grep -q 'root.setPanelEditorFocused("hidden-ssid", activeFocus)' "$panel" \
  || fail "the hidden-network SSID field announces its focus"
grep -q 'root.setPanelEditorFocused("hidden-password", activeFocus)' "$panel" \
  || fail "the hidden-network password field announces its focus"
[[ $(grep -c 'Keys.onEscapePressed: root.toggleHiddenNetworkForm()' "$panel") -eq 2 ]] \
  || fail "both hidden-network fields give the keyboard back on Esc"
pass "the hidden-network form announces its focus and can be left with Esc"

grep -q 'signal editorFocusChanged(bool focused)' "$row" \
  || fail "an IPv4 row reports the focus its fields hold"
grep -q 'editorFocusChanged(editing)' "$row" \
  || fail "an IPv4 row reports focus changes"
[[ $(grep -c 'Keys.onEscapePressed: ipv4Row.releaseFocus()' "$row") -eq 4 ]] \
  || fail "every IPv4 field releases the keyboard on Esc"
grep -q 'function releaseFocus()' "$row" \
  || fail "releasing focus leaves the draft alone"
pass "the IPv4 fields announce their focus and release it on Esc"

grep -q 'root.setWiredEditorFocused(wiredNic.info.key, focused)' "$panel" \
  || fail "the wired rows report their field focus"
grep -q 'root.setPanelEditorFocused("wifi-ipv4", focused)' "$panel" \
  || fail "the Wi-Fi IPv4 row reports its field focus"

# A delegate that a refresh replaces cannot report the focus it held, so a
# stale key would leave the dispatcher blocked for the rest of the session.
section 'function updateWiredDevices' '^  }' "$panel" | grep -q 'wiredEditorsFocused = \[\]' \
  || fail "a rebuilt wired list drops the focus its rows cannot report any more"
awk '/onOpenedChanged/,/^  }$/' "$panel" | grep -q 'panelEditorsFocused = \[\]' \
  || fail "closing the panel drops editor focus without waiting for a report"
pass "focus that can no longer be reported is dropped, not trusted"

# ------------------------------------------- 2. refresh respects the drafts ---

section 'scanWifi === undefined' 'syncWifiNetworks' "$panel" | grep -q 'refreshWiredDevices(false)' \
  || fail "a bare refresh goes through the wired draft guard"
section 'scanWifi === undefined' 'syncWifiNetworks' "$panel" | grep -q 'refreshWifiIpv4(false)' \
  || fail "a bare refresh goes through the Wi-Fi IPv4 guard"
if section 'scanWifi === undefined' 'syncWifiNetworks' "$panel" | grep -q 'ethListProc.running = true'; then
  fail "a bare refresh must not restart the wired list process directly"
fi
pass "refresh() cannot rebuild the IPv4 rows out from under a draft"

# The apply itself is the one refresh that has to replace the draft -- and the
# row it replaces cannot report itself clean afterwards.
grep -q 'root.setWiredDirty(wiredNic.info.key, false)' "$panel" \
  || fail "a successful wired apply drops its own draft key"
pass "a successful apply drops the draft key its row cannot drop for itself"

# ------------------------------------- 3. the applied notice survives a reload --

grep -q 'property bool keepStatusNotice: false' "$row" \
  || fail "the row can carry its success notice through the reload that follows it"
grep -q 'if (keepStatusNotice) keepStatusNotice = false' "$row" \
  || fail "the notice survives exactly one reload"
grep -q 'ipv4Row.keepStatusNotice = true' "$row" \
  || fail "a successful apply asks for its notice to survive"
section 'function markDirty' '^  }$' "$row" | grep -q 'keepStatusNotice = false' \
  || fail "a fresh edit drops a stale notice"
section 'function setMode' '^  }$' "$row" | grep -q 'keepStatusNotice = false' \
  || fail "a mode change drops a stale notice"
pass "the success notice outlives its own reload, and only that reload"

# Closing the panel discards panel-local state. The wired rows are rebuilt on
# the next open, so they lose a draft by themselves; the Wi-Fi row is one
# long-lived instance and has to be told, or it would reopen still showing a
# draft -- and a notice -- that describes an edit nobody is looking at.
grep -q 'wifiIpv4Row.discardDraft()' "$panel" \
  || fail "the panel tells the Wi-Fi IPv4 row that it is closing"
grep -q 'function discardDraft()' "$row" \
  || fail "the row can drop its panel-local state on a close"
section 'function discardDraft' '^  }$' "$row" | grep -q 'if (busy) return' \
  || fail "a close never interrupts an apply that is still running"
pass "a close discards panel-local drafts, an apply in flight excepted"

printf '\npanel editor guards test: pass\n'
