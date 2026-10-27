import math, os, sys, subprocess
import numpy as np
from PIL import Image, ImageDraw
from proto import *

W, H = 960, 540
SS = 2
VIEW_H = 1000.0
VIEW_W = VIEW_H * W / H


def scr(x, y):
    return ((x + VIEW_W / 2) / VIEW_W * W * SS, (VIEW_H / 2 - y) / VIEW_H * H * SS)


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
        # wound caps
        for cut_s, seg, sign in ((s0, segs[0], +1), (s1, segs[-1], -1)):
            if cut_s <= 0.0 or cut_s >= 1.0 and f.joints[n - 1].broken is False:
                continue
            ht, hb = sp.h(cut_s)
            cx = sp.x(cut_s)
            bulge = sp.L * 0.035 * sign
            cap = [xf(P[seg], cx + bulge * math.sin(math.pi * t), ht - (ht + hb) * t) for t in np.linspace(0, 1, 9)]
            d.polygon([scr(*p) for p in cap], fill=(150, 20, 25), outline=(90, 5, 10))
            bx, by = scr(*xf(P[seg], cx + bulge * 0.4, (ht - hb) * 0.5 * 0.0))
            d.ellipse([bx - 3 * SS, by - 3 * SS, bx + 3 * SS, by + 3 * SS], fill=(235, 225, 210))
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


def frame(g, mouse):
    img = Image.new('RGB', (W * SS, H * SS), (28, 26, 30))
    d = ImageDraw.Draw(img)
    d.rectangle([scr(TANK_L, LID), scr(TANK_R, TANK_B)], fill=(70, 80, 88))
    draw_water(img, g)
    d.rectangle([scr(TANK_L, GRAVEL_TOP), scr(TANK_R, TANK_B)], fill=(120, 105, 85))
    for pts in ARCH:
        d.polygon([scr(*p) for p in pts], fill=(95, 92, 88))
    for f in g.fish:
        draw_fish(d, f)
    d.rectangle([scr(TANK_L - 30, LID + 30), scr(TANK_R + 30, TANK_B - 40)], outline=(15, 15, 15), width=12)
    if mouse:
        mx, my = scr(mouse[0], mouse[1])
        r = 14 * SS
        d.rectangle([mx - r, my - r, mx + r, my + r], fill=(240, 200, 160) if not mouse[2] else (255, 150, 120), outline=(40, 20, 10), width=3)
    return img.resize((W, H), Image.LANCZOS)


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
    for i in range(n):
        t = i * dt
        g.mouse = mouse_script(t)
        g.step(dt)
        if i % 2 == 0:
            frame(g, g.mouse).save(f"{out}/f{i // 2:05d}.png")
        if i == int(2.0 / dt):
            moved = [math.hypot(f.parts[0].body.position[0] * U - s[0], f.parts[0].body.position[1] * U - s[1]) for f, s in zip(g.fish, start)]
            print("swim displacement after 2s:", [round(m) for m in moved])
    print("events:", g.events)


if __name__ == "__main__":
    main()
