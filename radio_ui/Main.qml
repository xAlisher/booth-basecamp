import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme      // logos-design-system (native on RC3+ Basecamp) — skill: logos-design-system-adoption
import Logos.Controls   // LogosText / LogosButton / LogosTextField

// radio_ui — broadcast-only (#39), universal (#40), design-system (#41). A focused broadcaster:
// data layer is the universal QtRO backend (logos.module("radio_ui") PROPs/SLOTs); visuals are the
// platform design system (Theme.palette tokens, zero hex; LogosText/LogosButton/LogosTextField).
// Status pills stay custom (multi-state, semantic-coloured) but adopt Theme tokens + shape.
Item {
    id: root
    width: 480; height: 640

    // ── Universal backend + state bound to its PROPs ───────────────────────────
    readonly property var    backend: logos.module("radio_ui")
    readonly property bool    ready:   logos.isViewModuleReady("radio_ui")
    readonly property string  streamState:   backend ? backend.streamState   : "idle"
    readonly property string  streamPrivacy: backend ? backend.streamPrivacy : "public"
    readonly property string  onionAddr:     backend ? backend.onionAddr     : ""
    readonly property bool    onionReady:    backend ? backend.onionReady    : false
    readonly property string  onionError:    backend ? backend.onionError    : ""
    readonly property string  deliveryState: backend ? backend.deliveryState : "offline"
    readonly property var     streamCard: (backend && backend.streamCardJson && backend.streamCardJson.length > 0)
                                          ? JSON.parse(backend.streamCardJson) : null

    // ── Backend actions (SLOTs via logos.watch) ────────────────────────────────
    function startStream() {
        var onion = privacyGroup.checkedButton === onionBtn
        var cfg = JSON.stringify({
            name: nameField.text,
            visibility: visGroup.checkedButton === privateBtn ? "private" : "public",
            privacy: onion ? "onion" : "public",
            description: descField.text
        })
        logos.watch(backend.startStream(cfg),
            function(){ logEvent("Stream started: " + nameField.text + (onion ? " · onion" : " · direct"), "success") },
            function(){ logEvent("Couldn't start the stream.", "error") })
    }
    function stopStream() { logos.watch(backend.stopStream(), function(){ logEvent("Stream stopped", "info") }, function(){}) }
    function regenerateKey() { logos.watch(backend.regenerateKey(), function(){ logEvent("Stream key rotated — re-enter the new key in OBS", "warning") }, function(){}) }
    function regenerateOnion() { logos.watch(backend.regenerateOnion(), function(){ logEvent("Rotating Tor address — listeners will rediscover", "warning") }, function(){}) }

    function deliveryDotColor() {
        return root.deliveryState === "connected" ? Theme.palette.success
             : root.deliveryState === "ready" ? Theme.palette.warning : Theme.palette.error
    }
    function deliveryLabel() {
        return root.deliveryState === "connected" ? "Announce online"
             : root.deliveryState === "ready" ? "Announce ready" : "Announce offline"
    }
    function obsLive() { return root.streamState === "live" || root.streamState === "receiving" }
    function obsDotColor() { return obsLive() ? Theme.palette.success : Theme.palette.warning }
    function obsLabel() { return obsLive() ? "OBS live" : "Waiting for OBS" }
    function onionDotColor() { return root.onionError.length > 0 ? Theme.palette.error : root.onionReady ? Theme.palette.success : Theme.palette.warning }
    function onionLabel() { return root.onionError.length > 0 ? "Tor error" : root.onionReady ? "Onion ready" : "Publishing over Tor…" }

    // ── Activity log ───────────────────────────────────────────────────────────
    function ts2(n) { return (n < 10 ? "0" : "") + n }
    function nowTs() { var d = new Date(); return "[" + ts2(d.getHours()) + ":" + ts2(d.getMinutes()) + ":" + ts2(d.getSeconds()) + "]" }
    function logEvent(msg, level) {
        logModel.append({ "ts": nowTs(), "msg": msg, "level": level || "info" })
        if (logModel.count > 100) logModel.remove(0)
        logList.positionViewAtEnd()
    }
    function levelColor(l) { return l === "success" ? Theme.palette.success : l === "warning" ? Theme.palette.warning : l === "error" ? Theme.palette.error : Theme.palette.textSecondary }
    ListModel { id: logModel }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true
        function onActivity(line) { root.logEvent(line, "info") }
    }
    onDeliveryStateChanged: logEvent(deliveryLabel(), deliveryState === "connected" ? "success" : deliveryState === "ready" ? "warning" : "error")
    onStreamStateChanged: if (streamCard !== null) logEvent("OBS: " + obsLabel(), obsLive() ? "success" : "warning")
    onOnionReadyChanged: if (onionReady) logEvent("Onion ready · " + onionAddr, "success")
    onOnionErrorChanged: if (onionError.length > 0) logEvent("Tor: " + onionError, "error")

    function copyText(t) { clipHelper.text = t; clipHelper.selectAll(); clipHelper.copy(); clipHelper.text = "" }
    TextEdit { id: clipHelper; visible: false }

    // ── Custom controls on Theme tokens (no DS equivalent / need readOnly+echoMode) ──
    component StatusPill: Rectangle {
        id: pill
        property color dot: Theme.palette.textMuted
        property string label: ""
        height: 28; radius: Theme.spacing.radiusMedium
        implicitWidth: spRow.implicitWidth + 20
        color: Theme.palette.surface
        border.color: Theme.palette.borderHairline; border.width: 1
        Layout.alignment: Qt.AlignVCenter
        RowLayout {
            id: spRow
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            spacing: 6
            Rectangle { implicitWidth: 7; implicitHeight: 7; radius: 4; Layout.alignment: Qt.AlignVCenter; color: pill.dot }
            LogosText { text: pill.label; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.text }
        }
    }
    // readOnly/secret-capable field (LogosTextField's readOnly/echoMode API is unproven → Theme-tokened TextField)
    component ThemedField: TextField {
        color: Theme.palette.text
        placeholderTextColor: Theme.palette.textMuted
        selectionColor: Theme.palette.primary
        background: Rectangle {
            radius: Theme.spacing.radiusSmall; implicitHeight: 34
            color: Theme.palette.surfaceRecessed
            border.color: parent && parent.activeFocus ? Theme.palette.primary : Theme.palette.borderHairline
            border.width: 1
        }
    }
    component ThemedRadio: RadioButton {
        id: dr
        spacing: 8
        palette.windowText: Theme.palette.text
        indicator: Rectangle {
            implicitWidth: 18; implicitHeight: 18; radius: 9
            x: dr.leftPadding; y: dr.topPadding + (dr.availableHeight - height) / 2
            color: "transparent"; border.width: 2
            border.color: dr.checked ? Theme.palette.primary : Theme.palette.textMuted
            Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: 4
                color: Theme.palette.primary; visible: dr.checked }
        }
    }

    // ── Background ────────────────────────────────────────────────────────────
    Rectangle { anchors.fill: parent; color: Theme.palette.background }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header ────────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 14; Layout.bottomMargin: 6
            spacing: 8
            ColumnLayout {
                spacing: 1
                LogosText { text: "Radio"; color: Theme.palette.text; font.pixelSize: Theme.typography.panelTitleText; font.weight: Theme.typography.weightBold }
                LogosText { text: "Decentralized broadcast"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
            }
            Item { Layout.fillWidth: true }
            RowLayout {
                spacing: 8
                Layout.alignment: Qt.AlignVCenter
                StatusPill { dot: root.deliveryDotColor(); label: root.deliveryLabel() }
                StatusPill { visible: root.streamCard !== null; dot: root.obsDotColor(); label: root.obsLabel() }
                StatusPill { visible: root.streamCard !== null && root.streamPrivacy === "onion"
                             dot: root.onionDotColor(); label: root.onionLabel() }
            }
        }

        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.palette.borderHairline; Layout.topMargin: 6 }

        // ── Broadcast body ────────────────────────────────────────────────────
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 16; spacing: 12

                // setup form
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 10
                    visible: root.streamCard === null
                    LogosText { text: "Station name"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                    LogosTextField { id: nameField; Layout.fillWidth: true; placeholderText: "What listeners see"; text: "My Station" }
                    LogosText { text: "Visibility"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                    RowLayout {
                        spacing: 16
                        ButtonGroup { id: visGroup }
                        ThemedRadio { id: publicBtn;  text: "Public";  checked: true; ButtonGroup.group: visGroup }
                        ThemedRadio { id: privateBtn; text: "Private"; ButtonGroup.group: visGroup }
                    }
                    LogosText { text: "Privacy"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                    RowLayout {
                        spacing: 16
                        ButtonGroup { id: privacyGroup }
                        ThemedRadio { id: onionBtn;  text: "Onion (Tor)";  checked: true; ButtonGroup.group: privacyGroup }
                        ThemedRadio { id: directBtn; text: "Direct (LAN)"; ButtonGroup.group: privacyGroup }
                    }
                    LogosText {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.typography.secondaryText
                        color: privacyGroup.checkedButton === onionBtn ? Theme.palette.textMuted : Theme.palette.warning
                        text: privacyGroup.checkedButton === onionBtn
                            ? "🧅 Listeners reach you over Tor — your IP stays hidden and it works through NAT (no port-forwarding). First connect is slower."
                            : "⚠ Direct mode is LAN-only and exposes your IP to listeners. Use it only for local/low-latency streams."
                    }
                    LogosText { text: "Description (optional)"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                    LogosTextField { id: descField; Layout.fillWidth: true; placeholderText: "Genre or a short note" }
                    LogosButton { text: "Start"; enabled: root.ready && nameField.text.length > 0; onClicked: root.startStream() }
                }

                // credentials card
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 10
                    visible: root.streamCard !== null
                    LogosText { text: "Stream credentials"; color: Theme.palette.text; font.pixelSize: Theme.typography.primaryText; font.weight: Theme.typography.weightBold }
                    LogosText {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText
                        text: "In OBS → Settings → Stream: set Service to “Custom…”, paste the RTMP Server and Stream Key below, then Start Streaming. The key is secret — don't share it."
                    }
                    component CopyRow: RowLayout {
                        id: cr
                        property string label: ""
                        property string value: ""
                        property bool secret: false
                        property bool revealed: false
                        property bool canRegen: false
                        signal regen()
                        Layout.fillWidth: true; spacing: 8
                        LogosText { text: cr.label; color: Theme.palette.textSecondary; Layout.preferredWidth: 90; font.pixelSize: Theme.typography.secondaryText }
                        ThemedField {
                            Layout.fillWidth: true; readOnly: true; text: cr.value
                            echoMode: (cr.secret && !cr.revealed) ? TextInput.Password : TextInput.Normal
                        }
                        LogosButton { visible: cr.secret; text: cr.revealed ? "Hide" : "Show"; implicitWidth: 56; onClicked: cr.revealed = !cr.revealed }
                        LogosButton { visible: cr.canRegen; text: "⟳ New"; implicitWidth: 64; onClicked: cr.regen() }
                        LogosButton { text: "Copy"; implicitWidth: 56; onClicked: root.copyText(cr.value) }
                    }
                    CopyRow { label: "RTMP Server"; value: root.streamCard ? root.streamCard.rtmpUrl : "" }
                    CopyRow {
                        label: "Stream Key"; value: root.streamCard ? root.streamCard.streamKey : ""
                        secret: true; canRegen: true
                        onRegen: root.regenerateKey()
                    }
                    RowLayout {
                        visible: root.streamPrivacy === "onion"
                        Layout.fillWidth: true; spacing: 8
                        LogosText { text: "Tor address"; color: Theme.palette.textSecondary; Layout.preferredWidth: 90; font.pixelSize: Theme.typography.secondaryText }
                        LogosText {
                            Layout.fillWidth: true; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.textMuted; elide: Text.ElideRight
                            text: root.onionReady ? "stable · persists across restarts" : "publishing…"
                        }
                        LogosButton { text: "⟳ New address"; implicitWidth: 120; onClicked: root.regenerateOnion() }
                    }
                    LogosButton { text: "Stop"; onClicked: root.stopStream() }
                }
                Item { Layout.fillHeight: true }
            }
        }

        // ── Activity log ──────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 10
            Layout.preferredHeight: 172
            color: Theme.palette.surface; radius: Theme.spacing.radiusMedium

            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: 1; color: Theme.palette.borderHairline
            }
            LogosText { anchors { top: parent.top; left: parent.left; topMargin: 8; leftMargin: 12 }
                   text: "Activity"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText; font.weight: Theme.typography.weightBold }

            Rectangle {
                visible: logModel.count > 0
                anchors { top: parent.top; right: copyBtn.left; topMargin: 8; rightMargin: 10 }
                width: 18; height: 18; color: "transparent"; opacity: clearArea.containsMouse ? 0.9 : 0.45
                LogosText { anchors.centerIn: parent; text: "✕"; color: Theme.palette.textMuted; font.pixelSize: 13 }
                MouseArea { id: clearArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: logModel.clear() }
                ToolTip { visible: clearArea.containsMouse; text: "Clear"; delay: 500 }
            }
            Rectangle {
                id: copyBtn
                anchors { top: parent.top; right: parent.right; topMargin: 8; rightMargin: 10 }
                width: 20; height: 20; color: "transparent"; opacity: copyArea.containsMouse ? 0.9 : 0.5
                Behavior on opacity { NumberAnimation { duration: 150 } }
                Rectangle { x: 3; y: 6; width: 10; height: 10; color: "transparent"; border.color: Theme.palette.textMuted; border.width: 1; radius: 2 }
                Rectangle { x: 6; y: 3; width: 10; height: 10; color: Theme.palette.surface; border.color: Theme.palette.textMuted; border.width: 1; radius: 2 }
                MouseArea {
                    id: copyArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { var s = ""; for (var i = 0; i < logModel.count; i++) { var e = logModel.get(i); s += e.ts + " " + e.msg + "\n" }
                        root.copyText(s); copyBtn.opacity = 0.25; copyFb.restart() }
                }
                ToolTip { visible: copyArea.containsMouse; text: "Copy all"; delay: 500 }
            }
            Timer { id: copyFb; interval: 200; onTriggered: copyBtn.opacity = copyArea.containsMouse ? 0.9 : 0.5 }

            ListView {
                id: logList
                anchors { top: parent.top; left: parent.left; right: parent.right; bottom: parent.bottom
                          topMargin: 30; leftMargin: 12; rightMargin: 12; bottomMargin: 10 }
                spacing: 4; clip: true; model: logModel
                ScrollBar.vertical: ScrollBar {}
                delegate: TextEdit {
                    width: logList.width
                    text: model.ts + " " + model.msg
                    color: root.levelColor(model.level)
                    font.pixelSize: 11; font.family: "monospace"
                    wrapMode: TextEdit.WordWrap
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                }
            }
            LogosText { visible: logModel.count === 0; anchors.centerIn: parent
                   text: "No activity yet"; color: Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText }
        }
    }
}
