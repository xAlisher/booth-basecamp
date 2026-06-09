import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// radio_ui — two-tab shell. Logic lives in radio_module (sandbox blocks network/subprocess
// in QML). Call it via logos.callModule("radio_module", method, [args]).
// Sandbox rules (qml-sandbox-restrictions): no QtMultimedia, no QtGraphicalEffects, no network
// URLs, no FileDialog, no Qt.openUrlExternally. Inside layouts use implicitHeight, never height.
Item {
    id: root
    width: 480; height: 640

    property var streamCard: null   // set after startStream succeeds (#7); null = setup form
    property string streamState: "idle"  // polled from getStreamStatus (#8)

    // #8: poll origin status while streaming (skill qml-timer-state-polling).
    Timer {
        interval: 1500; repeat: true
        running: root.streamCard !== null
        onTriggered: { var r = root.callParse("getStreamStatus", []); if (r && r.state) root.streamState = r.state }
    }
    function stateLabel() {
        return root.streamState === "live"      ? "🔴 Live (announcing)"
             : root.streamState === "receiving" ? "Receiving stream…"
                                                 : "Waiting for OBS…"
    }
    function stateColor() {
        return root.streamState === "live"      ? "#e5484d"
             : root.streamState === "receiving" ? "#f5a623"
                                                 : "#8b949e"
    }

    function callParse(method, args) {
        try {
            var raw = logos.callModule("radio_module", method, args || [])
            var t = JSON.parse(raw)
            return (typeof t === "string") ? JSON.parse(t) : t
        } catch (e) { return null }
    }

    // Clipboard via a hidden TextEdit — Qt.openUrlExternally/clipboard APIs are blocked in the sandbox.
    TextEdit { id: clipHelper; visible: false }
    function copyText(t) { clipHelper.text = t; clipHelper.selectAll(); clipHelper.copy(); clipHelper.text = "" }

    function startStream() {
        var cfg = JSON.stringify({
            name: nameField.text,
            visibility: visGroup.checkedButton === privateBtn ? "private" : "public",
            description: descField.text
        })
        var r = callParse("startStream", [cfg])
        if (r && r.ok) { root.streamState = "waiting"; root.streamCard = r }
    }
    function stopStream() { callParse("stopStream", []); root.streamCard = null; root.streamState = "idle" }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        TabBar {
            id: tabs
            Layout.fillWidth: true
            TabButton { text: "Stream" }
            TabButton { text: "Listen" }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabs.currentIndex

            // ---------------- Stream tab (#7) ----------------
            Item {
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 14

                    Label { text: "Stream"; font.pixelSize: 22; font.bold: true }

                    // --- Setup form (shown until a stream starts) ---
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        visible: root.streamCard === null

                        Label { text: "Station name" }
                        TextField {
                            id: nameField
                            Layout.fillWidth: true
                            placeholderText: "What listeners see"
                            text: "My Station"
                        }

                        Label { text: "Visibility" }
                        RowLayout {
                            spacing: 16
                            ButtonGroup { id: visGroup }
                            RadioButton { id: publicBtn; text: "Public"; checked: true; ButtonGroup.group: visGroup }
                            RadioButton { id: privateBtn; text: "Private"; ButtonGroup.group: visGroup }
                        }

                        Label { text: "Description (optional)" }
                        TextField {
                            id: descField
                            Layout.fillWidth: true
                            placeholderText: "Genre or a short note"
                        }

                        Button {
                            text: "Start"
                            enabled: nameField.text.length > 0
                            onClicked: root.startStream()
                        }
                    }

                    // --- OBS setup card (shown once streaming) ---
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        visible: root.streamCard !== null

                        // #8 live status light — polled from getStreamStatus.
                        RowLayout {
                            spacing: 8
                            Rectangle { width: 12; height: 12; radius: 6; color: root.stateColor() }
                            Label { text: root.stateLabel(); font.pixelSize: 15; font.bold: true }
                        }

                        Label { text: "Point OBS here"; font.pixelSize: 16; font.bold: true }
                        Label {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; opacity: 0.7
                            text: "In OBS → Settings → Stream, paste the WHIP URL (Service: WHIP), or use RTMP with the Server + Stream Key below."
                        }

                        component CopyRow: RowLayout {
                            property string label: ""
                            property string value: ""
                            Layout.fillWidth: true
                            spacing: 8
                            Label { text: parent.label; Layout.preferredWidth: 90 }
                            TextField { Layout.fillWidth: true; readOnly: true; text: parent.value }
                            Button { text: "Copy"; onClicked: root.copyText(parent.value) }
                        }

                        CopyRow { label: "WHIP URL"; value: root.streamCard ? root.streamCard.whipUrl : "" }
                        CopyRow { label: "RTMP Server"; value: root.streamCard ? root.streamCard.rtmpUrl : "" }
                        CopyRow { label: "Stream Key"; value: root.streamCard ? root.streamCard.streamKey : "" }

                        Button { text: "Stop"; onClicked: root.stopStream() }
                    }

                    Item { Layout.fillHeight: true }
                }
            }

            // ---------------- Listen tab (#9) ----------------
            Item {
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 16
                    Label { text: "Listen"; font.pixelSize: 22; font.bold: true }
                    Label {
                        text: "Live stations appear here as heartbeats arrive (#9). Tap to play."
                        wrapMode: Text.WordWrap; Layout.fillWidth: true; opacity: 0.7
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }
    }
}
