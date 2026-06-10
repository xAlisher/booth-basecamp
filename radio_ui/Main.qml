import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// radio_ui — dark theme, matching keeper/stash/beacon (palette + header title + dependency
// status pill on the right). Logic lives in radio_module (the QML sandbox blocks network/
// subprocess). Sandbox rules (qml-sandbox-restrictions): no QtMultimedia/QtGraphicalEffects/
// QtQuick.Shapes/FileDialog/network/Qt.openUrlExternally. Inside layouts use implicitHeight.
Item {
    id: root
    width: 480; height: 640

    // ── Dark palette (keeper/stash) ──────────────────────────────────────────
    readonly property color bgPrimary:     "#171717"
    readonly property color bgSecondary:   "#262626"
    readonly property color bgActive:      "#332A27"
    readonly property color textPrimary:   "#FFFFFF"
    readonly property color textSecondary: "#A4A4A4"
    readonly property color textMuted:     "#5D5D5D"
    readonly property color accentOrange:  "#FF5000"
    readonly property color successGreen:  "#22C55E"
    readonly property color warningYellow: "#F59E0B"
    readonly property color errorRed:      "#FB3748"
    readonly property color borderColor:   "#383838"

    // ── State ────────────────────────────────────────────────────────────────
    property var    streamCard:   null
    property string streamState:  "idle"
    property string streamPrivacy: "public"   // public | onion (this host's broadcast)
    property string onionAddr:    ""          // our .onion once published (onion mode)
    property bool   onionReady:   false        // hidden-service descriptor published → reachable
    property string onionError:   ""           // non-empty → Tor setup failed/timed out
    property var    stations:     []
    property string playingName:  ""
    property bool   discoveryStarted: false
    property int    volume:       75
    property string lastError:    ""
    property string deliveryState: "offline"   // offline | ready | connected
    property string deliveryPeerId: ""

    // ── Backend bridge ───────────────────────────────────────────────────────
    function callParse(method, args) {
        try {
            var raw = logos.callModule("radio_module", method, args || [])
            var t = JSON.parse(raw)
            return (typeof t === "string") ? JSON.parse(t) : t
        } catch (e) { return null }
    }
    function errorMessage(code) {
        var m = {
            "name_required": "Enter a station name first.",
            "already_streaming": "You're already broadcasting.",
            "mediamtx_not_found": "Broadcast server (MediaMTX) isn't available on this system.",
            "mediamtx_spawn_failed": "Couldn't start the broadcast server.",
            "mediamtx_port_or_config": "Broadcast server failed to start — a port may already be in use.",
            "config_write_failed": "Couldn't write the broadcast server config.",
            "ffplay_not_found": "Playback unavailable — ffplay (ffmpeg) is missing.",
            "ffplay_failed": "Couldn't start playback for that station.",
            "unsafe_url": "That station's URL is not a safe http(s) stream.",
            "no_url": "That station didn't provide a stream URL.",
            "no_delivery_client": "Discovery service (delivery_module) is unavailable.",
            "invalid_topic": "That topic isn't valid (use /path/like/this).",
            "discovery_not_started": "Open the Listen tab to start discovery first."
        }
        return m[code] || ("Something went wrong (" + code + ").")
    }
    function call(method, args) {
        var r = callParse(method, args)
        if (!r) root.lastError = "No response from radio_module."
        else if (r.ok === false) root.lastError = errorMessage(r.error)
        return r
    }

    function startStream() {
        var onion = privacyGroup.checkedButton === onionBtn
        var cfg = JSON.stringify({
            name: nameField.text,
            visibility: visGroup.checkedButton === privateBtn ? "private" : "public",
            privacy: onion ? "onion" : "public",
            description: descField.text
        })
        root.streamPrivacy = onion ? "onion" : "public"
        root.onionAddr = ""; root.onionReady = false
        var r = call("startStream", [cfg])
        if (r && r.ok) { root.streamState = "waiting"; root.streamCard = r }
    }
    function stopStream() {
        call("stopStream", []); root.streamCard = null; root.streamState = "idle"
        root.streamPrivacy = "public"; root.onionAddr = ""; root.onionReady = false; root.onionError = ""
    }
    function playStation(s) {
        var r = root.call("play", [s.streamUrl, s.name || ""])
        if (r && r.ok) root.playingName = s.name || s.path
    }
    function uptime(ms) {
        if (!ms) return ""
        var sec = Math.floor((Date.now() - ms) / 1000)
        return sec < 60 ? sec + "s" : sec < 3600 ? Math.floor(sec/60) + "m" : Math.floor(sec/3600) + "h"
    }
    function stateLabel() {
        // In onion mode the announce is held until the Tor descriptor publishes (~30–60s).
        if (root.streamPrivacy === "onion" && !root.onionReady
            && (root.streamState === "live" || root.streamState === "receiving"))
            return "Publishing over Tor…"
        return root.streamState === "live" ? "Live (announcing)"
             : root.streamState === "receiving" ? "Receiving stream…" : "Waiting for OBS…"
    }
    function stateColor() {
        return root.streamState === "live" ? root.errorRed
             : root.streamState === "receiving" ? root.warningYellow : root.textMuted
    }
    function deliveryDotColor() {
        return root.deliveryState === "connected" ? root.successGreen
             : root.deliveryState === "ready" ? root.warningYellow : root.errorRed
    }
    function deliveryLabel() {
        return root.deliveryState === "connected" ? "Discovery online"
             : root.deliveryState === "ready" ? "Discovery ready" : "Discovery offline"
    }

    function copyText(t) { clipHelper.text = t; clipHelper.selectAll(); clipHelper.copy(); clipHelper.text = "" }
    TextEdit { id: clipHelper; visible: false }

    // ── Pollers ──────────────────────────────────────────────────────────────
    Timer {  // delivery node status (always — drives the header pill)
        interval: 2000; repeat: true; running: true; triggeredOnStart: true
        onTriggered: { var r = root.callParse("getDeliveryStatus", []);
            if (r && r.ok) { root.deliveryState = r.state; root.deliveryPeerId = r.peerId || "" } }
    }
    Timer {  // origin status while streaming (#8)
        interval: 1500; repeat: true; running: root.streamCard !== null
        onTriggered: { var r = root.callParse("getStreamStatus", [])
            if (r && r.state) { root.streamState = r.state
                if (r.privacy) root.streamPrivacy = r.privacy
                if (r.onion !== undefined) root.onionAddr = r.onion
                if (r.onionReady !== undefined) root.onionReady = r.onionReady
                root.onionError = r.onionError || "" } }
    }
    Timer {  // live directory while on the Listen tab (#9)
        interval: 2000; repeat: true; running: tabs.currentIndex === 1
        onTriggered: { var r = root.callParse("getStations", []); if (r && r.ok) root.stations = r.stations || [] }
    }
    Connections {
        target: tabs
        function onCurrentIndexChanged() {
            if (tabs.currentIndex === 1 && !root.discoveryStarted) {
                root.call("startDiscovery", []); root.discoveryStarted = true
            }
        }
    }

    // ── Reusable dark controls ───────────────────────────────────────────────
    component DarkButton: Button {
        id: db
        contentItem: Text {
            text: db.text; font.pixelSize: 14
            color: !db.enabled ? root.textMuted : root.textPrimary
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 6; implicitHeight: 34; implicitWidth: 72
            color: db.down ? root.bgActive : db.hovered ? "#3a3a3a" : root.bgSecondary
            border.color: root.borderColor; border.width: 1
        }
    }
    component AccentButton: Button {
        id: ab
        contentItem: Text {
            text: ab.text; font.pixelSize: 14; font.bold: true
            color: ab.enabled ? "#FFFFFF" : root.textMuted
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 6; implicitHeight: 34; implicitWidth: 84
            color: !ab.enabled ? root.bgSecondary : ab.down ? "#CC4000" : root.accentOrange
        }
    }
    component DarkField: TextField {
        color: root.textPrimary
        placeholderTextColor: root.textMuted
        selectionColor: root.accentOrange
        background: Rectangle {
            radius: 6; implicitHeight: 34
            color: root.bgSecondary
            border.color: parent && parent.activeFocus ? root.accentOrange : root.borderColor
            border.width: 1
        }
    }
    // Native text layout (no overlap) + dark indicator; label recoloured via palette.
    component DarkRadio: RadioButton {
        id: dr
        spacing: 8
        palette.windowText: root.textPrimary
        indicator: Rectangle {
            implicitWidth: 18; implicitHeight: 18; radius: 9
            x: dr.leftPadding; y: dr.topPadding + (dr.availableHeight - height) / 2
            color: "transparent"; border.width: 2
            border.color: dr.checked ? root.accentOrange : root.textMuted
            Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: 4
                color: root.accentOrange; visible: dr.checked }
        }
    }

    // ── Background ────────────────────────────────────────────────────────────
    Rectangle { anchors.fill: parent; color: root.bgPrimary }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header: title (left) + delivery status pill (right) ──────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 14; Layout.bottomMargin: 6
            spacing: 8
            ColumnLayout {
                spacing: 1
                Label { text: "Radio"; color: root.textPrimary; font.pixelSize: 22; font.bold: true }
                Label { text: "Decentralized broadcast & discovery"; color: root.textSecondary; font.pixelSize: 11 }
            }
            Item { Layout.fillWidth: true }
            Rectangle {  // delivery_module status pill
                height: 28; radius: 14
                implicitWidth: pillRow.implicitWidth + 20
                color: Qt.rgba(0.149, 0.149, 0.149, 0.85)
                border.color: root.borderColor; border.width: 1
                Layout.alignment: Qt.AlignVCenter
                RowLayout {
                    id: pillRow
                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    spacing: 6
                    Rectangle { width: 7; height: 7; radius: 4; Layout.alignment: Qt.AlignVCenter; color: root.deliveryDotColor() }
                    Text { text: root.deliveryLabel(); font.pixelSize: 11; color: root.textPrimary }
                }
            }
        }

        // ── Error banner (#15) ────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
            color: "#3a1d1d"; radius: 6
            visible: root.lastError.length > 0
            implicitHeight: visible ? errRow.implicitHeight + 14 : 0
            RowLayout {
                id: errRow
                anchors.fill: parent; anchors.margins: 7; spacing: 8
                Label { text: "⚠"; color: "#ff9a9a" }
                Label { text: root.lastError; color: "#ff9a9a"; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                Button { text: "✕"; flat: true; onClicked: root.lastError = ""
                    contentItem: Text { text: "✕"; color: "#ff9a9a" } background: null }
            }
        }

        // ── Tabs ──────────────────────────────────────────────────────────────
        TabBar {
            id: tabs
            Layout.fillWidth: true
            Layout.topMargin: 6
            background: Rectangle { color: "transparent" }
            component DarkTab: TabButton {
                id: tb
                contentItem: Text {
                    text: tb.text; font.pixelSize: 15; font.bold: tb.checked
                    color: tb.checked ? root.textPrimary : root.textSecondary
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: "transparent"
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2
                        color: tb.checked ? root.accentOrange : "transparent" }
                }
            }
            DarkTab { text: "Stream" }
            DarkTab { text: "Listen" }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: root.borderColor }

        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            currentIndex: tabs.currentIndex

            // ── Stream tab ────────────────────────────────────────────────────
            Item {
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 16; spacing: 12

                    // setup form
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 10
                        visible: root.streamCard === null
                        Label { text: "Station name"; color: root.textSecondary; font.pixelSize: 12 }
                        DarkField { id: nameField; Layout.fillWidth: true; placeholderText: "What listeners see"; text: "My Station" }
                        Label { text: "Visibility"; color: root.textSecondary; font.pixelSize: 12 }
                        RowLayout {
                            spacing: 16
                            ButtonGroup { id: visGroup }
                            DarkRadio { id: publicBtn;  text: "Public";  checked: true; ButtonGroup.group: visGroup }
                            DarkRadio { id: privateBtn; text: "Private"; ButtonGroup.group: visGroup }
                        }
                        Label { text: "Privacy"; color: root.textSecondary; font.pixelSize: 12 }
                        RowLayout {
                            spacing: 16
                            ButtonGroup { id: privacyGroup }
                            // Onion is the default — internet radio shouldn't be LAN-only or leak the host IP.
                            DarkRadio { id: onionBtn;  text: "Onion (Tor)";  checked: true; ButtonGroup.group: privacyGroup }
                            DarkRadio { id: directBtn; text: "Direct (LAN)"; ButtonGroup.group: privacyGroup }
                        }
                        Label {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 11
                            color: privacyGroup.checkedButton === onionBtn ? root.textMuted : root.warningYellow
                            text: privacyGroup.checkedButton === onionBtn
                                ? "🧅 Listeners reach you over Tor — your IP stays hidden and it works through NAT (no port-forwarding). First connect is slower."
                                : "⚠ Direct mode is LAN-only and exposes your IP to listeners. Use it only for local/low-latency streams."
                        }
                        Label { text: "Description (optional)"; color: root.textSecondary; font.pixelSize: 12 }
                        DarkField { id: descField; Layout.fillWidth: true; placeholderText: "Genre or a short note" }
                        AccentButton { text: "Start"; enabled: nameField.text.length > 0; onClicked: root.startStream() }
                    }

                    // OBS setup card
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 10
                        visible: root.streamCard !== null
                        RowLayout {
                            spacing: 8
                            Rectangle { width: 12; height: 12; radius: 6; color: root.stateColor() }
                            Label { text: root.stateLabel(); color: root.textPrimary; font.pixelSize: 15; font.bold: true }
                        }
                        Label { text: "Point OBS here"; color: root.textPrimary; font.pixelSize: 16; font.bold: true }
                        Label {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; color: root.textSecondary; font.pixelSize: 12
                            text: "In OBS → Settings → Stream, paste the WHIP URL (Service: WHIP), or use RTMP with the Server + Stream Key below. The key is secret — don't share it."
                        }
                        // Onion mode: the publish state + the .onion address listeners discover
                        RowLayout {
                            visible: root.streamPrivacy === "onion"
                            Layout.fillWidth: true; spacing: 8
                            Label { text: "🧅"; font.pixelSize: 13 }
                            Label {
                                Layout.fillWidth: true; elide: Text.ElideMiddle; font.pixelSize: 12
                                color: root.onionError.length > 0 ? root.errorRed
                                     : root.onionReady ? root.successGreen : root.warningYellow
                                text: root.onionError.length > 0 ? "Tor publish timed out — Stop and start again"
                                     : root.onionReady ? ("Onion ready · " + root.onionAddr)
                                     : (root.onionAddr.length > 0 ? "Publishing Tor descriptor…" : "Starting Tor…")
                            }
                            DarkButton {
                                visible: root.onionReady && root.onionAddr.length > 0
                                text: "Copy .onion"
                                onClicked: root.copyText("http://" + root.onionAddr + "/"
                                    + (root.streamCard ? root.streamCard.path : "") + "/index.m3u8")
                            }
                        }
                        component CopyRow: RowLayout {
                            property string label: ""
                            property string value: ""
                            Layout.fillWidth: true; spacing: 8
                            Label { text: parent.label; color: root.textSecondary; Layout.preferredWidth: 90; font.pixelSize: 12 }
                            DarkField { Layout.fillWidth: true; readOnly: true; text: parent.value }
                            DarkButton { text: "Copy"; onClicked: root.copyText(parent.value) }
                        }
                        CopyRow { label: "WHIP URL"; value: root.streamCard ? root.streamCard.whipUrl : "" }
                        CopyRow { label: "RTMP Server"; value: root.streamCard ? root.streamCard.rtmpUrl : "" }
                        CopyRow { label: "Stream Key"; value: root.streamCard ? root.streamCard.streamKey : "" }
                        DarkButton { text: "Stop"; onClicked: root.stopStream() }
                    }
                    Item { Layout.fillHeight: true }
                }
            }

            // ── Listen tab ────────────────────────────────────────────────────
            Item {
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 16; spacing: 12

                    ListView {
                        id: stationList
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true; spacing: 6
                        model: root.stations
                        delegate: ItemDelegate {
                            required property var modelData
                            width: ListView.view ? ListView.view.width : 0
                            onClicked: root.playStation(modelData)
                            background: Rectangle { color: parent.hovered ? root.bgSecondary : "transparent"; radius: 6 }
                            contentItem: ColumnLayout {
                                spacing: 2
                                RowLayout {
                                    spacing: 6
                                    Label { text: modelData.name || "Unknown"; color: root.textPrimary; font.bold: true }
                                    Label {  // over-Tor badge — backend-computed flag (Senty ISSUE-1),
                                             // consistent with playback routing; not a spoofable substring
                                        visible: modelData._onion === true
                                        text: "🧅 Tor"; color: root.warningYellow; font.pixelSize: 10; font.bold: true
                                    }
                                }
                                Label { text: (modelData.host || "") + " · " + root.uptime(modelData.startedAt)
                                        color: root.textSecondary; font.pixelSize: 12 }
                            }
                        }
                    }
                    ColumnLayout {
                        visible: root.stations.length === 0
                        Layout.fillWidth: true; spacing: 8
                        BusyIndicator { running: root.discoveryStarted; Layout.alignment: Qt.AlignHCenter; implicitWidth: 28; implicitHeight: 28 }
                        Label {
                            text: root.discoveryStarted ? "Listening for stations…" : "Open to discover stations"
                            color: root.textMuted; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                        }
                    }
                    RowLayout {  // now-playing (no pause for live)
                        visible: root.playingName.length > 0
                        Layout.fillWidth: true; spacing: 8
                        Label { text: "▶ " + root.playingName; color: root.textPrimary; Layout.fillWidth: true; elide: Text.ElideRight }
                        Slider { from: 0; to: 100; value: root.volume; Layout.preferredWidth: 100
                            onMoved: { root.volume = Math.round(value); root.call("setVolume", [root.volume]) } }
                        DarkButton { text: "Stop"; onClicked: { root.call("stop", []); root.playingName = "" } }
                    }
                    RowLayout {  // + add private topic
                        Layout.fillWidth: true; spacing: 8
                        DarkField { id: topicField; Layout.fillWidth: true; placeholderText: "Add a private topic" }
                        DarkButton { text: "Add"; enabled: topicField.text.length > 0
                            onClicked: { root.call("addTopic", [topicField.text]); topicField.text = "" } }
                    }
                }
            }
        }
    }
}
