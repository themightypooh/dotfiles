#!/usr/bin/env python3
# Builds WavegooRoundsquare.ttf: a digitisation of Joseph Churchward's Roundsquare (the
# Bugonia title font), measured off the Te Papa specimen negative. Every glyph is a solid
# block (or a triangle for A / M / V / W / Y) with big round dots, hairline slits and wedges
# cut out of it; the cut-outs make the letter. Corners stay sharp, like the original.
#
# Needs fonttools + shapely:   python -m venv env && env/bin/pip install fonttools shapely
# Run:                         env/bin/python roundsquare.py   (writes next to this file)
# Tweak a letter: edit its entry in GLYPHS below; units are 1/1000 em, caps are H tall,
# and each letter's width is the one measured from the specimen.
import os
from shapely.geometry import Point, Polygon, box
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from shapely import affinity
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

H = 700        # cap height = block height
W = 560        # typical block width (used for punctuation and the space)
S = 30         # slit width: the original's are hairlines; this is as thin as stays visible in the bar
D = 105        # standard dot radius (B, E, H, S ... all share it)
SIDE = 64      # space either side of a glyph


def blk(w=W, h=H, y=0):
    return box(0, y, w, y + h)

def rect(x0, y0, x1, y1):
    return box(x0, y0, x1, y1)

def circ(x, y, r):
    return Point(x, y).buffer(r, 48)

def poly(*pts):
    return Polygon(pts)

def cut(base, *holes):
    return base.difference(unary_union(holes))

def key(x, y, r, to, w=S, off=0):
    """Churchward's keyhole: a round dot with a hairline slit running from it out past an edge.
    `off` shifts a sideways slit up (+) or down (-) off the dot's centre line, as on 2 5 6 9."""
    far = 5000
    slit = {"up": rect(x - w / 2, y, x + w / 2, far), "down": rect(x - w / 2, -far, x + w / 2, y),
            "left": rect(-far, y + off - w / 2, x, y + off + w / 2), "right": rect(x, y + off - w / 2, far, y + off + w / 2)}[to]
    return unary_union([circ(x, y, r), slit])

def corner_dot(x, y, r, w):
    """a dot that opens into the block's lower-right corner (F, P)"""
    return unary_union([circ(x, y, r), rect(x, -1, w + 1, y)])

def notch(w, y, side, depth, half):
    """small V notch in the left or right edge"""
    if side == "right":
        return poly((w - depth, y), (w + 1, y + half), (w + 1, y - half))
    return poly((depth, y), (-1, y + half), (-1, y - half))

def spin(g, w):
    return affinity.rotate(g, 180, origin=(w / 2, H / 2))

def stadium(x, y0, y1, r):
    return unary_union([circ(x, y0, r), circ(x, y1, r), rect(x - r, y0, x + r, y1)])

def rounded(w, h, rad, corners="tl tr bl br", x=0, y=0):
    """block with the named corners rounded off, lower-left at (x, y)"""
    parts = [rect(rad, 0, w - rad, h), rect(0, rad, w, h - rad)]
    spots = {"bl": (rad, rad), "br": (w - rad, rad), "tl": (rad, h - rad), "tr": (w - rad, h - rad)}
    for k, (px, py) in spots.items():
        parts.append(circ(px, py, rad) if k in corners.split() else rect(px - rad, py - rad, px + rad, py + rad))
    return affinity.translate(unary_union(parts), x, y)


def g_N(w=501):
    # a dot joined to the top edge by a wedge running down from the top-left corner; the bottom is the same turned round
    top = unary_union([circ(0.56 * w, 0.71 * H, 98), poly((-1, H + 1), (0.45 * w, H + 1), (0.45 * w, 0.71 * H), (0.56 * w - 69, 0.71 * H - 69))])
    return cut(blk(w), top, spin(top, w))

def g_Z(w=558):
    tl = unary_union([circ(0.42 * w, 0.71 * H, 100), poly((-1, 0.64 * H), (0.42 * w, 0.64 * H), (0.42 * w - 70, 0.71 * H - 70), (-1, 0.12 * H))])
    return cut(blk(w), tl, spin(tl, w))

def g_T(w=591):
    left = unary_union([rect(-1, 0.12 * H, 0.27 * w, 0.67 * H), rect(-1, -1, 0.22 * w, 0.12 * H + 1),
                        stadium(0.27 * w, 0.2 * H, 0.8 * H, 0.09 * w)])
    return cut(blk(w), left, affinity.scale(left, -1, 1, origin=(w / 2, 0)))

def g_7(w=467):
    left = unary_union([circ(0.36 * w, 0.69 * H, 95), poly((-1, 0.64 * H), (0.36 * w - 67, 0.69 * H - 67), (0.12 * w, -1), (-1, -1))])
    return cut(blk(w), left, poly((w + 1, 0.66 * H), (w + 1, -1), (0.45 * w, -1)))

def g_6(w=456):
    return cut(blk(w), key(0.5 * w, 514, 100, "right", off=62), circ(226, 219, 108))


GLYPHS = {
    "A": cut(poly((0, 0), (667, 0), (333.5, H)), key(333.5, 300, 112, "down")),
    "B": cut(blk(503), circ(241, 514, 106), circ(242, 209, 106), notch(503, 350, "right", 45, 42)),
    "C": cut(blk(571), circ(268, 350, 191), rect(268, 288, 572, 412)),
    "D": cut(poly((0, 0), (540, 0), (614, 84), (614, 574), (522, H), (0, H)), circ(301, 352, 191)),
    "E": cut(blk(452), key(205, 514, D, "right"), key(205, 209, D, "right")),
    "F": cut(blk(442), key(205, 514, D, "right"), corner_dot(205, 209, D, 442)),
    "G": cut(blk(582), cut(unary_union([circ(296, 360, 188), rect(296, 265, 505, 325), rect(296, 427, 583, 427 + S)]), rect(258, 325, 583, 427))),   # round counter, crossbar from the right, slit above it, slot below
    "H": cut(blk(525), key(262.5, 514, D, "up"), key(262.5, 209, D, "down")),
    "I": blk(205),
    "J": cut(blk(603), circ(277, 350, 175), rect(-1, 350, 277, H + 1)),
    "K": cut(blk(528), key(238, 514, D, "up"), key(238, 209, D, "down"), notch(528, 350, "right", 70, 70)),
    "L": cut(blk(582), circ(291, 350, 175), rect(291, 350, 583, H + 1)),
    "M": cut(poly((0, 0), (926, 0), (685, H), (463, 0.45 * H), (241, H)), key(268, 238, 96, "down"), key(658, 238, 96, "down")),
    "N": g_N(),
    "O": cut(blk(612), circ(306, 354, 196)),
    "P": cut(blk(481), circ(238, 494, 127), corner_dot(250, 245, 90, 481)),
    "Q": cut(blk(612), cut(circ(306, 395, 195), circ(306, 250, 75))),
    "R": cut(poly((0, 0), (492, 0), (492, 644), (452, H), (0, H)), circ(240, 515, 106), key(246, 209, D, "down"), notch(492, 330, "right", 42, 40)),
    "S": cut(blk(470), key(232, 514, D, "right"), key(238, 209, D, "left")),
    "T": g_T(),
    "U": cut(blk(511), key(255.5, 280, D, "up")),
    "V": cut(poly((0, H), (677, H), (338.5, 0)), key(338.5, 476, 100, "up")),
    "W": cut(poly((0, H), (926, H), (657, 0), (463, 0.55 * H), (269, 0)), key(278, 441, 96, "up"), key(648, 441, 96, "up")),
    "X": cut(blk(522), key(261, 514, D, "up"), key(261, 209, D, "down"), notch(522, 350, "right", 50, 50), notch(522, 350, "left", 50, 50)),
    "Y": cut(poly((0, H), (667, H), (454, 0.42 * H), (454, 0), (213, 0), (213, 0.42 * H)), key(333.5, 420, 118, "up")),
    "Z": g_Z(),

    "0": cut(blk(560), circ(280, 350, 185)),
    "1": blk(167),
    "2": cut(blk(470), key(235, 514, 100, "left", off=-62), key(235, 209, 100, "right", off=62)),
    "3": cut(blk(448), key(230, 514, 100, "left"), key(230, 209, 100, "left")),
    "4": cut(blk(533), circ(234, 485, 128), rect(-1, -1, 298, 0.3 * H), rect(458, -1, 534, 0.3 * H), poly((-1, H + 1), (170, H + 1), (-1, 0.72 * H))),
    "5": cut(blk(456), key(220, 514, 100, "right", off=62), key(228, 209, 100, "left", off=-62)),
    "6": g_6(),
    "7": g_7(),
    "8": cut(blk(438), circ(211, 514, 107), circ(212, 218, 107), notch(438, 365, "right", 32, 30), notch(438, 365, "left", 32, 30)),
    "9": spin(g_6(), 456),

    ".": blk(130, 130),
    ",": unary_union([blk(130, 130), poly((0, 1), (130, 1), (0, -0.2 * H))]),
    ":": unary_union([blk(130, 130), blk(130, 130, 0.46 * H)]),
    ";": unary_union([blk(130, 130), poly((0, 1), (130, 1), (0, -0.2 * H)), blk(130, 130, 0.46 * H)]),
    "-": blk(280, 120, 0.42 * H),
    "_": blk(450, 100, -0.12 * H),
    "=": unary_union([blk(340, 100, 0.22 * H), blk(340, 100, 0.52 * H)]),
    "+": unary_union([blk(340, 100, 0.43 * H), rect(120, 0.22 * H, 220, 0.78 * H)]),
    "!": unary_union([blk(150, 0.66 * H, 0.34 * H), circ(75, 75, 75)]),
    "?": unary_union([cut(blk(430, 0.58 * H, 0.42 * H), key(190, 0.7 * H, 90, "left"), rect(-1, 0.42 * H - 1, 140, 0.55 * H)),
                      rect(140, 0.28 * H, 300, 0.43 * H), circ(220, 75, 75)]),
    "'": blk(130, 0.3 * H, 0.7 * H),
    '"': unary_union([blk(130, 0.3 * H, 0.7 * H), rect(200, 0.7 * H, 330, H)]),
    "/": poly((0, -0.05 * H), (100, -0.05 * H), (360, 1.05 * H), (260, 1.05 * H)),
    "(": cut(blk(220, 1.1 * H, -0.05 * H), rect(110, 0.12 * H, 221, 0.88 * H)),
    ")": cut(blk(220, 1.1 * H, -0.05 * H), rect(-1, 0.12 * H, 110, 0.88 * H)),
    "·": blk(130, 130, 0.4 * H),
    "%": unary_union([cut(blk(170, 170, H - 170), circ(85, H - 85, 45)), poly((0, 0), (100, 0), (390, H), (290, H)),
                      cut(affinity.translate(blk(170, 170), 220, 0), circ(305, 85, 45))]),
    "&": cut(blk(540), circ(240, 514, 100), circ(240, 209, 100), key(470, 350, 40, "right"), notch(540, 350, "left", 40, 40)),
    "#": cut(blk(500), circ(150, 196, 62), circ(350, 196, 62), circ(150, 504, 62), circ(350, 504, 62)),
}


SPACE = int(W * 0.45)
NAMES = {".": "period", ",": "comma", ":": "colon", ";": "semicolon", "-": "hyphen", "_": "underscore",
         "=": "equal", "+": "plus", "!": "exclam", "?": "question", "'": "quotesingle", '"': "quotedbl",
         "/": "slash", "(": "parenleft", ")": "parenright", "·": "periodcentered", "%": "percent",
         "&": "ampersand", "#": "numbersign"}
DIGITS = {str(i): n for i, n in enumerate("zero one two three four five six seven eight nine".split())}


def gname(ch):
    return NAMES.get(ch) or DIGITS.get(ch) or ch


def draw(geom):
    pen = TTGlyphPen(None)
    polys = [geom] if geom.geom_type == "Polygon" else [g for g in geom.geoms if g.geom_type == "Polygon"]
    for p in polys:
        p = orient(p, sign=-1.0)          # TrueType: outer contours clockwise, holes counter-clockwise
        for ring in [p.exterior, *p.interiors]:
            pts = []
            for x, y in list(ring.coords)[:-1]:
                pt = (round(x), round(y))
                if not pts or pts[-1] != pt:
                    pts.append(pt)
            if len(pts) > 1 and pts[0] == pts[-1]:
                pts.pop()
            if len(pts) < 3:
                continue
            pen.moveTo(pts[0])
            for pt in pts[1:]:
                pen.lineTo(pt)
            pen.closePath()
    return pen.glyph()


def build(path):
    order = [".notdef", "space"]
    glyphs, metrics, cmap = {}, {}, {}

    nd = cut(blk(W * 0.7), rect(W * 0.12, H * 0.1, W * 0.58, H * 0.9))
    glyphs[".notdef"] = draw(affinity.translate(nd, SIDE, 0))
    metrics[".notdef"] = (int(W * 0.7) + 2 * SIDE, SIDE)
    glyphs["space"] = TTGlyphPen(None).glyph()
    metrics["space"] = (SPACE, 0)
    cmap[32] = "space"; cmap[0xA0] = "space"

    for ch, geom in GLYPHS.items():
        name = gname(ch)
        geom = geom.buffer(0)
        minx, _, maxx, _ = geom.bounds
        geom = affinity.translate(geom, SIDE - minx, 0)
        order.append(name)
        glyphs[name] = draw(geom)
        metrics[name] = (round(maxx - minx) + 2 * SIDE, SIDE)
        cmap[ord(ch)] = name
        if ch.isalpha():
            cmap[ord(ch.lower())] = name   # lowercase types as the same block caps

    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=820, descent=-200)
    fb.setupNameTable({"familyName": "Wavegoo Roundsquare", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=820, sTypoDescender=-200, sTypoLineGap=0, usWinAscent=820, usWinDescent=200,
                sCapHeight=H, sxHeight=H, achVendID="WGOO")
    fb.setupPost()
    fb.save(path)


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "WavegooRoundsquare.ttf")
    build(out)
    print("wrote", out)
