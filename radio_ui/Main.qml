import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme      // logos-design-system (native on RC3+ Basecamp) — skill: logos-design-system-adoption
import Logos.Controls   // LogosText / LogosButton / LogosBadge / LogosComboBox / LogosTextField

// radio_ui — broadcast-only (#39), universal (#40), design-system (#41). Focused broadcaster.
// Data layer: universal QtRO backend (logos.module("radio_ui") PROPs/SLOTs). Visuals: pure design
// system — LogosBadge status, LogosComboBox choices, LogosTextField fields, LogosButton/LogosText,
// Theme.palette tokens (0 hex). Reference: logos-delivery-demo (no invented widgets).
Item {
    id: root
    width: 480; height: 640

    // ── Universal backend + state bound to its PROPs ───────────────────────────
    readonly property var    backend: logos.module("radio_ui")
    readonly property string  streamState:   backend ? backend.streamState   : "idle"
    readonly property string  streamPrivacy: backend ? backend.streamPrivacy : "public"
    readonly property string  onionAddr:     backend ? backend.onionAddr     : ""
    readonly property bool    onionReady:    backend ? backend.onionReady    : false
    readonly property string  onionError:    backend ? backend.onionError    : ""
    readonly property string  deliveryState: backend ? backend.deliveryState : "offline"
    readonly property var     streamCard: (backend && backend.streamCardJson && backend.streamCardJson.length > 0)
                                          ? JSON.parse(backend.streamCardJson) : null
    readonly property var     keySrc: ["anonymous", "autogen", "keycard"]   // #24 dropdown index → tier
    readonly property string  keycardFp: backend ? backend.keycardFingerprint : ""   // #24 set after Connect Keycard

    // ── Backend actions (SLOTs via logos.watch) ────────────────────────────────
    function startStream() {
        var onion = privacyBox.currentIndex === 0   // model[0] = Onion (default)
        var cfg = JSON.stringify({
            name: nameField.text,
            visibility: visBox.currentIndex === 1 ? "private" : "public",
            privateTopic: visBox.currentIndex === 1 ? privTopicField.text.trim() : "",
            privacy: onion ? "onion" : "public",
            keySource: root.keySrc[keyBox.currentIndex],          // #24 anonymous | autogen | keycard (radio_module derives)
            description: descField.text
        })
        logos.watch(backend.startStream(cfg),
            function(){ logEvent("Stream started: " + nameField.text + (onion ? " · onion" : " · direct"), "success") },
            function(){ logEvent("Couldn't start the stream.", "error") })
    }
    function stopStream() { logos.watch(backend.stopStream(), function(){ logEvent("Stream stopped", "info") }, function(){}) }
    function regenerateKey() { logos.watch(backend.regenerateKey(), function(){ logEvent("Stream key rotated — re-enter the new key in your streaming software", "warning") }, function(){}) }
    function regenerateOnion() { logos.watch(backend.regenerateOnion(), function(){ logEvent("Rotating Tor address — listeners will rediscover", "warning") }, function(){}) }

    // status → text + Theme.palette colour (LogosBadge pattern, per delivery-demo/receiver)
    function deliveryColor() {
        return root.deliveryState === "connected" ? Theme.palette.success
             : root.deliveryState === "ready" ? Theme.palette.warning : Theme.palette.error
    }
    function deliveryLabel() {
        return root.deliveryState === "connected" ? "announce online"
             : root.deliveryState === "ready" ? "announce ready" : "announce offline"
    }
    // #36 — generic "streaming software" (OBS, Liquidsoap, ffmpeg…), not OBS-specific
    function sourceLive() { return root.streamState === "live" || root.streamState === "receiving" }
    function sourceColor() { return sourceLive() ? Theme.palette.success : Theme.palette.warning }
    function sourceLabel() { return sourceLive() ? "source live" : "waiting for source" }
    function onionColor() { return root.onionError.length > 0 ? Theme.palette.error : root.onionReady ? Theme.palette.success : Theme.palette.warning }
    function onionLabel() { return root.onionError.length > 0 ? "tor error" : root.onionReady ? "onion ready" : "publishing…" }

    // ── Activity log (no DS component for a log feed — Theme-tokened container) ──
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
    onStreamStateChanged: if (streamCard !== null) logEvent("Source: " + sourceLabel(), sourceLive() ? "success" : "warning")
    onOnionReadyChanged: if (onionReady) logEvent("Onion ready · " + onionAddr, "success")
    onOnionErrorChanged: if (onionError.length > 0) logEvent("Tor: " + onionError, "error")

    function copyText(t) { clipHelper.text = t; clipHelper.selectAll(); clipHelper.copy(); clipHelper.text = "" }
    TextEdit { id: clipHelper; visible: false }

    // ── Background ────────────────────────────────────────────────────────────
    Rectangle { anchors.fill: parent; color: Theme.palette.background }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header: title + status badges (LogosBadge) ────────────────────────
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
                LogosBadge { Layout.alignment: Qt.AlignVCenter; text: root.deliveryLabel(); color: root.deliveryColor() }
                LogosBadge { Layout.alignment: Qt.AlignVCenter; visible: root.streamCard !== null; text: root.sourceLabel(); color: root.sourceColor() }
                LogosBadge { Layout.alignment: Qt.AlignVCenter
                             visible: root.streamCard !== null && root.streamPrivacy === "onion"
                             text: root.onionLabel(); color: root.onionColor() }
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
                    RowLayout {
                        Layout.fillWidth: true; spacing: 12
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            LogosText { text: "Visibility"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                            LogosComboBox { id: visBox; model: ["Public", "Private"]; currentIndex: 0; Layout.fillWidth: true }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            LogosText { text: "Privacy"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                            LogosComboBox { id: privacyBox; model: ["Hide IP with Tor", "Show IP (LAN)"]; currentIndex: 0; Layout.fillWidth: true }
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.typography.secondaryText
                        color: privacyBox.currentIndex === 0 ? Theme.palette.textMuted : Theme.palette.warning
                        text: privacyBox.currentIndex === 0
                            ? "🧅 Listeners reach you over Tor — your IP stays hidden and it works through NAT (no port-forwarding). First connect is slower."
                            : "⚠ Direct mode is LAN-only and exposes your IP to listeners. Use it only for local/low-latency streams."
                    }
                    // #24 station identity: Anonymous (unsigned) | Autogenerated (device key) | Keycard (portable)
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 4
                        LogosText { text: "Station identity"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                        LogosComboBox { id: keyBox; model: ["Anonymous — no identity", "Autogenerated key", "Derive from Keycard"]; currentIndex: 1; Layout.fillWidth: true }
                        LogosText {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.typography.secondaryText
                            color: keyBox.currentIndex === 0 ? Theme.palette.warning : Theme.palette.textMuted
                            text: keyBox.currentIndex === 0
                                ? "Fully anonymous — but listeners can't verify or pin you, and a name can be impersonated."
                                : keyBox.currentIndex === 1
                                ? "A device-local key signs your announces — listeners verify + pin you across name/Tor changes (this device only)."
                                : "🔑 A portable key derived from your Keycard (same fingerprint on any device)."
                        }
                        // #7/#24 explicit Connect-Keycard step — derive bc:radio now + show the fingerprint before Start
                        RowLayout {
                            visible: keyBox.currentIndex === 2
                            Layout.fillWidth: true; spacing: 8
                            LogosButton {
                                text: root.keycardFp.length > 0 ? "✓ Keycard linked" : "Connect Keycard"
                                enabled: root.keycardFp.length === 0
                                onClicked: logos.watch(backend.connectKeycard(), function(){}, function(){})
                            }
                            LogosText {
                                visible: root.keycardFp.length > 0
                                Layout.alignment: Qt.AlignVCenter
                                text: root.keycardFp; color: Theme.palette.success; font.pixelSize: Theme.typography.secondaryText
                            }
                        }
                    }
                    // #49 private → name the topic listeners will subscribe to
                    ColumnLayout {
                        visible: visBox.currentIndex === 1
                        Layout.fillWidth: true; spacing: 4
                        LogosText { text: "Private directory name"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                        LogosTextField { id: privTopicField; Layout.fillWidth: true; placeholderText: "e.g. my-secret-room — a private directory to share" }
                    }
                    LogosText { text: "Description (optional)"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                    LogosTextField { id: descField; Layout.fillWidth: true; placeholderText: "Genre or a short note" }
                    LogosButton { text: "Start"
                        enabled: nameField.text.length > 0 && (keyBox.currentIndex !== 2 || root.keycardFp.length > 0)  // #7 keycard tier needs Connect first
                        onClicked: root.startStream() }
                }

                // credentials — bordered card (delivery-demo style), each field a labeled input block
                Rectangle {
                    Layout.fillWidth: true
                    visible: root.streamCard !== null
                    Layout.preferredHeight: credCol.implicitHeight + Theme.spacing.medium * 2
                    radius: Theme.spacing.radiusMedium
                    color: Theme.palette.surface
                    border.width: 1; border.color: Theme.palette.borderHairline
                    ColumnLayout {
                        id: credCol
                        anchors.fill: parent; anchors.margins: Theme.spacing.medium
                        spacing: Theme.spacing.medium
                        LogosText { text: "Stream credentials"; color: Theme.palette.text; font.pixelSize: Theme.typography.primaryText; font.weight: Theme.typography.weightBold }
                        LogosText {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText
                            text: "In your streaming software (OBS, Liquidsoap, ffmpeg…) → set a Custom RTMP service, paste the Server and Stream Key below, then start streaming. The key is secret — don't share it."
                        }
                        // labeled input block: label on top, value in a field, actions grouped after
                        component CredBlock: ColumnLayout {
                            id: cb
                            property string label: ""
                            property string value: ""
                            property bool secret: false
                            property bool revealed: false
                            property bool canRegen: false
                            signal regen()
                            Layout.fillWidth: true; spacing: 4
                            LogosText { text: cb.label; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                            RowLayout {
                                id: valRow
                                Layout.fillWidth: true; spacing: 8
                                // value shown in a LogosTextField (delivery-demo's input; no readOnly/echoMode — those
                                // crash the DS wrapper in Basecamp). Copy uses the real value regardless of edits.
                                LogosTextField { id: valField; Layout.fillWidth: true; text: (cb.secret && !cb.revealed) ? "••••••••••••••••" : cb.value }
                                // buttons match the field's height (delivery-demo aligns field+button in a row)
                                LogosButton { visible: cb.secret; text: cb.revealed ? "Hide" : "Show"; Layout.preferredHeight: valField.height; onClicked: cb.revealed = !cb.revealed }
                                LogosButton { visible: cb.canRegen; text: "⟳ New"; Layout.preferredHeight: valField.height; onClicked: cb.regen() }
                                LogosButton { text: "Copy"; Layout.preferredHeight: valField.height; onClicked: root.copyText(cb.value) }
                            }
                        }
                        CredBlock { label: "RTMP Server"; value: root.streamCard ? root.streamCard.rtmpUrl : "" }
                        CredBlock {
                            label: "Stream Key"; value: root.streamCard ? root.streamCard.streamKey : ""
                            secret: true; canRegen: true
                            onRegen: root.regenerateKey()
                        }
                        CredBlock {   // #49 private station: the announce topic to share out-of-band with listeners
                            visible: root.streamCard && root.streamCard.visibility === "private"
                            label: "Private directory — share with listeners"
                            value: root.streamCard ? (root.streamCard.announceTopic || "") : ""
                        }
                        CredBlock {   // #24 station fingerprint — the out-of-band anchor listeners verify/pin you by
                            visible: root.streamCard && (root.streamCard.keySource || "anonymous") !== "anonymous"
                                     && (root.streamCard.fingerprint || "").length > 0
                            label: "Station fingerprint — share so listeners verify you"
                            value: root.streamCard ? (root.streamCard.fingerprint || "") : ""
                        }
                        ColumnLayout {
                            visible: root.streamPrivacy === "onion"
                            Layout.fillWidth: true; spacing: 4
                            LogosText { text: "Tor address"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                LogosText {
                                    Layout.fillWidth: true; font.pixelSize: Theme.typography.secondaryText; color: Theme.palette.textMuted; elide: Text.ElideRight
                                    text: root.onionReady ? "stable · persists across restarts" : "publishing…"
                                }
                                LogosButton { text: "⟳ New address"; onClicked: root.regenerateOnion() }
                            }
                        }
                        LogosButton { text: "Stop"; onClicked: root.stopStream() }
                    }
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
