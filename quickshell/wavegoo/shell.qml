//@ pragma UseQApplication
// wavegoo — a dot-matrix taskbar for KDE Plasma.
// Run with:  qs -c wavegoo
// Files: Bar.qml (the bar), Launcher.qml (start menu), windows.py (open-window bridge to KWin),
//        ContextMenu.qml (right-click menus), Calendar.qml (clock popup), StatusIcon.qml (volume/net/bt/bell)
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris

ShellRoot {
    id: shell

    // ---- tweak me -------------------------------------------------------
    readonly property var defaultPins: [
        "steam", "brave-browser", "org.kde.konsole", "org.kde.dolphin",
        "org.qbittorrent.qBittorrent", "nordvpn-gui", "systemsettings"
    ]
    // colors are #AARRGGBB
    readonly property color gooA: "#f07f77dd"     // liquid, left side
    readonly property color gooB: "#f01d9e75"     // liquid, right side
    readonly property color grainM: "#ffff4fd8"   // sand: magenta
    readonly property color grainC: "#ff35e6ff"   // sand: cyan
    readonly property color grainY: "#ffffe04a"   // sand: yellow
    readonly property color backing: "#e6090a0d"  // dark fill behind the dots
    readonly property color dotColor: "#ff4a505c" // resting dots
    readonly property color litColor: "#ffdfe4ec" // dots lit by the cursor / shockwaves
    readonly property color rim: "#33ffffff"      // thin outlines (start menu edge)
    // ---------------------------------------------------------------------

    property bool launcherOpen: false
    // the bar's wave clock, so the start menu's grains move in lockstep with the bar's
    property real waveTime: 0

    // ---- pinned apps: defaultPins until you pin/unpin from a right-click menu,
    // then whatever's saved in ~/.local/state/quickshell/by-shell/<id>/pins.json
    property var pinned: defaultPins
    FileView {
        id: pinFile
        path: Quickshell.statePath("pins.json")
        printErrors: false
        onLoaded: {
            try { const p = JSON.parse(text()); if (Array.isArray(p)) shell.pinned = p } catch (e) {}
        }
    }
    function setPins(p) { pinned = p; pinFile.setText(JSON.stringify(p)) }
    function pinIndex(entry) {
        if (!entry) return -1
        for (let i = 0; i < pinned.length; i++) {
            const e = DesktopEntries.heuristicLookup(pinned[i])
            if (pinned[i] === entry.id || (e && e.id === entry.id)) return i
        }
        return -1
    }
    function pin(entry) { if (entry && pinIndex(entry) < 0) setPins(pinned.concat([entry.id])) }
    function unpin(entry) { const i = pinIndex(entry); if (i >= 0) setPins(pinned.filter((_, k) => k !== i)) }
    function movePin(i, d) {
        const j = i + d
        if (j < 0 || j >= pinned.length) return
        const p = pinned.slice(); const t = p[i]; p[i] = p[j]; p[j] = t
        setPins(p)
    }

    function run(cmd) { Quickshell.execDetached(cmd) }
    readonly property var powerActions: launcher.powerActions

    // true while the menu is open for a look only: it doesn't take the keyboard
    property bool launcherPeek: false
    onLauncherOpenChanged: if (!launcherOpen) launcherPeek = false

    IpcHandler {
        target: "launcher"
        function toggle(): void { shell.launcherOpen = !shell.launcherOpen }
        function open(): void { shell.launcherOpen = true }
        function close(): void { shell.launcherOpen = false }
        // previews for testing the menu without stealing keystrokes
        function peek(): void { shell.launcherPeek = true; shell.launcherOpen = true }
        function peekSearch(q: string): void { launcher.query = q; launcher.selectFirst() }
        function peekCategory(i: int): void { launcher.setCategory(i) }
        function peekTurn(d: int): void { launcher.turn(d) }
        function peekReveal(v: real): void { launcher.freezeReveal(v) }   // hold the open animation at v (0..1)
        function peekSelect(ring: int, i: int): void { launcher.selectAt(ring, i) }
        function peekState(): string { return JSON.stringify({ ring: launcher.selRing, i: launcher.selIndex, item: launcher.selItem ? launcher.selItem.name : null, cat: launcher.cat, cats: launcher.cats.map(c => c.name + ':' + c.apps.length) }) }
    }

    // reorder tabs from scripts:  qs -c wavegoo ipc call tasks move <from> <to> / auto <true|false>
    IpcHandler {
        target: "tasks"
        function move(from: int, to: int): void { shell.moveTask(from, to); shell.saveOrder() }
        function auto(on: bool): void { shell.setAutoOrder(on) }
    }

    // ---- music ----------------------------------------------------------
    readonly property var player: {
        const ps = Mpris.players.values
        for (let i = 0; i < ps.length; i++) if (ps[i].isPlaying) return ps[i]
        return ps.length ? ps[0] : null
    }
    readonly property bool playing: player !== null && player.isPlaying

    // ---- open windows (via windows.py) ------------------------------------
    property ListModel tasks: ListModel {}
    property bool tasksReady: false
    // the screen (output name) whose active window is fullscreen, so that bar can stop animating
    property string fullscreenOutput: ""

    // nobody's touched anything for a minute: the bars hold still until the next input
    // (video players' idle inhibitors are ignored on purpose; this only pauses the wave)
    IdleMonitor { id: idleMon; timeout: 60; respectInhibitors: false }
    readonly property bool idle: idleMon.isIdle

    Process {
        id: winProc
        running: true
        stdinEnabled: true
        command: ["python3", "-I", Quickshell.shellPath("windows.py")]
        stdout: SplitParser {
            onRead: line => {
                if (line === "MENU") shell.launcherOpen = !shell.launcherOpen   // Super key
                else if (line.startsWith("TASK ")) {                             // Meta+1..9
                    const i = parseInt(line.slice(5)) - 1
                    if (i >= 0 && i < shell.tasks.count) shell.winCmd("toggle", shell.tasks.get(i).wid)
                }
                else shell.syncTasks(JSON.parse(line))
            }
        }
        onExited: restartWin.start()
    }
    Timer { id: restartWin; interval: 2000; onTriggered: winProc.running = true }

    function winCmd(cmd, id) { winProc.write(cmd + " " + id + "\n") }

    function syncTasks(list) {
        const ids = list.map(w => w.id)
        const fs = list.find(w => w.active && w.fullScreen && !w.minimized)
        fullscreenOutput = fs && fs.output ? fs.output : ""
        for (let i = tasks.count - 1; i >= 0; i--)
            if (ids.indexOf(tasks.get(i).wid) < 0) tasks.remove(i)
        for (const w of list) {
            let found = -1
            for (let i = 0; i < tasks.count; i++) if (tasks.get(i).wid === w.id) { found = i; break }
            const row = { wid: w.id, title: w.title, app: w.app, desktop: w.desktop, active: w.active, minimized: w.minimized,
                          keepAbove: !!w.keepAbove, fullScreen: !!w.fullScreen, allDesktops: !!w.allDesktops,
                          attention: !!w.attention }
            if (found < 0) insertTask(row)
            else for (const k in row) if (tasks.get(found)[k] !== row[k]) tasks.setProperty(found, k, row[k])
        }
        tasksReady = true
    }

    // ---- app usage: drives taskbar icon size, height and order ---------------------
    // Seconds of focus per app, fading with a ~30 min time constant, so it follows what
    // you're doing now. Saved in ~/.local/state/quickshell/by-shell/<id>/usage.json.
    property var usage: ({})
    property real usageMax: 1
    property bool tasksHovered: false      // set by the bar; the order holds still while true
    property int usageTicks: 0
    FileView {
        id: usageFile
        path: Quickshell.statePath("usage.json")
        printErrors: false
        onLoaded: {
            try { const u = JSON.parse(text()); if (u && typeof u === "object") shell.usage = u } catch (e) {}
        }
    }
    function taskKey(t) { return t.desktop || t.app }
    Timer { interval: 1000; running: true; repeat: true; onTriggered: shell.tickUsage() }
    function tickUsage() {
        const k = Math.exp(-1 / 1800)
        const u = {}
        for (const key in usage) { const v = usage[key] * k; if (v > 0.5) u[key] = v }
        for (let i = 0; i < tasks.count; i++) {
            const t = tasks.get(i)
            if (t.active && !t.minimized) { const key = taskKey(t); u[key] = (u[key] || 0) + 1; break }
        }
        usage = u
        let m = 1
        for (let i = 0; i < tasks.count; i++) m = Math.max(m, u[taskKey(tasks.get(i))] || 0)
        usageMax = m
        usageTicks++
        if (usageTicks % 60 === 0) usageFile.setText(JSON.stringify(u))
        if (usageTicks % 6 === 0) settleStep()
    }
    // 0..1: how much this app is used compared with the busiest open one
    function weight(desktop, app) { return Math.sqrt(Math.min(1, (usage[desktop || app] || 0) / usageMax)) }
    // ---- tab order: drift by use (auto), or the order you dragged them into --------------------
    // Saved in ~/.local/state/quickshell/by-shell/<id>/order.json as { auto, order: [app keys] }.
    property bool autoOrder: false      // off by default: tabs stay where they open (or where you drag them)
    property var taskOrder: []
    FileView {
        id: orderFile
        path: Quickshell.statePath("order.json")
        printErrors: false
        onLoaded: {
            try {
                const o = JSON.parse(text())
                shell.autoOrder = o.auto !== false
                if (Array.isArray(o.order)) shell.taskOrder = o.order
            } catch (e) {}
        }
    }
    function saveOrder() { orderFile.setText(JSON.stringify({ auto: autoOrder, order: taskOrder })) }
    function setAutoOrder(on) { autoOrder = on; saveOrder() }
    // dragging a tab: move it, switch auto-drift off, and remember the order per app
    function moveTask(from, to) {
        if (from === to) return
        tasks.move(from, to, 1)
        autoOrder = false
        const keys = []
        for (let i = 0; i < tasks.count; i++) { const k = taskKey(tasks.get(i)); if (keys.indexOf(k) < 0) keys.push(k) }
        taskOrder = keys.concat(taskOrder.filter(k => keys.indexOf(k) < 0))   // closed apps keep their place after
    }
    // a new window goes where its app sits in your order (after its siblings), else at the end
    function insertTask(row) {
        const r = taskOrder.indexOf(taskKey(row))
        if (autoOrder || r < 0) { tasks.append(row); return }
        for (let i = 0; i < tasks.count; i++) {
            const ri = taskOrder.indexOf(taskKey(tasks.get(i)))
            if (ri < 0 || ri > r) { tasks.insert(i, row); return }
        }
        tasks.append(row)
    }

    // gravity: one neighbour swap at a time, busier apps drift toward the orb
    function settleStep() {
        if (tasksHovered || !autoOrder) return
        for (let i = 0; i < tasks.count - 1; i++) {
            const a = usage[taskKey(tasks.get(i))] || 0, b = usage[taskKey(tasks.get(i + 1))] || 0
            if (b > a * 1.25 + 10) { tasks.move(i + 1, i, 1); return }
        }
    }

    function entryFor(desktop, app) {
        return DesktopEntries.heuristicLookup(desktop || app) || DesktopEntries.heuristicLookup(app)
    }

    // ---- NordVPN --------------------------------------------------------
    property bool vpnOn: false
    property string vpnWhere: ""
    property bool vpnKnown: false
    Process {
        id: vpnPoll
        command: ["nordvpn", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                shell.vpnKnown = text.indexOf("Status:") >= 0
                shell.vpnOn = /Status:\s*Connected/.test(text)
                const m = text.match(/Country:\s*(.+)/)
                shell.vpnWhere = shell.vpnOn && m ? m[1].trim() : ""
            }
        }
    }
    // a connect/disconnect also shows up in nmcli monitor (the tunnel comes and goes), so this is a fallback
    Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: vpnPoll.running = true }
    Process { id: vpnToggle; onExited: vpnPoll.running = true }
    function vpnPollNow() { vpnPoll.running = true }
    function toggleVpn() {
        vpnToggle.command = vpnOn ? ["nordvpn", "disconnect"] : ["nordvpn", "connect"]
        vpnToggle.running = true
    }

    // ---- notifications (swaync) ------------------------------------------------
    property int notifCount: 0
    property bool notifDnd: false
    property bool notifKnown: false
    Process {
        id: notifSub
        running: true
        command: ["swaync-client", "-s"]
        stdout: SplitParser {
            onRead: line => {
                try { const j = JSON.parse(line); shell.notifCount = j.count; shell.notifDnd = j.dnd; shell.notifKnown = true } catch (e) {}
            }
        }
        onExited: { shell.notifKnown = false; notifRetry.start() }
    }
    Timer { id: notifRetry; interval: 3000; onTriggered: notifSub.running = true }

    // ---- network (NetworkManager via nmcli) --------------------------------------
    property string netType: ""        // "wifi", "ethernet" or "" when offline
    property string netName: ""
    property int netSignal: 0
    property bool wifiOn: true
    property bool netKnown: false
    // nmcli -t escapes ':' inside fields as '\:'
    function nmFields(line) { return line.replace(/\\:/g, "\u0001").split(":").map(f => f.replace(/\u0001/g, ":")) }
    Process {
        id: netPoll
        command: ["sh", "-c", "nmcli -t -f TYPE,STATE,CONNECTION device; echo --; nmcli -t -f IN-USE,SIGNAL dev wifi list --rescan no; echo --; nmcli radio wifi"]
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.split("--\n")
                let type = "", name = ""
                for (const l of (parts[0] || "").split("\n")) {
                    const f = shell.nmFields(l)
                    if (f[1] !== "connected" || (f[0] !== "wifi" && f[0] !== "ethernet")) continue
                    if (!type || f[0] === "ethernet") { type = f[0]; name = f[2] }
                }
                let sig = 0
                for (const l of (parts[1] || "").split("\n")) if (l.startsWith("*:")) sig = parseInt(l.slice(2)) || 0
                shell.netType = type; shell.netName = name; shell.netSignal = sig
                shell.wifiOn = (parts[2] || "").trim() !== "disabled"
                shell.netKnown = true
            }
        }
    }
    function netRefresh() { if (!netPoll.running) netPoll.running = true; else netAgain.start() }
    Timer { id: netAgain; interval: 600; onTriggered: shell.netRefresh() }
    // nmcli monitor below catches every state change; this only keeps the wifi signal bars fresh
    Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: shell.netRefresh() }
    // refresh right away whenever NetworkManager reports a change
    Process {
        id: netMon
        running: true
        command: ["nmcli", "monitor"]
        stdout: SplitParser { onRead: _ => netDebounce.restart() }
        onExited: netMonRetry.start()
    }
    Timer { id: netDebounce; interval: 400; onTriggered: { shell.netRefresh(); if (!vpnPoll.running) vpnPoll.running = true } }
    Timer { id: netMonRetry; interval: 5000; onTriggered: netMon.running = true }

    // KWin's own global shortcuts, e.g. "Show Desktop"
    function kwinShortcut(name) { run(["qdbus6", "org.kde.kglobalaccel", "/component/kwin", "org.kde.kglobalaccel.Component.invokeShortcut", name]) }

    SystemClock { id: clock; precision: SystemClock.Minutes }
    readonly property date now: clock.date

    Variants {
        model: Quickshell.screens
        Bar { required property var modelData; screen: modelData; root: shell }
    }
    Launcher { id: launcher; root: shell }
}
