// Note formatting, shared shape with the phone app (Fmt.kt). It lives in the note text itself as
// markdown-ish markers, so it syncs as plain text:
//   **bold**  *italic*  ~~strike~~      # heading      - bullet      - [ ] task / - [x] done
.pragma library

const reTodo = /^(\s*)[-*] \[([ xX])\] ?/
const reBullet = /^(\s*)[-*] /
const reHead = /^#{1,3}\s+/

function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

// desktop note text is already bold, so **bold** reads as a highlighter mark in the note colour
function inline(s, mark) {
    s = esc(s)
    s = s.replace(/\*\*(.+?)\*\*/g, "<span style=\"background-color:" + (mark || "#ffe04a") + "\">$1</span>")
    s = s.replace(/~~(.+?)~~/g, "<s>$1</s>")
    s = s.replace(/(^|[^*\w])\*(?!\s)(.+?)\*(?![*\w])/g, "$1<i>$2</i>")
    return s
}

function hasFormatting(text) {
    return /(^|\n)(\s*[-*] |#{1,3}\s)|\*\*.+?\*\*|~~.+?~~|(^|[^*\w])\*\S.*?\*/.test(text)
}

// The note as rich text: checkboxes are links ("cb:<line>") so a click can tick them.
function toHtml(text, accent, dim, blockFamily, mark) {
    const lines = text.split("\n"), out = []
    for (let i = 0; i < lines.length; i++) {
        const l = lines[i]
        let m
        if ((m = reTodo.exec(l))) {
            const done = m[2] !== " ", body = inline(l.slice(m[0].length), mark)
            out.push("&nbsp;".repeat(m[1].length) + "<a href=\"cb:" + i + "\" style=\"text-decoration:none;color:" +
                     (done ? accent : "#141418") + "\">" + (done ? "☑" : "☐") + "</a> " +
                     (done ? "<s><span style=\"color:" + dim + "\">" + body + "</span></s>" : body))
        } else if ((m = reBullet.exec(l))) {
            out.push("&nbsp;".repeat(m[1].length) + "<span style=\"color:" + accent + "\">•</span> " + inline(l.slice(m[0].length), mark))
        } else if ((m = reHead.exec(l))) {
            out.push("<span style=\"font-family:'" + blockFamily + "';font-size:17px\">" + inline(l.slice(m[0].length), mark) + "</span>")
        } else out.push(inline(l, mark))
    }
    return out.join("<br>")
}

// tick / untick the checkbox on line i
function toggle(text, i) {
    const lines = text.split("\n"), m = reTodo.exec(lines[i] || "")
    if (!m) return text
    const b = lines[i].indexOf("[")
    lines[i] = lines[i].slice(0, b + 1) + (m[2] === " " ? "x" : " ") + lines[i].slice(b + 2)
    return lines.join("\n")
}

// Enter on a list item: the prefix for the next line ("" = not a list), and whether the item was
// empty (then Enter ends the list instead)
function listPrefix(line) {
    let m
    if ((m = reTodo.exec(line))) return { prefix: m[1] + "- [ ] ", empty: !line.slice(m[0].length).trim(), len: m[0].length }
    if ((m = reBullet.exec(line))) return { prefix: m[1] + "- ", empty: !line.slice(m[0].length).trim(), len: m[0].length }
    return null
}
