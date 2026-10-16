#!/usr/bin/env python3
"""Open-window bridge between KWin and the wavegoo bar.

KWin doesn't expose a window list to normal Wayland clients, so this loads a
small KWin script that pushes the list to us over D-Bus whenever it changes.
We print it as one JSON line per update on stdout. The same script owns Meta+1..9
(prints TASK <n>; the bar activates its Nth window) and the bare Super key, which calls
toggleMenu() and prints MENU.

Commands come in on stdin, one per line:
    activate|toggle|minimize|close|maximize|keepabove|fullscreen|alldesktops <id>
Each one runs as a throwaway KWin script.
"""
import json
import os
import sys
import tempfile

from gi.repository import Gio, GLib

BUS_NAME = "org.wavegoo.Windows"
PLUGIN = "wavegoo-windows"

IFACE_XML = """
<node><interface name="org.wavegoo.Windows">
  <method name="update"><arg type="s" name="json" direction="in"/></method>
  <method name="toggleMenu"/>
  <method name="task"><arg type="s" name="n" direction="in"/></method>
</interface></node>
"""

WATCH_JS = r"""
function push() {
    const out = [];
    const act = workspace.activeWindow;
    for (const w of workspace.windowList()) {
        if (!w.normalWindow || w.skipTaskbar) continue;
        out.push({
            id: w.internalId.toString(),
            title: w.caption,
            app: w.resourceClass,
            desktop: w.desktopFileName,
            active: w === act,
            minimized: w.minimized,
            keepAbove: w.keepAbove,
            fullScreen: w.fullScreen,
            allDesktops: w.onAllDesktops,
            attention: w.demandsAttention,
            output: w.output ? w.output.name : "",
        });
    }
    callDBus("org.wavegoo.Windows", "/Windows", "org.wavegoo.Windows", "update", JSON.stringify(out));
}
function hook(w) {
    w.captionChanged.connect(push);
    w.minimizedChanged.connect(push);
    w.keepAboveChanged.connect(push);
    w.fullScreenChanged.connect(push);
    w.desktopsChanged.connect(push);
    w.demandsAttentionChanged.connect(push);
    w.outputChanged.connect(push);
}
workspace.windowList().forEach(hook);
// Meta+1..9: the bar knows its own order, so just tell it which number was pressed
for (let n = 1; n <= 9; n++)
    registerShortcut("wavegoo-task-" + n, "wavegoo: activate window " + n, "Meta+" + n,
                     () => callDBus("org.wavegoo.Windows", "/Windows", "org.wavegoo.Windows", "task", String(n)));
// Super on its own opens the start menu. Plasma 6 treats a bare Meta press as a normal global
// shortcut (kwinrc's ModifierOnlyShortcuts no longer does it), so register it like Meta+N.
registerShortcut("wavegoo-menu", "wavegoo: open start menu", "Meta",
                 () => callDBus("org.wavegoo.Windows", "/Windows", "org.wavegoo.Windows", "toggleMenu"));
workspace.windowAdded.connect(w => { hook(w); push(); });
workspace.windowRemoved.connect(push);
workspace.windowActivated.connect(push);
push();
"""

ACTION_JS = {
    "activate": "w.minimized = false; workspace.activeWindow = w;",
    "toggle": "if (workspace.activeWindow === w && !w.minimized) { w.minimized = true; }"
              " else { w.minimized = false; workspace.activeWindow = w; }",
    "minimize": "w.minimized = true;",
    "close": "w.closeWindow();",
    # maximized = the frame already covers the area a maximize would fill
    "maximize": "const a = workspace.clientArea(KWin.MaximizeArea, w), f = w.frameGeometry;"
                " const m = f.width >= a.width && f.height >= a.height;"
                " w.minimized = false; w.setMaximize(!m, !m); workspace.activeWindow = w;",
    "keepabove": "w.keepAbove = !w.keepAbove;",
    "fullscreen": "w.minimized = false; w.fullScreen = !w.fullScreen; workspace.activeWindow = w;",
    "alldesktops": "w.onAllDesktops = !w.onAllDesktops;",
}

tmpdir = tempfile.mkdtemp(prefix="wavegoo-")
bus = Gio.bus_get_sync(Gio.BusType.SESSION)


def kwin(method, sig, *args):
    return bus.call_sync("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", method,
                         GLib.Variant(sig, args) if sig else None, None,
                         Gio.DBusCallFlags.NONE, -1, None)


def run_script(path, name):
    if kwin("isScriptLoaded", "(s)", name).unpack()[0]:
        kwin("unloadScript", "(s)", name)
    kwin("loadScript", "(ss)", path, name)
    kwin("start", None)


def on_call(_conn, _sender, _path, _iface, method, params, invocation):
    if method == "update":
        sys.stdout.write(params.unpack()[0] + "\n")
        sys.stdout.flush()
    elif method == "toggleMenu":   # the Super key (registered in WATCH_JS)
        sys.stdout.write("MENU\n")
        sys.stdout.flush()
    elif method == "task":         # Meta+N
        sys.stdout.write(f"TASK {params.unpack()[0]}\n")
        sys.stdout.flush()
    invocation.return_value(None)


counter = 0


def on_stdin(channel, _cond):
    global counter
    line = channel.readline()
    if not line:
        loop.quit()
        return False
    parts = line.split()
    if len(parts) == 2 and parts[0] in ACTION_JS:
        counter += 1
        name = f"wavegoo-cmd-{counter}"
        path = os.path.join(tmpdir, name + ".js")
        wid = json.dumps(parts[1])
        with open(path, "w") as f:
            f.write("for (const w of workspace.windowList()) "
                    f"if (w.internalId.toString() === {wid}) {{ {ACTION_JS[parts[0]]} }}\n")
        run_script(path, name)
        # give KWin a moment to run it, then tidy up
        GLib.timeout_add(500, lambda: (kwin("unloadScript", "(s)", name), os.unlink(path), False)[-1])
    return True


node = Gio.DBusNodeInfo.new_for_xml(IFACE_XML)
bus.register_object("/Windows", node.interfaces[0], on_call, None, None)
watch = os.path.join(tmpdir, "watch.js")
with open(watch, "w") as f:
    f.write(WATCH_JS)
# start watching only once we own the name, so the first push isn't lost
Gio.bus_own_name_on_connection(bus, BUS_NAME, Gio.BusNameOwnerFlags.REPLACE,
                               lambda *_: run_script(watch, PLUGIN), None)

GLib.io_add_watch(GLib.IOChannel.unix_new(sys.stdin.fileno()), GLib.IO_IN | GLib.IO_HUP, on_stdin)
loop = GLib.MainLoop()
for sig in (2, 15):  # SIGINT, SIGTERM: quit cleanly so the KWin script gets unloaded
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, lambda: (loop.quit(), False)[-1])
try:
    loop.run()
finally:
    kwin("unloadScript", "(s)", PLUGIN)
