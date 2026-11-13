import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs   // #87 FileDialog/FolderDialog for the playlist (works in Basecamp, see qml-sandbox-restrictions)

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
    property string keycardAuthId: ""
    property string keycardAuthStatus: ""   // "" | pending | complete | error

    // #53 preflight — parse the backend's depsJson; only a real payload (defines `ok`) can show the card,
    // so the "{}" default / parse errors read as ok:true (no spurious flash before the backend publishes).
    function parseDeps(s) {
        var def = { ok: true, os: "", items: [], installCmd: "" }
        if (!s) return def
        try { var d = JSON.parse(s); return (d && typeof d.ok !== "undefined") ? d : def }
        catch (e) { return def }
    }
    readonly property var deps: parseDeps(backend ? backend.depsJson : "")

    // ── #87 Playlist source: stream audio files with no OBS / Liquidsoap ─────────
    function parsePlaylist(s) { if (!s) return {}; try { return JSON.parse(s) || {} } catch (e) { return {} } }
    readonly property var  playlist: parsePlaylist(backend ? backend.playlistJson : "")
    readonly property bool livePlaylist: root.streamCard !== null && root.streamCard.source === "playlist"
    property int  sourceTab: 0        // #87 audio source: 0 Playlist | 1 External (OBS, Liquidsoap…)
    property bool advOpen: false      // #94 Advanced section (visibility, privacy, identity, quality) folded by default
    property bool logOpen: false      // #94 activity log folded to its latest line while setting up
    property int  plOrder: 0          // 0 in order | 1 shuffle
    property int  plEnd: 0            // 0 loop | 1 stop at the end
    readonly property var kbpsChoices: [64, 96, 128, 160]
    property int  plKbpsIdx: 1        // 96 kbps default: listeners pull over Tor (160 measured 0.86x real time)
    property bool plDirty: false      // edited since last sent to radio_module (live "Apply")
    ListModel { id: plItems }         // { path } — files and folders, as chosen
    function plConfig() {
        var items = []
        for (var i = 0; i < plItems.count; i++) items.push(plItems.get(i).path)
        return { items: items, shuffle: root.plOrder === 1, loop: root.plEnd === 0, kbps: root.kbpsChoices[root.plKbpsIdx] }
    }
    function urlToPath(u) {
        var s = u.toString()
        if (s.indexOf("file://") === 0) s = decodeURIComponent(s.substring(7))
        return s
    }
    function addPaths(urls) {
        for (var i = 0; i < urls.length; i++) {
            var p = root.urlToPath(urls[i]), dup = false
            for (var j = 0; j < plItems.count; j++) if (plItems.get(j).path === p) dup = true
            if (!dup && p.length > 0) plItems.append({ "path": p })
        }
        root.plDirty = true
    }
    function baseName(p) { var i = p.lastIndexOf("/"); return i >= 0 ? p.substring(i + 1) : p }
    function mmss(sec) { sec = Math.max(0, Math.floor(sec || 0)); var m = Math.floor(sec / 60), s = sec % 60; return m + ":" + (s < 10 ? "0" : "") + s }
    // Restore the last playlist from radio_module (it persists it in station.json) the first time we hear it.
    onPlaylistChanged: {
        if (plItems.count > 0 || root.plDirty || !root.playlist.config || !root.playlist.config.items) return
        var items = root.playlist.config.items
        for (var i = 0; i < items.length; i++) plItems.append({ "path": items[i] })
        root.plOrder = root.playlist.config.shuffle ? 1 : 0
        root.plEnd = root.playlist.config.loop === false ? 1 : 0
        var k = root.kbpsChoices.indexOf(root.playlist.config.kbps)
        if (k >= 0) root.plKbpsIdx = k
    }
    // #94 one-line summary of the folded Advanced section, and why Go live is disabled (never a mute grey button)
    function advSummary() {
        var s = [visBox.currentIndex === 1 ? "Private" : "Public",
                 privacyBox.currentIndex === 0 ? "IP hidden (Tor)" : "IP visible (LAN)",
                 ["Anonymous", "Autogenerated key", "Keycard"][keyBox.currentIndex] || ""]
        if (root.sourceTab === 0) s.push(root.kbpsChoices[root.plKbpsIdx] + " kbps")
        return s.join(" · ")
    }
    function goLiveBlocker() {
        if (nameField.text.trim().length === 0) return "Name your station"
        if (root.sourceTab === 0 && plItems.count === 0) return "Add at least one audio file"
        if (keyBox.currentIndex === 2 && root.keycardFp.length === 0) return "Connect your Keycard (in Advanced)"
        return ""
    }
    function applyPlaylist() {
        logos.watch(backend.setPlaylist(JSON.stringify(root.plConfig())), function(){ root.plDirty = false }, function(){})
    }
    FileDialog {
        id: addFilesDialog
        title: "Add audio files"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["Audio (*.mp3 *.flac *.m4a *.aac *.ogg *.oga *.opus *.wav *.aif *.aiff *.wma *.mka)", "All files (*)"]
        onAccepted: root.addPaths(selectedFiles)
    }
    FolderDialog {
        id: addFolderDialog
        title: "Add a folder of audio (sub-folders included)"
        onAccepted: root.addPaths([selectedFolder])
    }

    // ── Backend actions (SLOTs via logos.watch) ────────────────────────────────
    function startStream() {
        var onion = privacyBox.currentIndex === 0   // model[0] = Onion (default)
        var usePlaylist = root.sourceTab === 0   // #87 Playlist tab
        var cfg = JSON.stringify({
            name: nameField.text,
            source: usePlaylist ? "playlist" : "external",
            playlist: root.plConfig(),
            visibility: visBox.currentIndex === 1 ? "private" : "public",
            pass: visBox.currentIndex === 1 ? privPassField.text : "",   // #66 non-empty ⇒ encrypted private stream
            privateTopic: visBox.currentIndex === 1 ? privTopicField.text.trim() : "",
            privacy: onion ? "onion" : "public",
            keySource: root.keySrc[keyBox.currentIndex],          // #24 anonymous | autogen | keycard (radio_module derives)
            description: descField.text
        })
        logos.watch(backend.startStream(cfg),
            function(){ root.plDirty = false
                        logEvent("Starting " + nameField.text + (onion ? " · onion" : " · direct") + (usePlaylist ? " · playlist" : ""), "info") },
            function(){ logEvent("Couldn't start the stream.", "error") })
    }
    function stopStream() { logos.watch(backend.stopStream(), function(){ logEvent("Stream stopped", "info") }, function(){}) }
    function regenerateKey() { logos.watch(backend.regenerateKey(), function(){ logEvent("Stream key rotated — re-enter the new key in your streaming software", "warning") }, function(){}) }
    function regenerateOnion() { logos.watch(backend.regenerateOnion(), function(){ logEvent("Rotating Tor address — listeners will rediscover", "warning") }, function(){}) }

    // #7/#24 Connect Keycard — beacon-style visible request: requestAuth pops the keycard UI, then poll
    // checkAuthStatus for the derived bc:radio key; hand it to radio_module to seed the signing identity.
    function callModuleParse(raw) { try { var t = JSON.parse(raw); return typeof t === 'string' ? JSON.parse(t) : t } catch (e) { return null } }
    function connectKeycard() {
        root.keycardAuthStatus = "pending"
        var r = root.callModuleParse(logos.callModule("keycard", "requestAuth", ["bc:radio", "radio_ui"]))
        if (r && r.authId) {
            root.keycardAuthId = r.authId
            keycardAuthPoll.start()
            logEvent("Keycard request sent — approve it on your Keycard", "info")
        } else {
            root.keycardAuthStatus = "error"
            logEvent("Couldn't reach the Keycard module — is it installed + a card inserted?", "error")
        }
    }
    Timer {
        id: keycardAuthPoll
        interval: 1000; repeat: true
        onTriggered: {
            if (root.keycardAuthId === "") { stop(); return }
            var r = root.callModuleParse(logos.callModule("keycard", "checkAuthStatus", [root.keycardAuthId]))
            if (!r) return
            if (r.status === "complete") {
                stop(); root.keycardAuthId = ""; root.keycardAuthStatus = "complete"
                logos.watch(backend.connectKeycard(r.key),   // radio_module seeds identity → keycardFingerprint PROP
                            function(){ logEvent("Keycard linked", "success") }, function(){})
            } else if (r.status === "failed" || r.status === "rejected") {
                stop(); root.keycardAuthId = ""; root.keycardAuthStatus = "error"
                logEvent("Keycard auth " + r.status, "error")
            }
        }
    }

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
    onStreamCardChanged: if (streamCard !== null) logOpen = true   // #94 live: show the log
    onStreamStateChanged: if (streamCard !== null) logEvent("Source: " + sourceLabel(), sourceLive() ? "success" : "warning")
    onOnionReadyChanged: if (onionReady) logEvent("Onion ready · " + onionAddr, "success")
    onOnionErrorChanged: if (onionError.length > 0) logEvent("Tor: " + onionError, "error")

    function copyText(t) { clipHelper.text = t; clipHelper.selectAll(); clipHelper.copy(); clipHelper.text = "" }
    TextEdit { id: clipHelper; visible: false }

    // #57 reusable copy-command box (multi-line) for the dependency card — declared at file root so it
    // resolves everywhere (nested inline components fail qmllint's resolver / can blank the card).
    component CmdBox: Rectangle {
        property string cmd: ""
        Layout.fillWidth: true
        implicitHeight: cbRow.implicitHeight + 12
        radius: 6
        color: Theme.palette.background; border.color: Theme.palette.borderHairline; border.width: 1
        RowLayout {
            id: cbRow
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                      leftMargin: 8; rightMargin: 8 }
            spacing: 8
            LogosText {
                text: cmd
                font.pixelSize: Theme.typography.secondaryText; font.family: "monospace"
                color: Theme.palette.textSecondary
                Layout.fillWidth: true; wrapMode: Text.WrapAnywhere
            }
            Rectangle {
                id: cbBtn
                implicitWidth: 20; implicitHeight: 20; color: "transparent"; Layout.alignment: Qt.AlignVCenter
                opacity: cbArea.containsMouse ? 0.9 : 0.5
                Behavior on opacity { NumberAnimation { duration: 150 } }
                Rectangle { x: 3; y: 6; width: 10; height: 10; color: "transparent"; border.color: Theme.palette.textMuted; border.width: 1; radius: 2 }
                Rectangle { x: 6; y: 3; width: 10; height: 10; color: Theme.palette.background; border.color: Theme.palette.textMuted; border.width: 1; radius: 2 }
                Timer { id: cbFb; interval: 200; onTriggered: cbBtn.opacity = cbArea.containsMouse ? 0.9 : 0.5 }
                MouseArea {
                    id: cbArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.copyText(cmd); cbBtn.opacity = 0.25; cbFb.restart() }
                }
            }
        }
    }

    // #87 small glyph button (↑ ↓ ✕) in the playlist rows — same look as the activity log's clear button.
    component GlyphBtn: Rectangle {
        property string glyph: ""
        property string tip: ""
        signal clicked()
        implicitWidth: 22; implicitHeight: 22; radius: 4; color: "transparent"
        opacity: gbArea.containsMouse ? 0.95 : 0.5
        LogosText { anchors.centerIn: parent; text: glyph; color: Theme.palette.textSecondary; font.pixelSize: 13 }
        MouseArea { id: gbArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
        ToolTip { visible: gbArea.containsMouse && tip.length > 0; text: tip; delay: 500 }
    }

    // #94 form building blocks: one style for section titles, field labels and hints everywhere.
    component SectionTitle: LogosText {
        Layout.fillWidth: true; Layout.topMargin: 6
        color: Theme.palette.text; font.pixelSize: Theme.typography.primaryText; font.weight: Theme.typography.weightBold
    }
    component FieldLabel: LogosText {
        Layout.fillWidth: true; Layout.topMargin: 4
        color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText
    }
    component Hint: LogosText {
        property bool warn: false
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        color: warn ? Theme.palette.warning : Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText
    }

    // #87/#94 playlist editor: shared by the setup form and the live card (both edit root's plItems).
    component PlaylistEditor: ColumnLayout {
        Layout.fillWidth: true; spacing: 6
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: plItems.count === 0 ? emptyCol.implicitHeight + 28 : Math.min(plItems.count, 5) * 28 + 8
            radius: 6; color: Theme.palette.background; border.color: Theme.palette.borderHairline; border.width: 1
            // empty state: says what goes here and offers the two ways to add it, inside the box
            ColumnLayout {
                id: emptyCol
                visible: plItems.count === 0
                anchors.centerIn: parent; width: parent.width - 24; spacing: 8
                LogosText { Layout.alignment: Qt.AlignHCenter; text: "No audio yet"
                            color: Theme.palette.text; font.pixelSize: Theme.typography.primaryText }
                LogosText { Layout.alignment: Qt.AlignHCenter; text: "mp3, flac, m4a, ogg, wav… Folders include their sub-folders."
                            color: Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText }
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter; spacing: 8
                    LogosButton { text: "Add files…"; implicitWidth: 120; implicitHeight: 32; onClicked: addFilesDialog.open() }
                    LogosButton { text: "Add folder…"; implicitWidth: 120; implicitHeight: 32; onClicked: addFolderDialog.open() }
                }
            }
            ListView {
                anchors.fill: parent; anchors.margins: 4
                visible: plItems.count > 0
                clip: true; model: plItems
                ScrollBar.vertical: ScrollBar {}
                delegate: RowLayout {
                    width: ListView.view.width - 8; height: 28; spacing: 2
                    LogosText {
                        text: root.baseName(model.path)
                        color: Theme.palette.text; font.pixelSize: Theme.typography.secondaryText
                        elide: Text.ElideMiddle; Layout.fillWidth: true; Layout.leftMargin: 6
                    }
                    GlyphBtn { glyph: "↑"; tip: "Move up"; visible: index > 0
                               onClicked: { plItems.move(index, index - 1, 1); root.plDirty = true } }
                    GlyphBtn { glyph: "↓"; tip: "Move down"; visible: index < plItems.count - 1
                               onClicked: { plItems.move(index, index + 1, 1); root.plDirty = true } }
                    GlyphBtn { glyph: "✕"; tip: model.path
                               onClicked: { plItems.remove(index, 1); root.plDirty = true } }
                }
            }
        }
        RowLayout {   // once there is audio, adding more sits under the list
            visible: plItems.count > 0
            Layout.fillWidth: true; spacing: 8
            LogosButton { text: "Add files…"; implicitWidth: 120; implicitHeight: 32; onClicked: addFilesDialog.open() }
            LogosButton { text: "Add folder…"; implicitWidth: 120; implicitHeight: 32; onClicked: addFolderDialog.open() }
            LogosText {
                text: plItems.count + (plItems.count === 1 ? " entry" : " entries")
                color: Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText
                horizontalAlignment: Text.AlignRight; Layout.fillWidth: true
            }
        }
        FieldLabel { text: "Order" }
        LogosComboBox { model: ["Play in order", "Shuffle"]; Layout.fillWidth: true
                        currentIndex: root.plOrder; onActivated: { root.plOrder = currentIndex; root.plDirty = true } }
        FieldLabel { text: "When the list ends" }
        LogosComboBox { model: ["Start again from the top", "Stop (silence stays on air)"]; Layout.fillWidth: true
                        currentIndex: root.plEnd; onActivated: { root.plEnd = currentIndex; root.plDirty = true } }
    }

    // #86/#94 Quality = AAC bitrate. Listeners pull the stream over a Tor onion circuit, which is slow and varies.
    component QualityField: ColumnLayout {
        Layout.fillWidth: true; spacing: 6
        FieldLabel { text: "Quality" }
        LogosComboBox {
            Layout.fillWidth: true
            model: ["64 kbps", "96 kbps (recommended)", "128 kbps", "160 kbps"]
            currentIndex: root.plKbpsIdx; onActivated: { root.plKbpsIdx = currentIndex; root.plDirty = true }
        }
        Hint { text: "Listeners stream over Tor. Higher sounds better but may stutter on slow connections."; warn: root.plKbpsIdx === 3 }
    }

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
                LogosText { text: "Booth"; color: Theme.palette.text; font.pixelSize: Theme.typography.panelTitleText; font.weight: Theme.typography.weightBold }
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

        // ── #53 Dependency preflight — broadcast helpers (mediamtx/tor/ffmpeg/torsocks) must be on PATH;
        //    if any are missing, guide the user with copy-able install command(s) + Re-check (no auto-install).
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 10
            visible: !root.deps.ok
            implicitHeight: depCol.implicitHeight + 24
            radius: 8
            color: Theme.palette.backgroundSecondary; border.color: Theme.palette.warning; border.width: 1

            ColumnLayout {
                id: depCol
                anchors { left: parent.left; right: parent.right; top: parent.top
                          leftMargin: 12; rightMargin: 12; topMargin: 12 }
                spacing: 8

                LogosText {
                    text: "⚠ Broadcasting needs a few tools installed"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.primaryText; font.weight: Theme.typography.weightBold
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                }
                // per-helper checklist: ✓ present · ⚠ installed-but-invisible · ✗ missing
                Repeater {
                    model: root.deps.items
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        LogosText { text: modelData.state === "present" ? "✓" : modelData.state === "found_offpath" ? "⚠" : "✗"
                                    color: modelData.state === "present" ? Theme.palette.success : modelData.state === "found_offpath" ? Theme.palette.warning : Theme.palette.error
                                    font.pixelSize: Theme.typography.primaryText; font.family: "monospace" }
                        LogosText { text: modelData.name
                                    color: modelData.state === "present" ? Theme.palette.textSecondary : Theme.palette.text
                                    font.pixelSize: Theme.typography.secondaryText; font.family: "monospace" }
                        LogosText { text: modelData.state === "present" ? "found"
                                        : modelData.state === "found_offpath" ? "installed — not visible to the app" : "missing"
                                    color: modelData.state === "present" ? Theme.palette.textMuted
                                         : modelData.state === "found_offpath" ? Theme.palette.warning : Theme.palette.error
                                    font.pixelSize: Theme.typography.secondaryText
                                    Layout.fillWidth: true; elide: Text.ElideRight }
                    }
                }

                // ── Block A: installed but invisible → point Booth at them ──
                LogosText {
                    visible: root.deps.setenvBlock && root.deps.setenvBlock.length > 0
                    text: "Some tools are installed but this app can't see them (macOS gives GUI apps a minimal PATH). Run this to point Booth at them:"
                    color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                }
                CmdBox {
                    visible: root.deps.setenvBlock && root.deps.setenvBlock.length > 0
                    cmd: root.deps.setenvBlock || ""
                }
                LogosText {
                    visible: root.deps.needsRelaunch === true
                    text: "…then fully quit & relaunch Basecamp (read at launch), and press Re-check."
                    color: Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                }

                // ── Block B: truly missing → install (mediamtx isn't in apt) ──
                LogosText {
                    visible: root.deps.installCmd && root.deps.installCmd.length > 0
                    text: root.deps.pkgMgr === "none"
                          ? "Install the missing tools:"
                          : "Install the missing tools" + (root.deps.pkgMgr ? " (" + root.deps.pkgMgr + (root.deps.os === "linux" ? "; mediamtx isn't in apt" : "") + ")" : "") + ":"
                    color: Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                }
                CmdBox {
                    visible: root.deps.installCmd && root.deps.installCmd.length > 0
                    cmd: root.deps.installCmd || ""
                }

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    LogosButton { text: "Re-check"; implicitWidth: 120; implicitHeight: 32
                                  onClicked: if (backend) backend.checkDeps() }
                    Item { Layout.fillWidth: true }
                }
            }
        }

        // ── Broadcast body ────────────────────────────────────────────────────
        // Scrolls: the setup form (identity, privacy, source, playlist) is taller than the panel, and without
        // this the Start button fell off the bottom with no way to reach it (#87).
        Flickable {
            id: bodyFlick
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: bodyCol.implicitHeight + 32
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: bodyFlick.contentHeight > bodyFlick.height ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded }
            ColumnLayout {
                id: bodyCol
                x: 16; y: 16; width: bodyFlick.width - 32; spacing: 12

                // setup form (#94): Station → Audio → Advanced (folded) → Go live. One column, labels above fields.
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    visible: root.streamCard === null

                    // ── Station: who listeners see ──
                    SectionTitle { text: "Station"; Layout.topMargin: 0 }
                    FieldLabel { text: "Name" }
                    LogosTextField { id: nameField; Layout.fillWidth: true; placeholderText: "What listeners see"; text: "My Station" }
                    FieldLabel { text: "Description (optional)" }
                    LogosTextField { id: descField; Layout.fillWidth: true; placeholderText: "Genre or a short note" }

                    // ── Audio: only this part changes with the source ──
                    SectionTitle { text: "Audio"; Layout.topMargin: 14 }
                    LogosTabBar {
                        Layout.fillWidth: true
                        currentIndex: root.sourceTab
                        onCurrentIndexChanged: root.sourceTab = currentIndex
                        LogosTabButton { text: "Playlist" }
                        LogosTabButton { text: "External" }
                    }
                    Hint {
                        Layout.topMargin: 2
                        text: root.sourceTab === 0
                              ? "Booth plays audio files from this computer. Nothing else to install or run."
                              : "Stream from OBS, Liquidsoap, ffmpeg or any RTMP / WHIP / SRT source. After you go live you'll get a server URL and a stream key to paste into it."
                    }
                    PlaylistEditor { visible: root.sourceTab === 0; Layout.topMargin: 4 }

                    // ── Advanced: settings with good defaults, folded behind a one-line summary ──
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.palette.borderHairline; Layout.topMargin: 14 }
                    Item {
                        Layout.fillWidth: true; implicitHeight: advRow.implicitHeight + 16
                        RowLayout {
                            id: advRow
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                            spacing: 8
                            LogosText { text: root.advOpen ? "▾" : "▸"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.primaryText }
                            LogosText { text: "Advanced"; color: Theme.palette.text; font.pixelSize: Theme.typography.primaryText; font.weight: Theme.typography.weightBold }
                            LogosText { text: root.advOpen ? "" : root.advSummary(); Layout.fillWidth: true; elide: Text.ElideRight
                                        color: Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.advOpen = !root.advOpen }
                    }
                    ColumnLayout {
                        visible: root.advOpen
                        Layout.fillWidth: true; spacing: 6

                        FieldLabel { text: "Visibility"; Layout.topMargin: 0 }
                        LogosComboBox { id: visBox; model: ["Public: listed for everyone", "Private: only people you share it with"]; currentIndex: 0; Layout.fillWidth: true }
                        // #66 private → a passphrase turns the station into a real private stream (secret topic +
                        // encrypted announce). Blank passphrase falls back to the legacy shareable directory (#49).
                        ColumnLayout {
                            visible: visBox.currentIndex === 1
                            Layout.fillWidth: true; spacing: 6
                            FieldLabel { text: "Passphrase (encrypts the stream)" }
                            LogosTextField { id: privPassField; Layout.fillWidth: true; placeholderText: "Listeners need the station name and this" }
                            Hint { text: privPassField.text.length > 0
                                         ? "Encrypted. Listeners need “" + nameField.text + "” and this passphrase."
                                         : "No passphrase: the station uses a shareable directory name instead (not encrypted)." }
                            FieldLabel { text: "Directory name"; visible: privPassField.text.length === 0 }
                            LogosTextField { id: privTopicField; visible: privPassField.text.length === 0; Layout.fillWidth: true
                                             placeholderText: "e.g. my-secret-room" }
                        }

                        FieldLabel { text: "Privacy" }
                        LogosComboBox { id: privacyBox; model: ["Hide my IP (Tor)", "Show my IP (local network only)"]; currentIndex: 0; Layout.fillWidth: true }
                        Hint { warn: privacyBox.currentIndex === 1
                               text: privacyBox.currentIndex === 0
                                     ? "Your IP stays hidden and it works behind NAT. Listeners take a little longer to connect."
                                     : "Local network only, and listeners can see your IP." }

                        // #24 station identity: Anonymous (unsigned) | Autogenerated (device key) | Keycard (portable)
                        FieldLabel { text: "Station identity" }
                        LogosComboBox { id: keyBox; model: ["Anonymous", "Autogenerated key", "Keycard"]
                            Layout.fillWidth: true; currentIndex: 1
                            Component.onCompleted: { if (root.backend) currentIndex = root.backend.identityTier   // #8 restore
                                                     if (currentIndex === 2) root.advOpen = true }               // Keycard needs a connect step
                            onActivated: if (root.backend) logos.watch(root.backend.saveIdentityTier(currentIndex), function(){}, function(){})
                        }
                        Connections {   // #8 the persisted tier may arrive async from the backend
                            target: root.backend; ignoreUnknownSignals: true
                            function onIdentityTierChanged() { keyBox.currentIndex = root.backend.identityTier
                                                               if (keyBox.currentIndex === 2 && root.keycardFp.length === 0) root.advOpen = true }
                        }
                        Hint { warn: keyBox.currentIndex === 0
                               text: keyBox.currentIndex === 0
                                     ? "Listeners can't verify you, and anyone can use the same name."
                                     : keyBox.currentIndex === 1
                                     ? "A key on this device signs your station, so listeners can verify it's you."
                                     : "A key from your Keycard signs your station: the same identity on any device." }
                        // #7/#24 explicit Connect-Keycard step: derive bc:radio now + show the fingerprint before Go live
                        RowLayout {
                            visible: keyBox.currentIndex === 2
                            Layout.fillWidth: true; spacing: 8
                            LogosButton {
                                text: root.keycardFp.length > 0 ? "✓ Keycard linked"
                                    : root.keycardAuthStatus === "pending" ? "Waiting for Keycard…" : "Connect Keycard"
                                enabled: root.keycardFp.length === 0 && root.keycardAuthStatus !== "pending"
                                onClicked: root.connectKeycard()
                            }
                            LogosText {
                                visible: root.keycardFp.length > 0
                                Layout.alignment: Qt.AlignVCenter
                                text: root.keycardFp; color: Theme.palette.success; font.pixelSize: Theme.typography.secondaryText
                            }
                        }

                        QualityField { visible: root.sourceTab === 0 }
                    }

                    // ── the one primary action, right after the last section; says why when it can't go ──
                    LogosButton {
                        Layout.fillWidth: true; Layout.topMargin: 14
                        text: "Go live"
                        enabled: root.goLiveBlocker() === ""
                        onClicked: root.startStream()
                    }
                    Hint { visible: root.goLiveBlocker() !== ""; text: root.goLiveBlocker(); horizontalAlignment: Text.AlignHCenter }
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
                        LogosText { text: root.livePlaylist ? "On air · playlist" : "Stream credentials"; color: Theme.palette.text; font.pixelSize: Theme.typography.primaryText; font.weight: Theme.typography.weightBold }

                        // #87 live playlist: now playing, controls, edit + apply. Replaces the RTMP card.
                        ColumnLayout {
                            visible: root.livePlaylist
                            Layout.fillWidth: true; spacing: 6
                            LogosText { text: "Now playing"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                            LogosText {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: root.playlist.nowPlaying && root.playlist.nowPlaying.length > 0 ? root.playlist.nowPlaying
                                    : root.playlist.state === "ended" ? "The playlist has ended (silence on air)"
                                    : root.playlist.state === "loading" ? "Loading…" : "—"
                                color: Theme.palette.text; font.pixelSize: Theme.typography.primaryText; font.weight: Theme.typography.weightBold
                            }
                            LogosText {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                visible: !!root.playlist.current
                                text: (root.playlist.current ? root.mmss(root.playlist.current.elapsed)
                                       + (root.playlist.current.duration > 0 ? " / " + root.mmss(root.playlist.current.duration) : "") : "")
                                      + (root.playlist.paused ? " · paused" : "")
                                      + (root.playlist.next ? " · next: " + root.playlist.next.title : "")
                                color: Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                LogosButton { text: root.playlist.paused ? "Resume" : "Pause"
                                              onClicked: logos.watch(backend.playlistPause(!root.playlist.paused), function(){}, function(){}) }
                                LogosButton { text: "Next"; enabled: root.playlist.state !== "ended"
                                              onClicked: logos.watch(backend.playlistNext(), function(){}, function(){}) }
                                Item { Layout.fillWidth: true }
                            }
                            LogosText { text: "Now playing text (optional, replaces the track title)"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                LogosTextField { id: npField; Layout.fillWidth: true; placeholderText: "e.g. Sunday session, live from the studio" }
                                LogosButton { text: "Set"; Layout.preferredHeight: npField.height; enabled: npField.text.trim().length > 0
                                              onClicked: logos.watch(backend.setNowPlaying(npField.text), function(){}, function(){}) }
                                LogosButton { text: "Clear"; Layout.preferredHeight: npField.height; visible: root.playlist.nowPlayingOverride === true
                                              onClicked: { npField.text = ""; logos.watch(backend.setNowPlaying(""), function(){}, function(){}) } }
                            }
                            PlaylistEditor {}
                            QualityField {}
                            LogosButton { text: "Apply playlist changes"; visible: root.plDirty; enabled: plItems.count > 0
                                          onClicked: root.applyPlaylist() }
                        }

                        LogosText {
                            visible: !root.livePlaylist
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
                        CredBlock { visible: !root.livePlaylist; label: "RTMP Server"; value: root.streamCard ? root.streamCard.rtmpUrl : "" }
                        CredBlock {
                            visible: !root.livePlaylist
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
            }
        }

        // ── Activity log ──────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 10
            // #94 folded to its latest line until clicked (it took ~170 px of the setup screen to say "announce ready")
            Layout.preferredHeight: root.logOpen ? 172 : 34
            color: Theme.palette.surface; radius: Theme.spacing.radiusMedium
            MouseArea { anchors { left: parent.left; right: parent.right; top: parent.top } height: 30
                        cursorShape: Qt.PointingHandCursor; onClicked: root.logOpen = !root.logOpen }

            Rectangle {
                anchors { top: parent.top; left: parent.left; right: parent.right }
                height: 1; color: Theme.palette.borderHairline
            }
            LogosText { anchors { top: parent.top; left: parent.left; topMargin: 8; leftMargin: 12 }
                   text: (root.logOpen ? "▾ " : "▸ ") + "Activity"; color: Theme.palette.textSecondary; font.pixelSize: Theme.typography.secondaryText; font.weight: Theme.typography.weightBold }
            LogosText {   // folded: the latest event, one line
                visible: !root.logOpen && logModel.count > 0
                anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 8; leftMargin: 90; rightMargin: 64 }
                text: logModel.count > 0 ? logModel.get(logModel.count - 1).msg : ""
                color: logModel.count > 0 ? root.levelColor(logModel.get(logModel.count - 1).level) : Theme.palette.textMuted
                font.pixelSize: Theme.typography.secondaryText; elide: Text.ElideRight
            }

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
                visible: root.logOpen
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
            LogosText { visible: root.logOpen && logModel.count === 0; anchors.centerIn: parent
                   text: "No activity yet"; color: Theme.palette.textMuted; font.pixelSize: Theme.typography.secondaryText }
        }
    }
}
