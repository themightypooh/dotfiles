import math, os, sys, subprocess, random
import numpy as np
from PIL import Image, ImageDraw
from proto import *

W, H = 960, 540
SS = 2
VIEW_H = 1300.0
VIEW_W = VIEW_H * W / H


def scr(x, y):
    return ((x + VIEW_W / 2) / VIEW_W * W * SS, (VIEW_H / 2 - (y - 50)) / VIEW_H * H * SS)


def xf(part, lx, ly):
    b = part.body
    f = part.fish.facing
    a = b.angle
    x, y = lx * f, ly
    return (b.position[0] * U + x * math.cos(a) - y * math.sin(a), b.position[1] * U + x * math.sin(a) + y * math.cos(a))


def pieces(f):
    n = f.spec.nseg
    out, cur = [], [0]
    for k in range(n - 1):
        if f.joints[k].broken:
            out.append(cur); cur = []
        cur.append(k + 1)
    out.append(cur)
    return out


def skin(f, segs, bw=0.05):
    sp = f.spec
    ss = f.ss
    a, b = segs[0], segs[-1]
    s0, s1 = ss[a], ss[b + 1]
    N = max(8, int((s1 - s0) * 48))
    top, bot, mid = [], [], []
    for i in range(N + 1):
        s = s0 + (s1 - s0) * i / N
        k = a
        while k < b and s > ss[k + 1]: k += 1
        ht, hb = sp.h(s)
        pts = []
        for ly in (ht, 0.0, -hb):
            p = xf(f.parts[k], sp.x(s), ly)
            # blend with the neighbour across an intact joint
            for j in range(a + 1, b + 1):
                d = s - ss[j]
                if abs(d) < bw:
                    w = smoothstep(-bw, bw, d)
                    pa = xf(f.parts[j - 1], sp.x(s), ly)
                    pb = xf(f.parts[j], sp.x(s), ly)
                    p = (pa[0] * (1 - w) + pb[0] * w, pa[1] * (1 - w) + pb[1] * w)
            pts.append(p)
        top.append(pts[0]); mid.append(pts[1]); bot.append(pts[2])
    return top, mid, bot, s0, s1


def lerpc(c0, c1, t):
    return tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))


def draw_fish(d, f):
    sp = f.spec
    P = f.parts
    n = sp.nseg
    fin = sp.fin
    finc = lerpc(fin, (20, 30, 40), 0.25)
    # tail and dorsal behind the body
    tail = P[n]
    d.polygon([scr(*xf(tail, x, y)) for x, y in f.tail_outline], fill=finc, outline=lerpc(finc, (0, 0, 0), 0.4))
    dors = P[n + 1]
    d.polygon([scr(*xf(dors, x, y)) for (p0, p1) in dors.edges for x, y in [p0]], fill=finc)
    for segs in pieces(f):
        top, mid, bot, s0, s1 = skin(f, segs)
        N = len(top) - 1
        for i in range(N):
            s = s0 + (s1 - s0) * (i + 0.5) / N
            cb = sp.back
            if sp.stripe and math.sin(s * 46) > 0.35:
                cb = sp.stripe
            d.polygon([scr(*top[i]), scr(*top[i + 1]), scr(*mid[i + 1]), scr(*mid[i])], fill=cb)
            d.polygon([scr(*mid[i]), scr(*mid[i + 1]), scr(*bot[i + 1]), scr(*bot[i])], fill=sp.belly)
        outline = [scr(*p) for p in top] + [scr(*p) for p in reversed(bot)]
        d.line(outline + ([outline[0]] if s0 == 0 else []), fill=lerpc(sp.back, (0, 0, 0), 0.55), width=2)
        # torn ends: ragged edge, skin flap, bone sticking out of the front half, socket on the back half
        for cut_s, seg, sign, jidx in ((s0, segs[0], +1, segs[0] - 1), (s1, segs[-1], -1, segs[-1])):
            if cut_s <= 0.0 or (cut_s >= 1.0 and not f.joints[n - 1].broken):
                continue
            jj = f.joints[jidx]
            rnd = random.Random(getattr(jj, 'seed', 1))
            ht, hb = sp.h(cut_s); h = ht + hb
            cx = sp.x(cut_s)
            bulge = sp.L * 0.04 * sign
            skew = (rnd.random() - 0.5) * 1.6
            ring = []
            for i in range(13):
                t = i / 12
                reach = (0.35 + 0.65 * math.sin(math.pi * t)) * (0.55 + rnd.random() * 1.1)
                if i % 3 == 1: reach *= 0.25
                ring.append(xf(P[seg], cx + bulge * reach + bulge * skew * (t - 0.5), ht - h * t))
            d.polygon([scr(*p) for p in ring], fill=(175, 40, 45), outline=(95, 8, 14))
            d.polygon([scr(*xf(P[seg], cx - bulge * 0.15, ht)), scr(*xf(P[seg], cx + bulge * (1.2 + rnd.random() * 0.8), ht - h * 0.15)), scr(*xf(P[seg], cx + bulge * 0.25, ht - h * 0.22))], fill=lerpc(sp.back, (95, 8, 14), 0.25))
            mid = (ht - hb) * 0.5; bw = max(2, h * 0.1) / VIEW_H * H * SS
            if sign < 0:
                d.line([scr(*xf(P[seg], cx - bulge * 0.2, mid)), scr(*xf(P[seg], cx + bulge * 2.3, mid))], fill=(238, 230, 212), width=int(max(2, bw)))
                tx, ty = scr(*xf(P[seg], cx + bulge * 2.3, mid))
                d.ellipse([tx - bw, ty - bw, tx + bw, ty + bw], fill=(238, 230, 212))
            else:
                ox, oy = scr(*xf(P[seg], cx + bulge * 0.35, mid))
                d.ellipse([ox - bw * 1.3, oy - bw, ox + bw * 1.3, oy + bw], fill=(50, 0, 6))
    # flesh strands stretching across a fresh tear, snapping as the halves fly apart
    for jj in f.joints:
        if not jj.broken or jj.kind == 'fin' or not hasattr(jj, 'torn_at'): continue
        age = g_time[0] - jj.torn_at
        if age > 0.45: continue
        ht, hb = sp.h(jj.s); x = sp.x(jj.s)
        rnd = random.Random(jj.seed)
        for k, oy in enumerate((ht * 0.5, 0, -hb * 0.5)):
            pa = xf(jj.a, x, oy); pb = xf(jj.b, x, oy)
            dd = math.hypot(pb[0] - pa[0], pb[1] - pa[1]); snap = 60 + rnd.random() * 70
            if dd > snap: continue
            wdt = int(max(1, (3.4 * (1 - age / 0.45) * (1 - dd / snap) + 0.6) / VIEW_H * H * SS))
            sag = ((pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2 - dd * 0.18)
            d.line([scr(*pa), scr(*sag), scr(*pb)], fill=(210, 190, 175) if k == 1 else (175, 40, 45), width=wdt)
    # scraps of torn fish
    for p in P:
        if p.kind != 'scrap': continue
        b = p.body
        pts = [b.GetWorldPoint((px / U, py / U)) for px, py in p.poly]
        d.polygon([scr(q[0] * U, q[1] * U) for q in pts], fill=(185, 55, 58), outline=lerpc(sp.back, (60, 0, 5), 0.5))
    # pectoral on top
    pec = P[n + 2]
    d.polygon([scr(*xf(pec, x, y)) for (p0, p1) in pec.edges for x, y in [p0]], fill=lerpc(fin, (255, 255, 255), 0.2), outline=finc)
    # eye
    ex, ey = scr(*xf(P[0], sp.x(sp.head_frac * 0.32), sp.h(sp.head_frac * 0.32)[0] * 0.25))
    r = max(3, sp.H * 0.16) / VIEW_H * H * SS
    d.ellipse([ex - r, ey - r, ex + r, ey + r], fill=(245, 245, 240))
    d.ellipse([ex - r * 0.55, ey - r * 0.55, ex + r * 0.55, ey + r * 0.55], fill=(10, 10, 10))
    # gill arc
    gl = [scr(*xf(P[0], sp.x(sp.head_frac * 0.8) + 4 * math.sin(t * math.pi), sp.h(sp.head_frac * 0.8)[0] * (0.7 - 1.4 * t))) for t in np.linspace(0, 1, 7)]
    d.line(gl, fill=lerpc(sp.back, (0, 0, 0), 0.5), width=2)


def draw_water(img, g):
    fl = g.fluid
    base_top = np.array([60, 140, 170], float); base_bot = np.array([18, 55, 80], float)
    t = np.linspace(0, 1, NY)[:, None, None]
    col = base_bot * (1 - t) + base_top * t
    col = col + (fl.tracer[..., None] - 0.5) * 50
    spd = np.sqrt(fl.u ** 2 + fl.v ** 2)[..., None]
    col = col + np.clip(spd / 400, 0, 1) * 35
    c = 1 - np.exp(-fl.blood[..., None] * 1.6)
    col = col * (1 - c) + np.array([120, 8, 12]) * c
    small = Image.fromarray(np.clip(col[::-1], 0, 255).astype(np.uint8))
    x0, y0 = scr(TANK_L, SURFACE + 40); x1, y1 = scr(TANK_R, TANK_B)
    big = small.resize((int(x1 - x0), int(y1 - y0)), Image.BILINEAR)
    # free surface: mask above the wave line
    mask = Image.new('L', big.size, 0)
    md = ImageDraw.Draw(mask)
    poly = [(0, big.size[1])]
    for i in range(NX + 1):
        x = TANK_L + i * DX
        sy = scr(x, SURFACE + fl.surf[i])[1] - y0
        poly.append((scr(x, 0)[0] - x0, sy))
    poly.append((big.size[0], big.size[1]))
    md.polygon(poly, fill=255)
    img.paste(big, (int(x0), int(y0)), mask)


g_time = [0.0]


def frame(g, mouse):
    g_time[0] = g.t
    img = Image.new('RGB', (W * SS, H * SS), (28, 26, 30))
    d = ImageDraw.Draw(img)
    d.rectangle([scr(-1300, FLOOR), scr(1300, -800)], fill=(90, 60, 36))
    d.rectangle([scr(-880, TANK_B - 26), scr(880, FLOOR)], fill=(80, 54, 32))
    d.rectangle([scr(TANK_L, RIM), scr(TANK_R, TANK_B)], fill=(60, 66, 74))
    draw_water(img, g)
    d.rectangle([scr(TANK_L, GRAVEL_TOP), scr(TANK_R, TANK_B)], fill=(120, 105, 85))
    for pts in ARCH:
        d.polygon([scr(*p) for p in pts], fill=(95, 92, 88))
    for f in g.fish:
        draw_fish(d, f)
    d.rectangle([scr(TANK_L - 30, RIM), scr(TANK_L, TANK_B)], fill=(120, 160, 175))
    d.rectangle([scr(TANK_R, RIM), scr(TANK_R + 30, TANK_B)], fill=(120, 160, 175))
    d.rectangle([scr(TANK_L - 30, TANK_B), scr(TANK_R + 30, TANK_B - 26)], fill=(20, 20, 22))
    if mouse:
        mx, my = scr(mouse[0], mouse[1])
        r = 14 * SS
        d.rectangle([mx - r, my - r, mx + r, my + r], fill=(240, 200, 160) if not mouse[2] else (255, 150, 120), outline=(40, 20, 10), width=3)
    return img.resize((W, H), Image.LANCZOS)


class Juggler:
    """Closed-loop fist: uppercut fish 0 out of the water, then hit it from below each time it starts falling."""
    def __init__(self):
        self.swing = None  # (t0, start, end, dur)
        self.pos = (-300.0, -250.0)
        self.count = 0

    def __call__(self, g, t):
        f = g.fish[0]
        head = f.parts[0].body
        hx, hy = head.worldCenter[0] * U, head.worldCenter[1] * U
        vy = head.linearVelocity[1] * U
        if self.swing:
            t0, a, b, dur = self.swing
            k = (t - t0) / dur
            if k >= 1:
                self.swing = None; self.pos = b
            else:
                self.pos = (a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k)
                return (self.pos[0], self.pos[1], True, False)
        if t < 2.0:
            return (self.pos[0], self.pos[1], False, False)
        airborne = not g.in_water(hx, hy)
        if (not airborne and hy > -260) or (airborne and vy < 150):
            side = 1 if (int(t * 3) % 2) else -1
            a = (hx + 40 * side, hy - 120)
            b = (hx - 30 * side, hy + 110)
            self.count += 1
            smash = self.count % 6 == 0  # every sixth swing is a full-speed clenched smash
            self.swing = (t, a, b, 0.09 if smash else 0.3)
            g.fist_last = a  # the swing starts where the fist is put, no teleport speed
            return (a[0], a[1], True, False)
        # drift towards a spot under the fish
        tx, ty = hx, hy - 160
        self.pos = (self.pos[0] + (tx - self.pos[0]) * 0.12, self.pos[1] + (ty - self.pos[1]) * 0.12)
        return (self.pos[0], self.pos[1], False, False)


def mouse_script(t):
    """scripted fist: (x, y, down, punch)"""
    if t < 2.0:
        return None
    if t < 5.0:  # slow circles under the goldfish
        a = (t - 2) * 2.2
        return (-420 + 160 * math.cos(a), 60 + 110 * math.sin(a), False, False)
    if t < 6.0:
        k = (t - 5)
        return (-200 + 600 * k, 60 - 260 * k, False, False)
    if t < 9.0:  # held, fast swipes toward the right wall through the mackerel
        k = ((t - 6) * 1.5) % 1.0
        return (-100 + 850 * k, -150 + 380 * k, True, False)
    if t < 12.0:
        k = (t - 9)
        x = 300 + 120 * math.sin(k * 3)
        return (x, -150 + 200 * math.cos(k * 2), True, (int(k * 50) % 25) == 0)
    k = t - 12
    return (-600 + 1100 * ((k * 0.8) % 1.0), 100 - 300 * math.sin(k * 2), True, False)


def main():
    g = Game()
    out = sys.argv[1] if len(sys.argv) > 1 else "frames"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 16
    os.makedirs(out, exist_ok=True)
    dt = 1 / 50
    n = int(secs / dt)
    start = [(f.parts[0].body.position[0] * U, f.parts[0].body.position[1] * U) for f in g.fish]
    jug = Juggler()
    for i in range(n):
        t = i * dt
        g.mouse = jug(g, t)
        g.step(dt)
        if i % 2 == 0:
            frame(g, g.mouse).save(f"{out}/f{i // 2:05d}.png")
        if i == int(2.0 / dt):
            moved = [math.hypot(f.parts[0].body.position[0] * U - s[0], f.parts[0].body.position[1] * U - s[1]) for f, s in zip(g.fish, start)]
            print("swim displacement after 2s:", [round(m) for m in moved])
    print("events:", g.events)


if __name__ == "__main__":
    main()
