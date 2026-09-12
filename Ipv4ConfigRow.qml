import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// One IPv4 configuration row: automatic DHCP versus a manual static address,
// the static form, and the apply/reset actions. The wired NIC list and the
// connected Wi-Fi network both use it; the owner supplies the normalized row
// (see Model.js wiredNicRow/wifiIpv4Row), the helper script that applies the
// change, and the panel-wide "an apply is running" flag.
//
// The row keeps its own drafts and reports them through draftStateChanged() so
// the owner can pause its refreshes while the user is working -- a rebuild under
// the cursor would discard the toggle or the typed address.
Item {
  id: ipv4Row

  required property var info
  // Helper that applies the change: <script> set <info.key> <dhcp|manual> [...]
  required property string script
  required property QtObject bar
  // Owned by the owner so two rows can never run an activation at once.
  property bool applyBusy: false

  signal applyStarted()
  signal applyFinished()
  signal applied()
  signal draftStateChanged()
  signal hovered()

  // The row is instantiated as soon as its section exists, even while the list
  // that fills it is still empty, so every field is read defensively.
  readonly property bool connected: !!info.connected
  readonly property bool linkPresent: !!info.linkPresent
  readonly property bool manualSaved: info.method === "manual"
  readonly property string liveAddressText: {
    var raw = String(info.liveIp || "")
    var idx = raw.indexOf("/")
    return idx < 0 ? raw : raw.substring(0, idx)
  }
  readonly property string livePrefixText: {
    var raw = String(info.liveIp || "")
    var idx = raw.indexOf("/")
    return idx < 0 ? "" : raw.substring(idx + 1)
  }
  readonly property string summaryText: {
    var parts = []
    parts.push(info.stateText || "")
    if (liveAddressText !== "") parts.push(liveAddressText + (livePrefixText !== "" ? "/" + livePrefixText : ""))
    if (info.profile) parts.push(info.profile)
    if (statusText !== "") parts.push(statusText)
    return parts.join(" · ")
  }

  property bool manualMode: manualSaved
  // Local copy of "the user touched the mode switch". modeDirty can in principle
  // become false if a background refresh updates info.method before the row has
  // been reloaded; this flag keeps the staged DHCP Apply button visible until
  // load/reset/apply explicitly clears it.
  property bool modeEdited: false
  readonly property bool modeDirty: manualMode !== manualSaved
  property string draftAddress: info.address || ""
  property string draftPrefix: info.prefix || ""
  property string draftGateway: info.gateway || ""
  property string draftDns: info.dns || ""
  property bool busy: false
  property string statusText: ""
  property bool failed: false
  property string initializedKey: ""
  // The saved configuration this row was loaded from, so a change made
  // elsewhere (another tool, nmcli, a reconnect) can be followed while the row
  // has nothing of the user's own on screen.
  property string loadedSignature: ""
  // Any uncommitted change: a field edit or a staged mode switch.
  readonly property bool draftDirty: modeEdited || fieldsDirty
  property bool fieldsDirty: false
  // Focus alone (an untouched field) also has to pause refreshes, because a
  // rebuilt delegate would drop the cursor.
  readonly property bool editing: ipField.activeFocus || prefixField.activeFocus
    || gatewayField.activeFocus || dnsField.activeFocus

  onDraftDirtyChanged: draftStateChanged()
  onEditingChanged: draftStateChanged()

  // The saved profile values the user would be editing. Live addresses are not
  // part of it: they change on their own and must never reload the row.
  function infoSignature() {
    return [
      info.method || "auto",
      info.address || "",
      info.prefix || "",
      info.gateway || "",
      info.dns || ""
    ].join("|")
  }

  function loadFromInfo() {
    if (!info.key) return
    initializedKey = info.key
    manualMode = info.method === "manual"
    modeEdited = false
    fieldsDirty = false
    draftAddress = info.address || ""
    draftPrefix = info.prefix || ""
    draftGateway = info.gateway || ""
    draftDns = info.dns || ""
    busy = false
    statusText = ""
    failed = false
    loadedSignature = infoSignature()
  }

  // Later info updates must not clobber drafts while the user is working on this
  // row -- but a row nobody is touching follows the profile it belongs to.
  function initFromInfo() {
    // Losing the row (the network is no longer in use) must not leave it
    // initialised, or the same network would not have its saved settings read
    // again when it comes back.
    if (!info.key) {
      initializedKey = ""
      return
    }
    if (initializedKey !== info.key) {
      loadFromInfo()
      return
    }
    // Same target: follow a saved configuration that changed underneath (the
    // helper ran from a terminal, the network reconnected, this row's own apply
    // landed) while the row is clean. A draft, a focused field, or an apply in
    // flight is never overwritten.
    if (draftDirty || editing || busy) return
    if (infoSignature() !== loadedSignature) loadFromInfo()
  }

  // Reset/Cancel: restore every draft from the saved NetworkManager profile,
  // regardless of whether this row was initialized before.
  function resetToInfo() {
    loadFromInfo()
  }

  function markDirty() {
    fieldsDirty = true
  }

  function setMode(nextManual) {
    if (busy) return
    manualMode = nextManual
    statusText = ""
    failed = false

    if (manualMode) {
      if (draftAddress === "") {
        if (liveAddressText !== "") {
          draftAddress = liveAddressText
          if (livePrefixText !== "") draftPrefix = livePrefixText
        }
      }
      if (draftPrefix === "") draftPrefix = "24"
    }
    modeEdited = manualMode !== manualSaved
  }

  function validIpv4(value) {
    var text = String(value || "").trim()
    if (!text) return false
    var parts = text.split(".")
    if (parts.length !== 4) return false
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i]
      if (!/^\d{1,3}$/.test(part)) return false
      var n = parseInt(part, 10)
      if (n < 0 || n > 255) return false
    }
    return true
  }

  function validPrefix(value) {
    var text = String(value || "").trim()
    if (!/^\d{1,2}$/.test(text)) return false
    var n = parseInt(text, 10)
    return n >= 0 && n <= 32
  }

  function validDns(value) {
    var text = String(value || "").trim()
    if (text === "") return true
    var tokens = text.split(/[\s,]+/)
    for (var i = 0; i < tokens.length; i++) {
      if (!validIpv4(tokens[i])) return false
    }
    return true
  }

  function applyConfig() {
    // Serialize reconfiguration. applyBusy is the owner's flag because
    // NetworkManager activations can overlap across rows, and clearing it when
    // the first of two concurrent applies exits would resume details polling
    // while the second link is still transitioning.
    if (busy || applyBusy || !info.key) return
    statusText = ""
    failed = false

    if (manualMode) {
      if (!validIpv4(draftAddress)) {
        statusText = "Invalid IP address"
        failed = true
        return
      }
      if (!validPrefix(draftPrefix)) {
        statusText = "Invalid prefix (0-32)"
        failed = true
        return
      }
      if (String(draftGateway || "").trim() !== "" && !validIpv4(draftGateway)) {
        statusText = "Invalid gateway"
        failed = true
        return
      }
      if (!validDns(draftDns)) {
        statusText = "Invalid DNS server"
        failed = true
        return
      }
    }

    busy = true
    statusText = info.applyingText || ""
    applyStarted()

    var args = [ipv4Row.script, "set", info.key]
    if (!manualMode) {
      args.push("dhcp")
    } else {
      var prefix = String(draftPrefix || "").trim() || "24"
      args.push("manual")
      args.push(String(draftAddress || "").trim())
      args.push(prefix)
      args.push(String(draftGateway || "").trim())
      args.push(String(draftDns || "").trim())
    }
    applyProc.command = args
    applyProc.running = true
  }

  onInfoChanged: initFromInfo()
  Component.onCompleted: initFromInfo()
  Component.onDestruction: {
    // If a refresh destroys the row while its apply process is still running,
    // never leave the owner's busy flag (and the details poll) stuck on.
    if (busy) applyFinished()
  }

  implicitHeight: contentColumn.implicitHeight

  Column {
    id: contentColumn
    width: parent.width
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.space(6)

    // Header: name + state on the left, DHCP/manual switch on the right.
    Item {
      width: parent.width
      implicitHeight: Math.max(headerLabels.implicitHeight, modeSwitchGroup.implicitHeight)

      Row {
        id: modeSwitchGroup
        spacing: Style.space(6)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: ipv4Row.manualMode ? "MANUAL" : "AUTO DHCP"
          color: Qt.darker(ipv4Row.bar.foreground, 1.4)
          font.family: ipv4Row.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.0
          anchors.verticalCenter: parent.verticalCenter
        }

        ToggleSwitch {
          checked: !ipv4Row.manualMode
          enabled: !ipv4Row.busy && !ipv4Row.applyBusy
          foreground: ipv4Row.bar.foreground
          onToggled: ipv4Row.setMode(!ipv4Row.manualMode)
          onHovered: function(hovered) {
            if (hovered) ipv4Row.hovered()
          }
        }
      }

      Column {
        id: headerLabels
        anchors.left: parent.left
        anchors.right: modeSwitchGroup.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: ipv4Row.info.name || ""
          color: (ipv4Row.connected || ipv4Row.linkPresent)
            ? ipv4Row.bar.foreground
            : Qt.darker(ipv4Row.bar.foreground, 1.4)
          font.family: ipv4Row.bar.fontFamily
          font.pixelSize: Style.font.body
          font.bold: ipv4Row.connected || ipv4Row.linkPresent
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: ipv4Row.summaryText
          color: ipv4Row.failed
            ? ipv4Row.bar.urgent
            : Qt.darker(ipv4Row.bar.foreground, 1.4)
          font.family: ipv4Row.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    // Auto DHCP is the default; no form is needed. When the saved profile is
    // still manual, toggling the switch only stages the change -- it must be
    // committed with the Apply button below, exactly like editing a static IP.
    Column {
      visible: !ipv4Row.manualMode
      width: parent.width
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: "DHCP — obtain IP, gateway and DNS automatically."
        color: Qt.darker(ipv4Row.bar.foreground, 1.6)
        font.family: ipv4Row.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Row {
        visible: ipv4Row.modeDirty || ipv4Row.modeEdited
        spacing: Style.space(6)

        Button {
          text: ipv4Row.busy ? "Applying…" : (ipv4Row.info.dhcpButtonText || "Apply DHCP")
          enabled: !ipv4Row.busy && !ipv4Row.applyBusy
          fontSize: Style.font.body
          foreground: ipv4Row.bar.foreground
          fontFamily: ipv4Row.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: ipv4Row.applyConfig()
        }

        Button {
          text: "Reset"
          visible: !ipv4Row.busy
          fontSize: Style.font.body
          foreground: ipv4Row.bar.foreground
          fontFamily: ipv4Row.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: ipv4Row.resetToInfo()
        }
      }
    }

    // Static IPv4 form.
    Column {
      visible: ipv4Row.manualMode
      width: parent.width
      spacing: Style.space(6)

      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: ipField
          Layout.fillWidth: true
          placeholderText: "IP address"
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          foreground: ipv4Row.bar.foreground
          horizontalPadding: Style.spacing.controlGap
          verticalPadding: Style.spacing.controlPaddingY
          enabled: !ipv4Row.busy && !ipv4Row.applyBusy
          text: ipv4Row.draftAddress
          onTextChanged: {
            if (text !== ipv4Row.draftAddress) {
              ipv4Row.draftAddress = text
              ipv4Row.markDirty()
            }
          }
          onAccepted: prefixField.forceActiveFocus()
        }

        TextField {
          id: prefixField
          Layout.preferredWidth: Style.space(72)
          placeholderText: "/24"
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          foreground: ipv4Row.bar.foreground
          horizontalPadding: Style.spacing.controlGap
          verticalPadding: Style.spacing.controlPaddingY
          enabled: !ipv4Row.busy && !ipv4Row.applyBusy
          text: ipv4Row.draftPrefix
          onTextChanged: {
            if (text !== ipv4Row.draftPrefix) {
              ipv4Row.draftPrefix = text
              ipv4Row.markDirty()
            }
          }
          onAccepted: gatewayField.forceActiveFocus()
        }
      }

      TextField {
        id: gatewayField
        width: parent.width
        placeholderText: "Gateway (optional)"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        foreground: ipv4Row.bar.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        enabled: !ipv4Row.busy
        text: ipv4Row.draftGateway
        onTextChanged: {
          if (text !== ipv4Row.draftGateway) {
            ipv4Row.draftGateway = text
            ipv4Row.markDirty()
          }
        }
        onAccepted: dnsField.forceActiveFocus()
      }

      TextField {
        id: dnsField
        width: parent.width
        placeholderText: "DNS servers (optional, comma or space separated)"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        foreground: ipv4Row.bar.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        enabled: !ipv4Row.busy && !ipv4Row.applyBusy
        text: ipv4Row.draftDns
        onTextChanged: {
          if (text !== ipv4Row.draftDns) {
            ipv4Row.draftDns = text
            ipv4Row.markDirty()
          }
        }
      }

      Row {
        spacing: Style.space(6)

        Button {
          text: ipv4Row.busy ? "Applying…" : "Apply static IP"
          enabled: !ipv4Row.busy && !ipv4Row.applyBusy
          fontSize: Style.font.body
          foreground: ipv4Row.bar.foreground
          fontFamily: ipv4Row.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: ipv4Row.applyConfig()
        }

        Button {
          text: "Reset"
          visible: !ipv4Row.busy
          fontSize: Style.font.body
          foreground: ipv4Row.bar.foreground
          fontFamily: ipv4Row.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: ipv4Row.resetToInfo()
        }
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyOut; waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(exitCode) {
      ipv4Row.busy = false
      ipv4Row.applyFinished()
      if (exitCode === 0) {
        ipv4Row.failed = false
        ipv4Row.statusText = ipv4Row.info.appliedText || "Applied"
        // Clearing initializedKey lets the row reload from the profile the
        // apply just wrote, instead of staying on its old draft.
        ipv4Row.initializedKey = ""
        ipv4Row.applied()
      } else {
        ipv4Row.failed = true
        var firstLine = String(applyErr.text || "").trim().split("\n")[0]
        ipv4Row.statusText = firstLine !== "" ? "Failed: " + firstLine : "Apply failed"
      }
    }
  }
}
