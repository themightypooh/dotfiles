// The bar: a strip made of square dots that scatter from the cursor, with open windows
// in the middle, a drawer of pinned apps that grows out of the dots, and a start orb.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Services.SystemTray
import Quickshell.Services.Pipewire
import Quickshell.Bluetooth

PanelWindow {
    id: win
    required property var root

    readonly property int barH: 46
    readonly property int headroom: 84         // room above the bar for the drawer
    readonly property real barTop: headroom

    anchors { left: true; right: true; bottom: true }
    implicitHeight: headroom + barH
    // reserve the bar plus the wave's usual crest, so windows stop above it and stay clickable
    // (the cursor swell can still poke a little higher, but that area is click-through)
    readonly property int crest: 14
    exclusiveZone: barH + crest
    color: "transparent"
    WlrLayershell.namespace: "wavegoo"
    WlrLayershell.layer: WlrLayer.Top

    // only the bar strip (and the open drawer) catch the mouse; the rest is click-through
    mask: Region {
        item: stripHit
        Region { item: drawerHit }
    }
    Item { id: stripHit; x: 0; y: win.barTop - 4; width: win.width; height: win.barH + 4 }
    Item { id: drawerHit; x: drawer.left; y: drawer.top; width: drawer.w; height: drawer.h > 4 ? drawer.h : 0 }

    // pointer tracking for the dots; a handler needs an Item to live in, not the window itself
    Item {
        id: hoverArea
        anchors.fill: parent
        HoverHandler { id: hover }
    }
    readonly property bool inside: hover.hovered
    readonly property point pointer: hover.point.position
    property real fakeX: -1

    // ---- the drawer geometry: a box that grows up out of the bar ------------------
    property bool drawerOpen: false
    QtObject {
        id: drawer
        readonly property real fullW: win.root.pinned.length * 54 + 22
        readonly property real fullH: 70
        property real w: win.drawerOpen ? fullW : 46
        property real h: win.drawerOpen ? fullH : 0
        Behavior on w { SpringAnimation { spring: 3.4; damping: 0.55; epsilon: 0.2 } }
        Behavior on h { SpringAnimation { spring: 3.8; damping: 0.55; epsilon: 0.2 } }
        readonly property real cx: center.x + drawerBtn.x + drawerBtn.width / 2
        readonly property real left: cx - w / 2
        readonly property real right: cx + w / 2
        readonly property real top: win.barTop - Math.max(0, h)
        readonly property real p: Math.max(0, Math.min(1, h / fullH))    // 0..1 open amount
        readonly property real fillet: Math.min(14, Math.max(0, h) * 0.4)
        readonly property real corner: Math.min(16, Math.max(0, h) * 0.5, w / 2)
    }
    Timer { id: drawerAutoClose; interval: 900; onTriggered: win.drawerOpen = false }
    onInsideChanged: if (inside) drawerAutoClose.stop(); else if (drawerOpen && !ctx.visible) drawerAutoClose.start()
    // the drawer shoves the dots up as it rises
    onDrawerOpenChanged: if (drawerOpen) dots.shock(drawer.cx, win.barTop + 4, 70)

    // knock the dots outward (launch / open / close)
    function burst(x, y) { dots.shock(x, y, 120) }

    // debugging hooks: qs -c wavegoo ipc call bardebug state / shock <x> <y>
    IpcHandler {
        target: "bardebug"
        function state(): string { return JSON.stringify({ hovered: win.inside, fast: dots.fast, hov: dots.hov, calm: taskView.calm, awake: dots.awake, px: win.pointer.x, py: win.pointer.y, cols: dots.cols, rows: dots.rows, canvas: dots.debugCanvas() }) }
        function shock(x: real, y: real): void { dots.shock(x, y, 160) }
        // pretend the pointer is resting on the bar at x (for screenshots); -1 to stop
        function fakeHover(x: real): void { win.fakeX = x }
        function tasks(): string { const out = []; for (let i = 0; i < win.root.tasks.count; i++) out.push((win.root.tasks.get(i).active ? "*" : "") + (win.root.tasks.get(i).attention ? "!" : "") + win.root.tasks.get(i).title.slice(0, 30)); return JSON.stringify(out) }
        // menu bar|orb|clock|vpn|task|vol|net|bt|notif|cal  — pops that right-click menu without a click
        function menu(kind: string): void {
            ctx.grabFocus = false   // no real click to grab with; a real right-click restores it

            if (kind === "orb") win.menuAt(orb, "", win.orbMenu())
            else if (kind === "clock") win.menuAt(clockText, "", win.clockMenu())
            else if (kind === "vpn") win.menuAt(vpnPill, "nordvpn", win.vpnMenu())
            else if (kind === "close") { ctx.hide(); cal.visible = false }
            else if (kind === "vol") win.menuAt(volIcon, "audio", win.audioMenu())
            else if (kind === "net") win.openNetMenu(netIcon)
            else if (kind === "bt") win.menuAt(btIcon, "bluetooth", win.btMenu())
            else if (kind === "notif") win.menuAt(bellIcon, "notifications", win.notifMenu())
            else if (kind === "cal") { cal.grabFocus = false; const p = clockText.mapToItem(null, 0, 0); cal.toggle(p.x, win.barTop - 4) }
            else if (kind === "task" && taskView.count) { const t = taskView.itemAtIndex(0); win.menuAt(t, t.title, win.taskMenu(t)) }
            else ctx.show(win.width / 2, win.barTop - 4, "wavegoo", win.barMenu())
        }
    }

    // ---- right-click menus (ContextMenu.qml) ----------------------------------------
    ContextMenu {
        id: ctx
        root: win.root
        bar: win
        // keep the drawer up while a pin's menu is open
        onVisibleChanged: if (!visible && !win.inside && win.drawerOpen) drawerAutoClose.start()
    }
    Calendar { id: cal; root: win.root; bar: win }

    // hover tooltip for windows that aren't showing their title
    PopupWindow {
        id: tip
        property string text: ""
        anchor.window: win
        anchor.rect.width: 1; anchor.rect.height: 1
        anchor.edges: Edges.Top; anchor.gravity: Edges.Top
        color: "transparent"
        implicitWidth: tipCard.width; implicitHeight: tipCard.height + 6
        Rectangle {
            id: tipCard
            width: Math.min(420, tipText.implicitWidth + 20); height: 26; radius: 13
            color: win.root.backing; border.color: win.root.rim; border.width: 1
            Text {
                id: tipText
                anchors.centerIn: parent; width: parent.width - 20
                elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                text: tip.text; color: "white"; font.pixelSize: 11; textFormat: Text.PlainText
            }
        }
    }
    property Item tipFor: null
    Timer { id: tipDelay; interval: 550; onTriggered: if (win.tipFor && !ctx.visible) { const p = win.tipFor.mapToItem(null, win.tipFor.width / 2, 0); tip.anchor.rect.x = Math.round(p.x); tip.anchor.rect.y = Math.round(Math.min(p.y, win.barTop) - 4); tip.visible = true } }
    function tipOn(item, text) { tip.text = text; tipFor = item; if (tip.visible) tipDelay.triggered(); else tipDelay.restart() }
    function tipOff(item) { if (tipFor === item) { tipFor = null; tipDelay.stop(); tip.visible = false } }

    // ---- audio (PipeWire) --------------------------------------------------------
    readonly property var sink: Pipewire.defaultAudioSink
    PwObjectTracker { objects: win.sink ? [win.sink] : [] }
    readonly property real vol: sink && sink.audio ? sink.audio.volume : 0
    readonly property bool muted: !sink || !sink.audio || sink.audio.muted
    function volIcon() {
        if (!sink) return "audio-volume-muted"
        if (muted || vol <= 0) return "audio-volume-muted"
        return vol < 0.34 ? "audio-volume-low" : vol < 0.67 ? "audio-volume-medium" : "audio-volume-high"
    }
    function setVol(v) { if (sink && sink.audio) { sink.audio.muted = false; sink.audio.volume = Math.max(0, Math.min(1, v)) } }
    function toggleMute() { if (sink && sink.audio) sink.audio.muted = !sink.audio.muted }
    function sinkName(n) { return n.description || n.nickname || n.name }
    function audioMenu() {
        const items = [{ slider: true, icon: () => win.volIcon(), get: () => win.vol, set: v => win.setVol(v), act: () => win.toggleMute() },
                       { text: "Mute", icon: "audio-volume-muted", checked: win.muted, act: () => win.toggleMute() }]
        const outs = Pipewire.nodes.values.filter(n => n.isSink && !n.isStream && n.audio)
        if (outs.length > 1) {
            items.push(sep())
            for (const n of outs)
                items.push({ text: sinkName(n), icon: "audio-speakers", checked: n === win.sink, act: () => Pipewire.preferredDefaultAudioSink = n })
        }
        items.push(sep(), { text: "Audio settings", icon: "preferences-desktop-sound", act: () => win.root.run(["systemsettings", "kcm_pulseaudio"]) })
        return items
    }

    // ---- network ------------------------------------------------------------------
    function netIcon() {
        const r = win.root
        if (!r.netKnown) return "network-wireless-disconnected"
        if (r.netType === "ethernet") return "network-wired-activated"
        if (r.netType === "wifi") {
            const s = r.netSignal
            return "network-wireless-signal-" + (s >= 80 ? "excellent" : s >= 55 ? "good" : s >= 30 ? "ok" : s > 5 ? "weak" : "none")
        }
        return r.wifiOn ? "network-wireless-disconnected" : "network-wireless-off"
    }
    // scan results come in async; the menu opens once they're in
    property Item netAnchor: null
    Process {
        id: wifiScan
        command: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                const seen = {}, nets = []
                for (const l of text.split("\n")) {
                    const f = win.root.nmFields(l)
                    if (f.length < 4 || !f[1]) continue
                    // one network can show up once per access point: merge them
                    const n = { on: f[0] === "*", ssid: f[1], signal: parseInt(f[2]) || 0, secure: f[3] !== "" && f[3] !== "--" }
                    const old = seen[n.ssid]
                    if (old) { old.on = old.on || n.on; old.signal = Math.max(old.signal, n.signal); continue }
                    seen[n.ssid] = n
                    nets.push(n)
                }
                nets.sort((a, b) => (b.on - a.on) || (b.signal - a.signal))
                if (win.netAnchor) win.menuAt(win.netAnchor, win.root.netName ? "connected · " + win.root.netName : "network", win.netMenu(nets.slice(0, 10)))
            }
        }
    }
    function openNetMenu(anchorItem) { netAnchor = anchorItem; if (!wifiScan.running) wifiScan.running = true }
    function netMenu(nets) {
        const r = win.root
        const items = [{ text: "Wi-Fi", icon: "network-wireless", checked: r.wifiOn,
                         act: () => { r.run(["nmcli", "radio", "wifi", r.wifiOn ? "off" : "on"]); r.netRefresh() } }]
        if (r.wifiOn && nets.length) {
            items.push(sep())
            for (const n of nets) {
                const lvl = n.signal >= 80 ? "excellent" : n.signal >= 55 ? "good" : n.signal >= 30 ? "ok" : "weak"
                items.push({ text: n.ssid + (n.secure ? "  🔒" : ""), icon: "network-wireless-signal-" + lvl, checked: n.on,
                             // NetworkManager asks Plasma's password prompt for new secured networks
                             act: n.on ? () => r.run(["nmcli", "con", "down", "id", n.ssid])
                                       : () => r.run(["nmcli", "dev", "wifi", "connect", n.ssid]) })
            }
        }
        items.push(sep(), { text: "Network settings", icon: "preferences-system-network", act: () => r.run(["systemsettings", "kcm_networkmanagement"]) })
        return items
    }

    // ---- bluetooth ----------------------------------------------------------------
    readonly property var bt: Bluetooth.defaultAdapter
    readonly property var btDevices: bt ? bt.devices.values.filter(d => d.paired) : []
    readonly property int btConnected: btDevices.filter(d => d.connected).length
    function btMenu() {
        const items = [{ text: "Bluetooth", icon: "preferences-system-bluetooth", checked: win.bt.enabled, act: () => win.bt.enabled = !win.bt.enabled }]
        if (win.bt.enabled && win.btDevices.length) {
            items.push(sep())
            for (const d of win.btDevices)
                items.push({ text: (d.name || d.deviceName) + (d.batteryAvailable ? "  " + Math.round(d.battery * 100) + "%" : ""),
                             icon: d.icon || "bluetooth", checked: d.connected,
                             act: () => d.connected ? d.disconnect() : d.connect() })
        }
        items.push(sep(), { text: "Bluetooth settings", icon: "preferences-system-bluetooth", act: () => win.root.run(["systemsettings", "kcm_bluetooth"]) })
        return items
    }

    // ---- notifications (swaync) -------------------------------------------------------
    function notifMenu() {
        const r = win.root
        return [
            { text: "Show notifications", icon: "notifications", act: () => r.run(["swaync-client", "-op", "-sw"]) },
            { text: "Do not disturb", icon: "notifications-disabled", checked: r.notifDnd, act: () => r.run(["swaync-client", "-d", "-sw"]) },
            { text: "Clear all", icon: "edit-clear-all", enabled: r.notifCount > 0, act: () => r.run(["swaync-client", "-C", "-sw"]) }
        ]
    }

    // pop the menu up from above an item
    function menuAt(item, title, items) {
        const p = item.mapToItem(null, item.width / 2, 0)
        ctx.show(p.x, Math.min(p.y, win.barTop) - 4, title, items)
    }
    function sep() { return { sep: true } }
    // an app's own extra actions from its .desktop file ("New private window", ...)
    function entryActions(entry) {
        const out = []
        if (!entry || !entry.actions) return out
        for (let i = 0; i < entry.actions.length; i++) {
            const a = entry.actions[i]
            out.push({ text: a.name, icon: a.icon || entry.icon, act: () => a.execute() })
        }
        return out
    }
    function pinToggle(entry) {
        if (!entry) return []
        const pinned = win.root.pinIndex(entry) >= 0
        return [{ text: pinned ? "Unpin from drawer" : "Pin to drawer", icon: pinned ? "window-unpin" : "window-pin",
                  act: () => pinned ? win.root.unpin(entry) : win.root.pin(entry) }]
    }

    function taskMenu(task) {
        const id = task.wid, e = task.entry
        const same = []
        for (let i = 0; i < win.root.tasks.count; i++) if (win.root.tasks.get(i).app === task.app) same.push(win.root.tasks.get(i).wid)
        let items = []
        if (task.minimized) items.push({ text: "Restore", icon: "window-restore", act: () => win.root.winCmd("activate", id) })
        else {
            if (!task.active) items.push({ text: "Focus", icon: "go-up", act: () => win.root.winCmd("activate", id) })
            items.push({ text: "Minimize", icon: "window-minimize", act: () => win.root.winCmd("minimize", id) })
        }
        items.push({ text: "Maximize / unmaximize", icon: "window-maximize", act: () => win.root.winCmd("maximize", id) })
        items.push({ text: "Fullscreen", icon: "view-fullscreen", checked: task.fullScreen, act: () => win.root.winCmd("fullscreen", id) })
        items.push({ text: "Keep above others", icon: "window-keep-above", checked: task.keepAbove, act: () => win.root.winCmd("keepabove", id) })
        items.push({ text: "On all desktops", icon: "window-pin", checked: task.allDesktops, act: () => win.root.winCmd("alldesktops", id) })
        if (e) {
            items.push(sep())
            items.push({ text: "New window", icon: e.icon, act: () => e.execute() })
            items = items.concat(entryActions(e), pinToggle(e))
        }
        items.push(sep())
        items.push({ text: "Close", icon: "window-close", danger: true, act: () => task.close() })
        if (same.length > 1)
            items.push({ text: "Close all " + same.length + " windows", icon: "window-close", danger: true, confirm: true,
                         act: () => same.forEach(w => win.root.winCmd("close", w)) })
        return items
    }

    function pinMenu(i, e) {
        const n = win.root.pinned.length
        return [{ text: "Open", icon: e.icon, act: () => e.execute() }]
            .concat(entryActions(e))
            .concat([
                sep(),
                { text: "Move left", icon: "go-previous", enabled: i > 0, act: () => win.root.movePin(i, -1) },
                { text: "Move right", icon: "go-next", enabled: i < n - 1, act: () => win.root.movePin(i, 1) },
                { text: "Unpin", icon: "window-unpin", danger: true, act: () => win.root.unpin(e) }
            ])
    }

    function systemItems() {
        return [
            { text: "System Monitor", icon: "utilities-system-monitor", act: () => win.root.run(["plasma-systemmonitor"]) },
            { text: "System Settings", icon: "preferences-system", act: () => win.root.run(["systemsettings"]) }
        ]
    }

    function orbMenu() {
        const items = [{ text: win.root.launcherOpen ? "Close start menu" : "Open start menu", icon: "start-here-kde",
                         act: () => win.root.launcherOpen = !win.root.launcherOpen }]
            .concat(systemItems(), [sep()])
        for (const a of win.root.powerActions)
            items.push({ text: a.name, icon: a.icon, danger: a.confirm, confirm: a.confirm, act: () => win.root.run(a.cmd) })
        return items
    }

    function clockMenu() {
        const now = new Date()
        return [
            { text: "Copy time", icon: "edit-copy", act: () => Quickshell.clipboardText = Qt.formatDateTime(now, "h:mm ap") },
            { text: "Copy date", icon: "edit-copy", act: () => Quickshell.clipboardText = Qt.formatDateTime(now, "yyyy-MM-dd") },
            sep(),
            { text: "Date & time settings", icon: "preferences-system-time", act: () => win.root.run(["systemsettings", "kcm_clock"]) }
        ]
    }

    function playerMenu() {
        const p = win.root.player
        if (!p) return []
        return [
            { text: p.isPlaying ? "Pause" : "Play", icon: p.isPlaying ? "media-playback-pause" : "media-playback-start",
              enabled: p.canTogglePlaying, act: () => p.togglePlaying() },
            { text: "Next", icon: "media-skip-forward", enabled: p.canGoNext, act: () => p.next() },
            { text: "Previous", icon: "media-skip-backward", enabled: p.canGoPrevious, act: () => p.previous() },
            sep(),
            { text: "Show " + (p.identity || "player"), icon: p.desktopEntry || "multimedia-player", enabled: p.canRaise, act: () => p.raise() }
        ]
    }

    function vpnMenu() {
        const app = DesktopEntries.heuristicLookup("nordvpn-gui")
        const items = [
            { text: win.root.vpnOn ? "Disconnect" : "Connect", icon: win.root.vpnOn ? "network-disconnect" : "network-connect",
              act: () => win.root.toggleVpn() },
            { text: "Refresh status", icon: "view-refresh", act: () => vpnRefresh() }
        ]
        if (app) items.push(sep(), { text: "Open NordVPN", icon: app.icon, act: () => app.execute() })
        return items
    }
    function vpnRefresh() { win.root.vpnPollNow() }

    function barMenu() {
        return [
            { text: "Start menu", icon: "start-here-kde", act: () => win.root.launcherOpen = true },
            { text: win.drawerOpen ? "Close pinned apps" : "Pinned apps", icon: "view-list-icons", act: () => win.drawerOpen = !win.drawerOpen },
            { text: "Show desktop", icon: "user-desktop", act: () => win.root.kwinShortcut("Show Desktop") },
            { text: win.root.autoOrder ? "Tabs: sorted by use ✓" : "Tabs: sort by use", icon: "view-sort",
              act: () => win.root.setAutoOrder(!win.root.autoOrder) },
            { text: "Overview", icon: "view-grid", act: () => win.root.kwinShortcut("Overview") }
        ].concat([sep()], systemItems(), [
            sep(),
            { text: "Edit bar files", icon: "document-edit", act: () => win.root.run(["xdg-open", Quickshell.shellPath("")]) },
            { text: "Reset pinned apps", icon: "edit-undo", confirm: true, act: () => win.root.setPins(win.root.defaultPins) },
            { text: "Restart bar", icon: "view-refresh", act: () => Quickshell.reload(true) }
        ])
    }

    // ---- the dot surface (physics in DotSurface.qml) --------------------------------
    DotSurface {
        id: dots
        anchors.fill: parent
        barTop: win.barTop
        box: Qt.vector4d(drawer.left, drawer.top, drawer.right, win.barTop + drawer.corner + 2)
        corner: drawer.corner
        fillet: drawer.fillet
        pointer: win.fakeX >= 0 ? Qt.point(win.fakeX, win.barTop + 22) : win.pointer
        hovered: win.inside || win.fakeX >= 0
        dotColor: win.root.dotColor
        litColor: win.root.litColor
        backing: win.root.backing
        gradA: win.root.gooA
        gradB: win.root.gooB
        grainM: win.root.grainM
        grainC: win.root.grainC
        grainY: win.root.grainY
        paused: win.root.idle || (win.root.fullscreenOutput !== "" && win.root.fullscreenOutput === win.screen.name)
    }
    // share the wave clock with the start menu (it draws the same grain field, so they must agree)
    Binding { target: win.root; property: "waveTime"; value: dots.time }

    // right-click on empty bar
    MouseArea {
        x: stripHit.x; y: stripHit.y; width: stripHit.width; height: stripHit.height
        acceptedButtons: Qt.RightButton
        onClicked: m => ctx.show(m.x, win.barTop - 4, "wavegoo", win.barMenu())
    }

    // ---- drawer contents: pinned apps ---------------------------------------
    Row {
        id: pinRow
        x: drawer.cx - width / 2
        y: drawer.top + 12
        spacing: 8
        visible: drawer.p > 0.05
        Repeater {
            model: win.root.pinned
            delegate: Item {
                id: pin
                required property string modelData
                required property int index
                readonly property var entry: DesktopEntries.applications.values.length >= 0 ? DesktopEntries.heuristicLookup(modelData) : null
                width: 46; height: 46
                // icons pop in one after another as the drawer opens
                readonly property real show: Math.max(0, Math.min(1, (drawer.p - 0.35 - index * 0.06) / 0.35))
                opacity: show
                scale: (0.4 + show * 0.6) * (pinMouse.containsMouse ? 1.18 : 1)
                Behavior on scale { SpringAnimation { spring: 5; damping: 0.55 } }
                Rectangle {
                    anchors.fill: parent; radius: 23
                    color: "#ffffff"; opacity: pinMouse.containsMouse ? 0.22 : 0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                }
                IconImage {
                    anchors.centerIn: parent; implicitSize: 30
                    source: pin.entry ? Quickshell.iconPath(pin.entry.icon, "application-x-executable") : ""
                }
                MouseArea {
                    id: pinMouse
                    anchors.fill: parent; hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: m => {
                        if (m.button === Qt.RightButton) {
                            if (pin.entry) win.menuAt(pin, pin.entry.name, win.pinMenu(pin.index, pin.entry))
                            return
                        }
                        if (pin.entry) pin.entry.execute()
                        const p = pin.mapToItem(null, 23, 23)
                        win.burst(p.x, p.y, 55)
                        win.drawerOpen = false
                    }
                }
            }
        }
    }

    // The floaters lag behind the wave on loose springs, but only while the pointer is on the bar.
    // Idle, the wave ticks at 30fps and they just follow it: springs chasing a moving target never
    // settle, so they'd keep the bar redrawing at the full screen rate all day.
    readonly property bool springy: dots.fast
    // bar contents ride the wave: shift for something centred at x (negative = up)
    function ride(x) { return dots.waveLift(x) * 0.65 }
    // ...and float on it like buoys: swaying side to side and bobbing on their own rhythm
    function rock(x) { return Math.sin(dots.time * 1.1 + x / 37) * 3.5 }                  // swings through upright
    function sway(x) { return Math.sin(dots.time * 1.1 + x / 37 + 0.6) * 1.8 }            // side to side, with the swing
    function bob(x) { return Math.sin(dots.time * 1.3 + x / 53) * 1.6 }
    // dock-style magnify for things near the cursor
    function magnify(x) { return 1 + 0.3 * Math.exp(-Math.pow((x - dots.mouseX) / 70, 2)) * dots.hov }

    // ---- left: start orb, clock, now playing -----------------------------------
    Row {
        id: leftRow
        x: 14
        y: win.barTop + (win.barH - height) / 2
        spacing: 14

        Item {
            id: orb
            width: 34; height: 34
            anchors.verticalCenter: parent.verticalCenter
            // floats: rides the wave, sways side to side, and lags behind on a loose spring
            transform: Translate {
                x: win.sway(leftRow.x + orb.x + 17)
                y: win.ride(leftRow.x + orb.x + 17) + win.bob(leftRow.x + orb.x + 17)
                Behavior on y { enabled: win.springy; SpringAnimation { spring: 3; damping: 0.22 } }
            }
            rotation: win.rock(leftRow.x + orb.x + 17)
            Behavior on rotation { enabled: win.springy; SpringAnimation { spring: 2.5; damping: 0.2 } }
            scale: win.magnify(leftRow.x + orb.x + 17)
            Rectangle {
                anchors.centerIn: parent
                width: 34; height: 34; radius: 17
                color: "#ffffff"
                opacity: orbMouse.containsMouse || win.root.launcherOpen ? 0.3 : 0.16
                Behavior on opacity { NumberAnimation { duration: 160 } }
            }
            Rectangle {
                anchors.centerIn: parent
                width: 14; height: 14; radius: 7
                color: "#ffffff"
                scale: win.root.launcherOpen ? 1.45 : 1
                Behavior on scale { SpringAnimation { spring: 6; damping: 0.55 } }
            }
            MouseArea {
                id: orbMouse
                anchors.fill: parent; hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: m => {
                    if (m.button === Qt.RightButton) { win.menuAt(orb, "", win.orbMenu()); return }
                    win.root.launcherOpen = !win.root.launcherOpen
                    const p = orb.mapToItem(null, 17, 17)
                    win.burst(p.x, p.y, 30)
                }
            }
        }
        Text {
            text: Qt.formatDateTime(win.root.now, "h:mm ap")   // 12-hour
            color: "white"; font.pixelSize: 17; font.family: "monospace"; font.weight: Font.Medium
            anchors.verticalCenter: parent.verticalCenter
            id: clockText
            MouseArea {
                anchors.fill: parent; anchors.margins: -4
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: m => {
                    if (m.button === Qt.RightButton) win.menuAt(clockText, Qt.formatDateTime(win.root.now, "dddd, MMMM d"), win.clockMenu())
                    else { const p = clockText.mapToItem(null, 0, 0); cal.toggle(p.x, win.barTop - 4) }
                }
            }
            // floats: rides the wave, sways side to side, and lags behind on a loose spring
            transform: Translate {
                x: win.sway(leftRow.x + clockText.x + clockText.width / 2)
                y: win.ride(leftRow.x + clockText.x + clockText.width / 2) + win.bob(leftRow.x + clockText.x + clockText.width / 2)
                Behavior on y { enabled: win.springy; SpringAnimation { spring: 3; damping: 0.22 } }
            }
            rotation: win.rock(leftRow.x + clockText.x + clockText.width / 2)
            Behavior on rotation { enabled: win.springy; SpringAnimation { spring: 2.5; damping: 0.2 } }
        }
        Text {
            text: Qt.formatDateTime(win.root.now, "ddd MMM d").toLowerCase()
            color: "#aaffffff"; font.pixelSize: 12
            anchors.verticalCenter: parent.verticalCenter
            id: dateText
            MouseArea {
                anchors.fill: parent; anchors.margins: -4
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: m => {
                    if (m.button === Qt.RightButton) win.menuAt(dateText, Qt.formatDateTime(win.root.now, "dddd, MMMM d"), win.clockMenu())
                    else { const p = clockText.mapToItem(null, 0, 0); cal.toggle(p.x, win.barTop - 4) }
                }
            }
            // floats: rides the wave, sways side to side, and lags behind on a loose spring
            transform: Translate {
                x: win.sway(leftRow.x + dateText.x + dateText.width / 2)
                y: win.ride(leftRow.x + dateText.x + dateText.width / 2) + win.bob(leftRow.x + dateText.x + dateText.width / 2)
                Behavior on y { enabled: win.springy; SpringAnimation { spring: 3; damping: 0.22 } }
            }
            rotation: win.rock(leftRow.x + dateText.x + dateText.width / 2)
            Behavior on rotation { enabled: win.springy; SpringAnimation { spring: 2.5; damping: 0.2 } }
        }
        Text {
            visible: win.root.player !== null && win.root.player.trackTitle !== ""
            text: win.root.player ? ((win.root.playing ? "♪ " : "❚❚ ") + win.root.player.trackTitle) : ""
            textFormat: Text.PlainText
            color: "#ddffffff"; font.pixelSize: 12
            width: Math.min(implicitWidth, 240); elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
            id: trackText
            MouseArea {
                anchors.fill: parent; anchors.margins: -4
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onClicked: m => {
                    if (m.button !== Qt.RightButton) { if (win.root.player) win.root.player.togglePlaying(); return }
                    win.menuAt(trackText, win.root.player ? win.root.player.trackTitle : "", win.playerMenu())
                }
            }
            // floats: rides the wave, sways side to side, and lags behind on a loose spring
            transform: Translate {
                x: win.sway(leftRow.x + trackText.x + trackText.width / 2)
                y: win.ride(leftRow.x + trackText.x + trackText.width / 2) + win.bob(leftRow.x + trackText.x + trackText.width / 2)
                Behavior on y { enabled: win.springy; SpringAnimation { spring: 3; damping: 0.22 } }
            }
            rotation: win.rock(leftRow.x + trackText.x + trackText.width / 2)
            Behavior on rotation { enabled: win.springy; SpringAnimation { spring: 2.5; damping: 0.2 } }
        }
    }

    // ---- sticky notes (goonotes) + its file cabinet + corkboard + the hourglass timer, halfway between the now-playing text and the drawer button --
    // left = new note (pops up over your windows), right = lift all notes over your windows / drop them back,
    // middle = notes drawer. Starts goonotes if it isn't running.
    Item {
        id: notesSlot
        width: notesPair.width; height: 22
        x: Math.round((leftRow.x + leftRow.width + center.x) / 2 - width / 2)
        y: win.barTop + (win.barH - height) / 2
        function notes(call) {
            win.root.run(["sh", "-c", "qs -c goonotes ipc call notes " + call + " 2>/dev/null || qs -c goonotes -d"])
        }
        Row {
        id: notesPair
        height: 22
        spacing: 12
        StatusIcon {
            id: notesIcon
            bar: win; row: notesSlot
            x: 0
            icon: "view-pim-notes"
            tint: win.root.grainY
            onClicked: b => notesSlot.notes(b === Qt.RightButton ? "peek" : b === Qt.MiddleButton ? "drawer" : "add")
        }
        // the file cabinet: click to bring it up over your windows (click again, or leave it, and it sinks back)
        StatusIcon {
            id: cabinetIcon
            bar: win; row: notesSlot
            icon: "archive-insert"
            onClicked: b => notesSlot.notes(b === Qt.MiddleButton ? "drawer" : "cabinet")
        }
        // the corkboard: click to open / close it, middle = notes drawer
        StatusIcon {
            id: boardIcon
            bar: win; row: notesSlot
            icon: "dashboard-show"
            tint: win.root.grainM
            onClicked: b => notesSlot.notes(b === Qt.MiddleButton ? "drawer" : "board")
        }
        // the hourglass timer: left = bring it up over your windows, right = start / pause,
        // middle = reset, scroll = set the time. Starts it if it isn't running.
        StatusIcon {
            id: hourglassIcon
            bar: win; row: notesSlot
            icon: "chronometer"
            tint: win.root.grainC
            function hg(call) {
                win.root.run(["sh", "-c", "qs -c hourglass ipc call hourglass " + call + " 2>/dev/null || qs -c hourglass -d"])
            }
            onClicked: b => hg(b === Qt.RightButton ? "toggle" : b === Qt.MiddleButton ? "reset" : "peek")
            onWheel: up => hg("nudge " + (up ? 1 : -1))
        }
        }
    }

    // ---- center: drawer button + open windows ---------------------------------
    Row {
        id: center
        x: (win.width - width) / 2
        y: win.barTop + (win.barH - height) / 2
        spacing: 6
        Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        Item {
            id: drawerBtn
            width: 40; height: 36
            // floats: rides the wave, sways side to side, and lags behind on a loose spring
            transform: Translate {
                x: win.sway(center.x + drawerBtn.x + 20)
                y: win.ride(center.x + drawerBtn.x + 20) + win.bob(center.x + drawerBtn.x + 20)
                Behavior on y { enabled: win.springy; SpringAnimation { spring: 3; damping: 0.22 } }
            }
            rotation: win.rock(center.x + drawerBtn.x + 20)
            Behavior on rotation { enabled: win.springy; SpringAnimation { spring: 2.5; damping: 0.2 } }
            Grid {
                anchors.centerIn: parent
                scale: win.magnify(center.x + drawerBtn.x + 20)
                columns: 3; spacing: 4
                rotation: win.drawerOpen ? 45 : 0
                Behavior on rotation { SpringAnimation { spring: 4; damping: 0.55 } }
                Repeater {
                    model: 9
                    Rectangle { width: 4; height: 4; radius: 2; color: "white"; opacity: drawerMouse.containsMouse || win.drawerOpen ? 1 : 0.75 }
                }
            }
            MouseArea {
                id: drawerMouse
                anchors.fill: parent; hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: m => {
                    if (m.button === Qt.RightButton)
                        win.menuAt(drawerBtn, "pinned apps", [
                            { text: win.drawerOpen ? "Close" : "Open", icon: "view-list-icons", act: () => win.drawerOpen = !win.drawerOpen },
                            { text: "Reset to defaults", icon: "edit-undo", confirm: true, act: () => win.root.setPins(win.root.defaultPins) }
                        ])
                    else win.drawerOpen = !win.drawerOpen
                }
            }
        }

        Rectangle { width: 1; height: 22; color: "#44ffffff"; anchors.verticalCenter: parent.verticalCenter }

        ListView {
            id: taskView
            orientation: ListView.Horizontal
            interactive: false
            spacing: 4
            height: 36
            width: contentWidth
            model: win.root.tasks
            anchors.verticalCenter: parent.verticalCenter

            add: Transition {
                NumberAnimation { property: "scale"; from: 0; to: 1; duration: 380; easing.type: Easing.OutCubic }
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200 }
            }
            remove: Transition {
                NumberAnimation { property: "scale"; to: 0; duration: 220; easing.type: Easing.InBack }
                NumberAnimation { property: "opacity"; to: 0; duration: 220 }
            }
            displaced: Transition { NumberAnimation { properties: "x"; duration: 260; easing.type: Easing.OutCubic } }

            // tabs hold still while the pointer is over them, so clicks (and the ✕) land
            HoverHandler { id: tasksHover }
            readonly property bool held: tasksHover.hovered
            onHeldChanged: win.root.tasksHovered = held
            property real calm: tasksHover.hovered ? 0 : 1
            Behavior on calm { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            // wheel over the windows cycles through them, like Plasma's task manager
            WheelHandler {
                onWheel: e => {
                    const t = win.root.tasks, n = t.count
                    if (!n) return
                    let cur = -1
                    for (let i = 0; i < n; i++) if (t.get(i).active) cur = i
                    const next = cur < 0 ? 0 : (cur + (e.angleDelta.y > 0 ? -1 : 1) + n) % n
                    win.root.winCmd("activate", t.get(next).wid)
                }
            }

            delegate: Item {
                id: task
                required property int index
                required property string wid
                required property string title
                required property string app
                required property string desktop
                required property bool active
                required property bool minimized
                required property bool keepAbove
                required property bool fullScreen
                required property bool allDesktops
                required property bool attention
                readonly property var entry: DesktopEntries.applications.values.length >= 0 ? win.root.entryFor(desktop, app) : null
                // no hover close button (it kept getting hit by accident): middle-click or right-click > Close
                readonly property bool hot: taskMouse.containsMouse

                height: 36
                // Tabs hold still: one fixed size, no title widening, no tilting or swaying.
                // They only bob gently up and down with the wave (and rise a bit when a window
                // wants attention), so nothing ever shifts sideways under the pointer.
                readonly property real iconSize: 24
                property real rise: attention && !active ? 7 : 0
                Behavior on rise { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                readonly property real gx: center.x + taskView.x + task.x + 11 + iconSize / 2   // icon centre on screen
                z: taskMouse.dragging ? 10 : 0
                opacity: taskMouse.dragging ? 0.85 : 1
                // floats: rides the wave, sways side to side, and lags behind on a loose spring
                // (all of it fades out while the pointer is over the tabs)
                transform: Translate {
                    y: (win.ride(task.gx) + win.bob(task.gx)) * 0.6 * taskView.calm - task.rise
                    // the spring would wobble as they settle, so it's off while calming down
                    Behavior on y { enabled: win.springy && taskView.calm > 0.99; SpringAnimation { spring: 3; damping: 0.22 } }
                }
                // measure the title separately so the label's own width can't feed back into ours
                TextMetrics { id: titleMetrics; text: task.title; font.pixelSize: 12 }
                width: iconSize + 22          // fixed: the window title shows in the tooltip instead
                Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }   // no overshoot

                Rectangle {
                    anchors.fill: parent; radius: 18
                    color: "#ffffff"
                    opacity: task.active ? 0.26 : task.hot ? 0.14 : 0
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                }
                // wants attention: a warm pulse until you look at it
                Rectangle {
                    anchors.fill: parent; radius: 18
                    visible: task.attention && !task.active
                    color: "transparent"; border.color: "#ffb36b"; border.width: 1.5
                    SequentialAnimation on opacity {
                        running: task.attention && !task.active; loops: Animation.Infinite
                        NumberAnimation { from: 1; to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.25; to: 1; duration: 650; easing.type: Easing.InOutSine }
                    }
                    Rectangle { anchors.fill: parent; radius: 18; color: "#ffb36b"; opacity: 0.18 }
                }
                // a little glowing dot under the focused window
                Rectangle {
                    width: task.active ? 14 : 4; height: 3; radius: 1.5
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom; anchors.bottomMargin: -3
                    color: "white"
                    opacity: task.minimized ? 0 : task.active ? 1 : 0.5
                    Behavior on width { SpringAnimation { spring: 5; damping: 0.55 } }
                }
                IconImage {
                    id: icon
                    x: 11; anchors.verticalCenter: parent.verticalCenter
                    implicitSize: task.iconSize
                    scale: 1 + (win.magnify(task.gx) - 1) * taskView.calm
                    source: task.entry ? Quickshell.iconPath(task.entry.icon, "application-x-executable")
                                       : Quickshell.iconPath(task.app.toLowerCase(), "application-x-executable")
                }
                Text {
                    id: label
                    x: task.iconSize + 18; anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, task.width - task.iconSize - 22 - 6)
                    text: task.title
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: "white"; font.pixelSize: 12
                    opacity: task.active && width > 20 ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                }
                MouseArea {
                    id: taskMouse
                    anchors.fill: parent; hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    onContainsMouseChanged: if (containsMouse) win.tipOn(task, task.title); else win.tipOff(task)
                    // drag sideways to reorder (switches the bar's auto-drift off)
                    preventStealing: true
                    property real pressX: 0
                    property bool dragging: false
                    onPressed: m => { win.tipOff(task); pressX = m.x; dragging = false }
                    onPositionChanged: m => {
                        if (!(pressedButtons & Qt.LeftButton)) return
                        if (!dragging && Math.abs(m.x - pressX) > 8) dragging = true
                        if (!dragging) return
                        const p = taskMouse.mapToItem(taskView.contentItem, m.x, task.height / 2)
                        const to = taskView.indexAt(p.x, p.y)
                        const t = to >= 0 ? taskView.itemAtIndex(to) : null
                        if (!t || to === task.index) return
                        // only swap once the pointer is past the middle of the tab it's moving onto
                        if ((to > task.index && p.x < t.x + t.width / 2) || (to < task.index && p.x > t.x + t.width / 2)) return
                        win.root.moveTask(task.index, to)
                    }
                    onReleased: if (dragging) win.root.saveOrder()
                    onClicked: m => {
                        if (dragging) { dragging = false; return }
                        if (m.button === Qt.MiddleButton) task.close()
                        else if (m.button === Qt.RightButton) win.menuAt(task, task.title, win.taskMenu(task))
                        else win.root.winCmd("toggle", task.wid)
                    }
                }
                function close() {
                    const p = task.mapToItem(null, 22, 18)
                    win.burst(p.x, p.y, 45)
                    win.root.winCmd("close", task.wid)
                }
                Component.onDestruction: win.tipOff(task)
                Component.onCompleted: if (win.root.tasksReady) {
                    const p = task.mapToItem(null, 22, 18)
                    win.burst(p.x, p.y, 25)
                }
            }
        }
    }

    // ---- far right: peek at desktop, like Plasma's corner button ---------------------
    Rectangle {
        id: peek
        anchors.right: parent.right
        y: win.barTop + 8; width: 6; height: win.barH - 16; radius: 3
        color: "white"
        opacity: peekMouse.containsMouse ? 0.35 : 0.0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        MouseArea {
            id: peekMouse
            anchors.fill: parent; anchors.leftMargin: -4; anchors.topMargin: -8; anchors.bottomMargin: -8
            hoverEnabled: true
            onClicked: win.root.kwinShortcut("Show Desktop")
        }
    }

    // ---- right: tray + vpn -------------------------------------------------------
    Row {
        id: rightRow
        anchors.right: parent.right; anchors.rightMargin: 18
        y: win.barTop + (win.barH - height) / 2
        spacing: 12
        Repeater {
            model: SystemTray.items
            delegate: IconImage {
                id: trayIcon
                required property var modelData
                implicitSize: 18
                // qBittorrent re-sends its tray pixmap constantly (it bakes in the speed); fetching it
                // over and over cost ~1.5% CPU, so show its themed icon instead
                source: modelData.id === "qBittorrent" ? Quickshell.iconPath("qbittorrent-tray", "qbittorrent") : modelData.icon
                anchors.verticalCenter: parent.verticalCenter
                // floats: rides the wave, sways side to side, and lags behind on a loose spring
                transform: Translate {
                    x: win.sway(rightRow.x + trayIcon.x + 9)
                    y: win.ride(rightRow.x + trayIcon.x + 9) + win.bob(rightRow.x + trayIcon.x + 9)
                    Behavior on y { enabled: win.springy; SpringAnimation { spring: 3; damping: 0.22 } }
                }
                rotation: win.rock(rightRow.x + trayIcon.x + 9)
                Behavior on rotation { enabled: win.springy; SpringAnimation { spring: 2.5; damping: 0.2 } }
                scale: win.magnify(rightRow.x + trayIcon.x + 9) * (trayMouse.containsMouse ? 1.1 : 1)
                MouseArea {
                    id: trayMouse
                    anchors.fill: parent; anchors.margins: -4
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    onClicked: m => {
                        if (m.button === Qt.RightButton && trayIcon.modelData.hasMenu) {
                            const p = trayIcon.mapToItem(null, 0, 0)
                            trayIcon.modelData.display(win, p.x, win.barTop - 6)
                        } else if (m.button === Qt.LeftButton) trayIcon.modelData.activate()
                        else trayIcon.modelData.secondaryActivate()
                    }
                }
            }
        }
        StatusIcon {
            id: btIcon
            bar: win; row: rightRow
            visible: !!win.bt
            icon: win.bt && win.bt.enabled ? (win.btConnected ? "network-bluetooth-activated" : "network-bluetooth") : "network-bluetooth"
            dim: !win.bt || !win.bt.enabled
            onClicked: b => { if (b === Qt.MiddleButton) win.bt.enabled = !win.bt.enabled; else win.menuAt(btIcon, win.btConnected ? win.btConnected + " connected" : "bluetooth", win.btMenu()) }
        }
        StatusIcon {
            id: netIcon
            bar: win; row: rightRow
            icon: win.netIcon()
            dim: win.root.netType === ""
            onClicked: b => win.openNetMenu(netIcon)
        }
        StatusIcon {
            id: volIcon
            bar: win; row: rightRow
            visible: !!win.sink
            icon: win.volIcon()
            level: win.muted ? 0 : win.vol
            onClicked: b => { if (b === Qt.MiddleButton) win.toggleMute(); else win.menuAt(volIcon, win.sink ? win.sinkName(win.sink).toLowerCase() : "audio", win.audioMenu()) }
            onWheel: up => win.setVol(win.vol + (up ? 0.05 : -0.05))
        }
        StatusIcon {
            id: bellIcon
            bar: win; row: rightRow
            visible: win.root.notifKnown
            icon: win.root.notifDnd ? "notifications-disabled" : win.root.notifCount > 0 ? "notification-active" : "notification-inactive"
            badge: win.root.notifCount > 0 && !win.root.notifDnd ? (win.root.notifCount > 99 ? "99+" : String(win.root.notifCount)) : ""
            onClicked: b => {
                if (b === Qt.RightButton) win.menuAt(bellIcon, "notifications", win.notifMenu())
                else if (b === Qt.MiddleButton) win.root.run(["swaync-client", "-d", "-sw"])
                else win.root.run(["swaync-client", "-t", "-sw"])
            }
        }
        Rectangle {
            id: vpnPill
            height: 24; radius: 12
            width: vpnText.implicitWidth + 20
            color: win.root.vpnOn ? "#2affffff" : "#33000000"
            border.color: win.root.vpnOn ? "#9fe1cb" : "#f09595"
            border.width: 1
            anchors.verticalCenter: parent.verticalCenter
            // floats: rides the wave, sways side to side, and lags behind on a loose spring
            transform: Translate {
                x: win.sway(rightRow.x + vpnPill.x + vpnPill.width / 2)
                y: win.ride(rightRow.x + vpnPill.x + vpnPill.width / 2) + win.bob(rightRow.x + vpnPill.x + vpnPill.width / 2)
                Behavior on y { enabled: win.springy; SpringAnimation { spring: 3; damping: 0.22 } }
            }
            rotation: win.rock(rightRow.x + vpnPill.x + vpnPill.width / 2)
            Behavior on rotation { enabled: win.springy; SpringAnimation { spring: 2.5; damping: 0.2 } }
            Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }
            Text {
                id: vpnText
                anchors.centerIn: parent
                text: !win.root.vpnKnown ? "vpn ?" : win.root.vpnOn ? "◆ " + win.root.vpnWhere.toLowerCase() : "◇ vpn off"
                color: win.root.vpnOn ? "#e1f5ee" : "#fcebeb"
                font.pixelSize: 11; font.family: "monospace"
            }
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: m => {
                    if (m.button === Qt.RightButton) win.menuAt(vpnPill, win.root.vpnOn ? "connected · " + win.root.vpnWhere.toLowerCase() : "nordvpn", win.vpnMenu())
                    else win.root.toggleVpn()
                }
            }
        }
    }
}
