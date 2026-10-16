// goonotes — dot-matrix sticky notes that sit on the KDE desktop, in wavegoo colors.
// Run with:  qs -c goonotes -d
// IPC:       qs -c goonotes ipc call notes add | drawer | board | toggle | pinAll | unpinAll | quit | list
// Files: Note.qml (one note on the desktop), Drawer.qml (browse / search / sort every note),
//        CategoryMenu.qml (category picker), NoteButton.qml (header icon button),
//        Cabinet.qml (file cabinet), Corkboard.qml (notes kept in sight).
// Notes are saved in ~/.local/state/quickshell/by-shell/<id>/notes.json
// Phone sync (goonotes-sync, ~/Projects/goonotes-android/sync): it reads notes.json and writes
// inbox.json next to it; we watch that and merge it in. Deleted notes leave a tombstone so the
// deletion reaches the phone; colour/category/stash/text/title changes bump `updated`, moving and
// resizing don't (those stay desktop-only and never leave this machine). Pasted images live in
// images/ next to notes.json and are desktop-only too (a note's `images` list never syncs).
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: notesApp

    // ---- tweak me -------------------------------------------------------
    // a = header, b = the goo along the bottom: wavegoo's hues, muted so they sit quietly on the desktop
    readonly property var palette: [
        { name: "dusk",  a: "#8a84b8", b: "#6f9a8a" },
        { name: "rose",  a: "#b38a96", b: "#7aa0a6" },
        { name: "ochre", a: "#c4a06c", b: "#b08474" },
        { name: "moss",  a: "#98a67a", b: "#86a99a" },
        { name: "mist",  a: "#a3aec0", b: "#7d91a6" }
    ]
    readonly property color backing: "#f2090a0d"  // dark fill behind the dots
    readonly property color dotColor: "#ff2c3039" // resting dots
    readonly property color ink: "#ffdfe4ec"      // note text
    readonly property color dim: "#80dfe4ec"      // labels, counters
    readonly property color rim: "#33ffffff"      // thin outline
    readonly property color danger: "#ffe24b4a"
    readonly property string mono: "MesloLGS Nerd Font Mono"
    readonly property var starterCategories: ["todo", "ideas", "s&box"]
    // Amiga AGA-style palette: the cabinet and the notes are dithered into these (max 32)
    readonly property var aga: [
        // steel / greys, dark to light
        "#141418", "#2a2c31", "#42454b", "#5b5f65", "#757980", "#8f949a", "#aaaeb3", "#c5c8cc", "#dfe1e3", "#f4f5f6",
        // orange (accents)
        "#7a3a00", "#c25e00", "#ff8800", "#ffb85c",
        // paper
        "#efeee6", "#d6d4c8",
        // the note colours (palette above, a and b)
        "#8a84b8", "#6f9a8a", "#b38a96", "#7aa0a6", "#c4a06c", "#b08474", "#98a67a", "#86a99a", "#a3aec0", "#7d91a6"
    ]
    // ---------------------------------------------------------------------

    FontLoader { id: blockFont; source: "fonts/WavegooRoundsquare.ttf" }
    readonly property string block: blockFont.name

    // id -> { id, x, y, w, h, color, title, text, pinned, created, updated, screen, category, stashed, images }
    // plus, for the corkboard (desktop-only, never synced): board, bx, by (where its card sits), boardAt
    property var store: ({})
    // what a note is called (drawer tabs, the note's header): its title, or else its first line
    function titleOf(n) {
        if (!n) return "untitled"
        return (n.title || "").trim() || ((n.text || "").split("\n").find(l => l.trim()) || "").trim() || "untitled"
    }
    property var ids: []
    property var categories: []
    property real catsUpdated: 0    // when the category list last changed (sync: newest list wins)
    property var tombstones: ({})   // id -> when it was deleted, so the phone hears about it
    property var extra: ({})        // top-level keys in notes.json we don't know, kept as they are
    property bool ready: false
    property string typing: ""      // the note being typed in: sync leaves it alone until you stop
    signal remoteEdit(string id)    // a note's text/colour came in from the phone
    property var desktopIds: []   // notes that are out on the desktop (not stashed)
    property int rev: 0           // bumps when stored data changes, so the drawer and labels refresh
    property bool shown: true
    property bool drawerOpen: false
    property string pendingFlash: ""
    property bool peek: false      // every note lifted above windows (bar button right-click)
    // the file cabinet (Cabinet.qml): where it sits, and the note being dragged toward it
    property var cabinet: ({})
    property string dragNote: ""
    property bool cabinetPeek: false   // lift the cabinet above windows (preview from IPC)
    property real dragX: 0          // pointer, in screen coords, while a note is dragged
    property real dragY: 0
    signal noteDropped(string id, real sx, real sy)
    function setCabinet(x, y) { cabinet = { x: x, y: y }; save() }
    // the corkboard (Corkboard.qml): where it sits, how big it is, and whether it's closed
    property var board: ({})
    function setBoard(patch) { board = Object.assign({}, board, patch); save() }
    // open the notes drawer showing one category
    signal browseRequested(string cat)
    function browse(cat) { drawerOpen = true; browseRequested(cat) }
    property bool quitting: false

    // Quickshell crashes (and its crash handler restarts it) if it exits with note windows still up,
    // so close every window first, the same way stashing does, then exit
    function quit() {
        file.setText(serialise())
        quitting = true
        quitTimer.start()
    }
    Timer { id: quitTimer; interval: 300; onTriggered: Qt.quit() }

    FileView {
        id: file
        path: Quickshell.statePath("notes.json")
        printErrors: false
        blockLoading: true
        onLoaded: notesApp.load(text())
        onLoadFailed: notesApp.load("")
    }

    function load(raw) {
        let list = [], cats = null
        try {
            const o = JSON.parse(raw)
            if (Array.isArray(o.notes)) list = o.notes
            if (Array.isArray(o.categories)) cats = o.categories
            if (o.cabinet && typeof o.cabinet === "object") cabinet = o.cabinet
            if (o.board && typeof o.board === "object") board = o.board
            if (o.tombstones && typeof o.tombstones === "object") tombstones = o.tombstones
            catsUpdated = o.catsUpdated || 0
            const known = ["categories", "catsUpdated", "cabinet", "board", "tombstones", "notes"], x = {}
            for (const k in o) if (known.indexOf(k) < 0) x[k] = o[k]
            extra = x
        } catch (e) {}
        const s = {}
        for (const n of list) if (n && n.id) s[n.id] = n
        store = s
        ids = list.filter(n => n && n.id).map(n => n.id)
        categories = cats || starterCategories.slice()
        refreshDesktop()
        ready = true
        inbox.reload()
        if (!ids.length) newNote("goonotes\n\n" +
            "drag the top strip to move\n" +
            "corner grip to resize\n" +
            "click the line under the header to give it a title\n" +
            "ctrl+v an image to stick it in, drag its corner to size it\n\n" +
            "click the label up top to file it in a category\n" +
            "box = stash it (kept in the drawer, off the desktop)\n" +
            "list = open the drawer: search, filter, sort\n" +
            "brush = color, pin = keep above windows\n" +
            "trash twice = delete\n\n" +
            "ctrl+n new, esc to stop typing")
    }

    function refreshDesktop() {
        const d = ids.filter(i => store[i] && !store[i].stashed)
        if (d.join() !== desktopIds.join()) desktopIds = d
    }

    function newNote(text, category) {
        const id = Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36)
        const k = desktopIds.length % 8
        const s = Object.assign({}, store)
        const now = Date.now()
        s[id] = { id: id, x: 120 + k * 36, y: 120 + k * 36, w: 300, h: 280,
                  color: ids.length % palette.length, title: "", text: text || "", pinned: false,
                  created: now, updated: now, screen: "", category: category || "", stashed: false }
        store = s
        ids = ids.concat([id])
        refreshDesktop()
        changed()
        return id
    }

    // notes keep their own live state; this only records it, so no note gets rebuilt
    function update(id, patch) {
        if (!store[id]) return
        if ("text" in patch || "color" in patch || "title" in patch) patch.updated = Date.now()
        Object.assign(store[id], patch)
        save()
    }

    function remove(id) {
        dropImages(store[id])
        tombstones[id] = Date.now()
        ids = ids.filter(i => i !== id)
        delete store[id]
        refreshDesktop()
        changed()
    }

    function setCategory(id, cat) {
        if (!store[id]) return
        if (cat && categories.indexOf(cat) < 0) addCategory(cat)
        store[id].category = cat
        store[id].updated = Date.now()
        changed()
    }
    function addCategory(name) {
        name = (name || "").trim().toLowerCase()
        if (!name || categories.indexOf(name) >= 0) return
        categories = categories.concat([name])
        catsUpdated = Date.now()
        changed()
    }
    // rename a category everywhere; renaming onto an existing one merges the two
    function renameCategory(from, to) {
        to = (to || "").trim().toLowerCase()
        if (!to || to === from) return
        const i = categories.indexOf(from)
        if (i < 0) { addCategory(to); return }
        const cats = categories.slice()
        if (cats.indexOf(to) >= 0) cats.splice(i, 1)
        else cats[i] = to
        categories = cats
        catsUpdated = Date.now()
        for (const id of ids) if (store[id].category === from) { store[id].category = to; store[id].updated = catsUpdated }
        changed()
    }
    // notes in a removed category become unsorted; nothing is deleted
    function removeCategory(name) {
        categories = categories.filter(c => c !== name)
        catsUpdated = Date.now()
        for (const i of ids) if (store[i].category === name) { store[i].category = ""; store[i].updated = catsUpdated }
        changed()
    }

    // a note was put away from its own close button: the cabinet bumps the drawer it went into
    signal putAway(string id)
    signal peekMenu(string id, string kind)
    function putAwayNote(id) { if (!store[id]) return; stash(id, true); putAway(id) }

    function stash(id, on) {
        if (!store[id]) return
        store[id].stashed = on
        store[id].updated = Date.now()
        refreshDesktop()
        changed()
    }

    // bring a note forward: unstash it, close the drawer, lift it above windows for a moment
    signal flash(string id)
    function reveal(id) {
        if (!store[id]) return
        drawerOpen = false
        shown = true
        if (store[id].stashed) { pendingFlash = id; stash(id, false) }
        else flash(id)
    }

    // ---- the corkboard ---------------------------------------------------------------------
    // A note on the board keeps its drawer: the board only shows it, until you take it down.
    // Pinning a loose note puts it away (it becomes a card); clicking the card takes it back out.
    function pinToBoard(id, bx, by) {
        const n = store[id]
        if (!n) return
        n.board = true; n.boardAt = Date.now()
        if (bx !== undefined) { n.bx = Math.round(bx); n.by = Math.round(by) } else { delete n.bx; delete n.by }
        if (!n.stashed) { n.stashed = true; n.updated = Date.now(); refreshDesktop() }
        if (board.hidden) setBoard({ hidden: false })
        changed()
    }
    function unpinFromBoard(id) { const n = store[id]; if (n) { n.board = false; changed() } }
    function setCardPos(id, bx, by) { const n = store[id]; if (n) { n.bx = Math.round(bx); n.by = Math.round(by); changed() } }
    // take a card's note out onto the desktop at (x, y)
    function openFromBoard(id, x, y) {
        const n = store[id]
        if (!n) return
        if (n.stashed) { n.x = Math.round(x); n.y = Math.round(y) }
        reveal(id)
    }

    function changed() { rev++; save() }
    function save() { saveTimer.restart() }
    Timer {
        id: saveTimer
        interval: 400
        onTriggered: {
            file.setText(notesApp.serialise())
            notesApp.rev++   // refresh drawer previews after typing settles
        }
    }

    function serialise() {
        // tombstones older than half a year have reached everything by now
        const cut = Date.now() - 180 * 86400000, t = {}
        for (const k in tombstones) if (tombstones[k] > cut) t[k] = tombstones[k]
        tombstones = t
        return JSON.stringify(Object.assign({}, extra, { categories: categories, catsUpdated: catsUpdated,
            cabinet: cabinet, board: board, tombstones: tombstones, notes: ids.map(i => store[i]) }), null, 1)
    }

    // ---- phone sync: merge what goonotes-sync left in inbox.json -------------------------
    // Only the synced fields (text, color, category, stashed, created, updated) come in; a note's
    // place and size on the desktop are never touched. A note with edits the sync hasn't picked
    // up yet (updated > pcSeen), or that you're typing in, is skipped; the sync sorts it out next.
    FileView {
        id: inbox
        path: Quickshell.statePath("inbox.json")
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: notesApp.mergeInbox(text())
    }
    onTypingChanged: if (!typing) inbox.reload()

    function mergeInbox(raw) {
        if (!ready || quitting) return
        let o
        try { o = JSON.parse(raw) } catch (e) { return }
        if (!o || !Array.isArray(o.notes)) return
        let touched = false, shape = false
        const s = store
        for (const id in (o.tombstones || {})) {
            const ts = o.tombstones[id]
            if (s[id] && (s[id].updated || 0) <= ts && id !== typing) { dropImages(s[id]); delete s[id]; shape = true }
            if (!s[id] && (tombstones[id] || 0) < ts) { tombstones[id] = ts; touched = true }
        }
        let fresh = []
        for (const r of o.notes) {
            if (!r || !r.id) continue
            const n = s[r.id]
            const synced = { text: r.text || "", color: r.color || 0, category: r.category || "",
                             stashed: !!r.stashed, created: r.created, updated: r.updated }
            // an older sync server doesn't know titles: leave ours alone unless it sends one
            if (typeof r.title === "string") synced.title = r.title
            if (!n) {
                if ((tombstones[r.id] || 0) >= r.updated) continue
                delete tombstones[r.id]
                const k = (desktopIds.length + fresh.length) % 8
                s[r.id] = Object.assign({ id: r.id, x: 120 + k * 36, y: 120 + k * 36, w: 300, h: 280,
                                          pinned: false, screen: "" }, synced, { synced: r.updated })
                fresh.push(r.id)
                continue
            }
            if (r.id === typing || (n.updated || 0) > (r.pcSeen || 0)) continue
            const diff = n.text !== synced.text || n.color !== synced.color || (n.category || "") !== synced.category
                         || ("title" in synced && (n.title || "") !== synced.title)
                         || !!n.stashed !== synced.stashed || n.updated !== synced.updated
            if (diff) {
                if (!!n.stashed !== synced.stashed) shape = true
                Object.assign(n, synced)
                remoteEdit(r.id)
            }
            if (diff || n.synced !== r.updated) { n.synced = r.updated; touched = true }
        }
        const c = o.categories
        if (c && Array.isArray(c.list) && (c.updated || 0) > catsUpdated) {
            categories = c.list.slice(); catsUpdated = c.updated; touched = true
        }
        if (shape || fresh.length) {
            store = s
            ids = ids.filter(i => s[i]).concat(fresh)
            refreshDesktop()
        }
        if (shape || fresh.length || touched) changed()
    }

    function ago(ms) {
        const s = Math.max(0, (Date.now() - (ms || 0)) / 1000)
        if (s < 60) return "just now"
        if (s < 3600) return Math.floor(s / 60) + "m ago"
        if (s < 86400) return Math.floor(s / 3600) + "h ago"
        if (s < 86400 * 7) return Math.floor(s / 86400) + "d ago"
        return Qt.formatDate(new Date(ms), "dd MMM yy")
    }

    function screenFor(name) {
        const ss = Quickshell.screens
        for (let i = 0; i < ss.length; i++) if (ss[i].name === name) return ss[i]
        return ss.length ? ss[0] : null
    }

    signal pinEverything(bool on)

    // ---- pasted images --------------------------------------------------------------------
    // Pasting takes the clipboard straight from wl-paste (wl-clipboard). Only these formats are
    // accepted, the file's first bytes must match the type, and it's capped in size; the name is
    // ours (note id + time), never anything from the clipboard.
    readonly property string imageDir: Quickshell.statePath("images")
    readonly property var imageTypes: ({ "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif", "image/bmp": "bmp" })
    readonly property int imageMaxBytes: 25 * 1024 * 1024
    property bool hasWlPaste: false
    Process {
        running: true
        command: ["sh", "-c", "command -v wl-paste"]
        onExited: code => notesApp.hasWlPaste = code === 0
    }
    function imageUrl(file) { return "file://" + imageDir + "/" + file }
    function safeImageName(f) { return typeof f === "string" && /^[a-z0-9]+-[a-z0-9]+\.(png|jpg|webp|gif|bmp)$/.test(f) }
    function deleteImageFile(f) { if (safeImageName(f)) Quickshell.execDetached(["rm", "-f", "--", imageDir + "/" + f]) }
    function dropImages(n) { for (const im of (n && n.images) || []) deleteImageFile(im.file) }

    IpcHandler {
        target: "notes"
        // new note from the bar: lift it above your windows so you can see it and type
        function add(): void { notesApp.shown = true; const id = notesApp.newNote(""); notesApp.pendingFlash = id; notesApp.flash(id) }
        function peek(): void { notesApp.shown = true; notesApp.peek = !notesApp.peek }
        // delete notes that have no text
        function clean(): int { const e = notesApp.ids.filter(i => !(notesApp.store[i].text || "").trim()); e.forEach(i => notesApp.remove(i)); return e.length }
        function drawer(): void { notesApp.drawerOpen = !notesApp.drawerOpen }
        function toggle(): void { notesApp.shown = !notesApp.shown }
        function show(): void { notesApp.shown = true }
        function hide(): void { notesApp.shown = false }
        function pinAll(): void { notesApp.pinEverything(true) }
        function unpinAll(): void { notesApp.pinEverything(false) }
        function quit(): void { notesApp.quit() }
        // scripting: list returns [{id, category, stashed, title}]
        function list(): string { return JSON.stringify(notesApp.ids.map(i => { const n = notesApp.store[i]
            return { id: i, category: n.category || "", stashed: !!n.stashed, title: notesApp.titleOf(n) } })) }
        function stashNote(id: string): void { notesApp.stash(id, true) }
        function reveal(id: string): void { notesApp.reveal(id) }
        // open a note's menu for screenshots: kind = "text", "note" or "colour"
        function peekMenu(id: string, kind: string): void { notesApp.peekMenu(id, kind) }
        // preview the file cabinet as if a note were being dragged to (x, y) on screen; "" x to stop
        // scripting: file a note into a category and put it away
        function remove(id: string): void { notesApp.remove(id) }
        function renameCategory(from: string, to: string): void { notesApp.renameCategory(from, to) }
        // scripting: make a note with this text (category optional); returns its id
        function write(text: string, category: string): string { notesApp.shown = true; const id = notesApp.newNote(text, category); notesApp.pendingFlash = id; return id }
        function fileNote(id: string, category: string): void { notesApp.setCategory(id, category); notesApp.stash(id, true) }
        function peekCabinet(on: bool): void { notesApp.cabinetPeek = on }
        // bar button: bring the cabinet up over your windows, or send it back to the desktop
        function cabinet(): void { notesApp.shown = true; notesApp.cabinetPeek = !notesApp.cabinetPeek }
        // corkboard: open / close it, pin a note to it, take one down
        function board(): void { notesApp.shown = true; notesApp.setBoard({ hidden: !notesApp.board.hidden }) }
        function boardPin(id: string): void { notesApp.pinToBoard(id) }
        function boardUnpin(id: string): void { notesApp.unpinFromBoard(id) }
        function peekDrag(x: real, y: real): void { notesApp.dragX = x; notesApp.dragY = y; notesApp.dragNote = x < 0 ? "" : "peek" }
    }

    Variants {
        model: notesApp.quitting ? [] : notesApp.desktopIds
        Note { app: notesApp }
    }

    LazyLoader {
        active: !notesApp.quitting
        Drawer { app: notesApp }
    }

    LazyLoader {
        active: !notesApp.quitting
        Cabinet { app: notesApp }
    }

    LazyLoader {
        active: !notesApp.quitting
        Corkboard { app: notesApp }
    }
}
