"""Tuning rig for Fishy Flop (not the deliverable).

Same model as the s&box C# code: segmented fish (hull per segment, sprung
revolute joints that break on force/torque), CPU stable-fluids grid,
anisotropic drag coupling, blood as dye.  All gameplay logic is in s&box
units (inches); Box2D 2.3 runs in metres, so we convert at the API edge.
"""
import math, os, sys, random
import numpy as np
from PIL import Image, ImageDraw
import Box2D
from Box2D import b2World, b2PolygonShape, b2FixtureDef

U = 40.0  # s&box units per Box2D metre (matches b2SetLengthUnitsPerMeter(40))

# ------------------------------------------------------------------ tank
TANK_L, TANK_R = -800.0, 800.0
TANK_B, RIM = -470.0, 180.0
LID = RIM
GRAVEL_TOP = -425.0
SURFACE = 0.0
FLOOR = -560.0
NX, NY = 100, 29
DX = (TANK_R - TANK_L) / NX
DY = (SURFACE - TANK_B) / NY
G = 850.0

C = dict(
    drag_n=0.030, drag_t=0.004, drag_q=0.00004,  # per unit length
    wake=0.010, inv_tau_n=9.0, inv_tau_t=1.2, thrust=1.0,
    swim_hz=2.2, swim_amp=22.0, muscle_hz=5.0, limp_hz=1.6, damp=0.35,
    break_force=5200.0, break_torque=90000.0,
    mouse_push=0.55, mouse_radius=70.0, punch=900.0,
)


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


# ------------------------------------------------------------------ fluid
class Fluid:
    def __init__(self):
        self.u = np.zeros((NY, NX), np.float32)
        self.v = np.zeros((NY, NX), np.float32)
        self.p = np.zeros((NY, NX), np.float32)
        self.blood = np.zeros((NY, NX), np.float32)
        yy, xx = np.mgrid[0:NY, 0:NX]
        self.base = (0.5 + 0.25 * np.sin(xx * 0.35 + np.sin(yy * 0.21) * 2) * np.sin(yy * 0.29 + xx * 0.05)).astype(np.float32)
        self.tracer = self.base.copy()
        self.solid = np.zeros((NY, NX), bool)
        gy = int((GRAVEL_TOP - TANK_B) / DY)
        self.solid[:gy, :] = True
        self.xx, self.yy = xx.astype(np.float32), yy.astype(np.float32)
        self.surf = np.zeros(NX + 1, np.float32)
        self.surf_v = np.zeros(NX + 1, np.float32)

    def cell(self, x, y):
        return (x - TANK_L) / DX - 0.5, (y - TANK_B) / DY - 0.5

    def sample(self, f, x, y):
        cx, cy = self.cell(x, y)
        cx = min(max(cx, 0), NX - 1.001); cy = min(max(cy, 0), NY - 1.001)
        i, j = int(cx), int(cy); fx, fy = cx - i, cy - j
        return (f[j, i] * (1 - fx) * (1 - fy) + f[j, i + 1] * fx * (1 - fy) +
                f[j + 1, i] * (1 - fx) * fy + f[j + 1, i + 1] * fx * fy)

    def vel(self, x, y):
        return float(self.sample(self.u, x, y)), float(self.sample(self.v, x, y))

    def drag_to(self, x, y, tu, tv, r, k):
        cx, cy = self.cell(x, y)
        d2 = ((self.xx - cx) * DX) ** 2 + ((self.yy - cy) * DY) ** 2
        w = np.exp(-d2 / (r * r)) * k
        self.u += (tu - self.u) * w; self.v += (tv - self.v) * w

    def splat(self, x, y, fu, fv, r, dye=0.0):
        cx, cy = self.cell(x, y)
        d2 = ((self.xx - cx) * DX) ** 2 + ((self.yy - cy) * DY) ** 2
        w = np.exp(-d2 / (r * r))
        self.u += fu * w; self.v += fv * w
        if dye: self.blood += dye * w

    def radial(self, x, y, s, r):
        cx, cy = self.cell(x, y)
        dx = (self.xx - cx) * DX; dy = (self.yy - cy) * DY
        d = np.sqrt(dx * dx + dy * dy) + 1e-3
        w = np.exp(-(d * d) / (r * r))
        self.u += dx / d * s * w; self.v += dy / d * s * w

    def advect(self, f, dt):
        x = self.xx - self.u * dt / DX
        y = self.yy - self.v * dt / DY
        x = np.clip(x, 0, NX - 1.001); y = np.clip(y, 0, NY - 1.001)
        i = x.astype(int); j = y.astype(int); fx = x - i; fy = y - j
        return (f[j, i] * (1 - fx) * (1 - fy) + f[j, i + 1] * fx * (1 - fy) +
                f[j + 1, i] * (1 - fx) * fy + f[j + 1, i + 1] * fx * fy)

    def step(self, dt):
        u, v = self.u, self.v
        u[self.solid] = 0; v[self.solid] = 0
        self.u, self.v = self.advect(u, dt), self.advect(v, dt)
        self.u *= 0.995; self.v *= 0.995
        self.walls()
        div = np.zeros_like(self.u)
        div[1:-1, 1:-1] = ((self.u[1:-1, 2:] - self.u[1:-1, :-2]) / (2 * DX) +
                           (self.v[2:, 1:-1] - self.v[:-2, 1:-1]) / (2 * DY))
        p = self.p * 0.9
        h2 = DX * DY
        for _ in range(24):
            pn = np.zeros_like(p)
            pn[1:-1, 1:-1] = (p[1:-1, 2:] + p[1:-1, :-2] + p[2:, 1:-1] + p[:-2, 1:-1] - div[1:-1, 1:-1] * h2) * 0.25
            pn[:, 0] = pn[:, 1]; pn[:, -1] = pn[:, -2]; pn[0, :] = pn[1, :]
            pn[-1, :] = 0  # free surface
            p = pn
        self.p = p
        self.u[1:-1, 1:-1] -= (p[1:-1, 2:] - p[1:-1, :-2]) / (2 * DX)
        self.v[1:-1, 1:-1] -= (p[2:, 1:-1] - p[:-2, 1:-1]) / (2 * DY)
        self.walls()
        self.tracer = self.advect(self.tracer, dt)
        self.tracer += (self.base - self.tracer) * 0.01
        self.blood = self.advect(self.blood, dt) * 0.9993
        # surface waves driven by the top row's vertical velocity
        vt = np.concatenate([[self.v[-1, 0]], 0.5 * (self.v[-1, 1:] + self.v[-1, :-1]), [self.v[-1, -1]]])
        lap = np.zeros_like(self.surf); lap[1:-1] = self.surf[2:] + self.surf[:-2] - 2 * self.surf[1:-1]
        self.surf_v += (lap * 900.0 - self.surf * 2.0) * dt + vt * dt * 0.35
        self.surf_v *= 0.985
        self.surf += self.surf_v * dt
        self.surf -= self.surf.mean()
        np.clip(self.surf, -24, 24, out=self.surf)

    def walls(self):
        self.u[:, 0] = 0; self.u[:, -1] = 0; self.v[0, :] = 0
        self.u[self.solid] = 0; self.v[self.solid] = 0


# ------------------------------------------------------------------ fish spec
class Spec:
    def __init__(self, name, L, H, peak, ped, nseg, head_frac, tail_len, tail_h, fork,
                 back, belly, fin, stripe=None, dorsal=(0.35, 0.6, 0.35), mass=1.0):
        self.__dict__.update(locals()); del self.__dict__['self']
        self.a = math.log(0.5) / math.log(peak)

    def h(self, s):
        """half height (top, bottom) at spine param s in [0,1]"""
        base = math.sin(math.pi * min(max(s, 1e-4), 1.0) ** self.a) ** 0.72
        q = smoothstep(0.62, 1.0, s)
        f = (1 - q) * base + q * self.ped
        f = max(f, self.ped if s > 0.6 else 0.0)
        return self.H * f * 1.08, self.H * f * 0.92

    def x(self, s):
        return self.L * (0.5 - s)


SPECS = [
    Spec("goldie", 150, 0.42 * 150 * 0.5, 0.32, 0.22, 5, 0.30, 62, 40, 0.42,
         (190, 80, 20), (255, 196, 120), (240, 120, 40)),
    Spec("mackerel", 210, 0.22 * 210 * 0.5, 0.28, 0.16, 6, 0.24, 64, 44, 0.62,
         (40, 70, 95), (225, 232, 238), (90, 110, 130), stripe=(25, 40, 55)),
    Spec("tang", 120, 0.58 * 120 * 0.5, 0.40, 0.25, 4, 0.34, 40, 30, 0.25,
         (230, 190, 20), (255, 230, 90), (240, 200, 30)),
]


# ------------------------------------------------------------------ fish
class Part:
    def __init__(self, body, kind, s0=0.0, s1=0.0, mass=0.1):
        self.body, self.kind, self.s0, self.s1, self.mass = body, kind, s0, s1, mass
        self.fish = None


class Joint:
    def __init__(self, j, a, b, s, kind):
        self.j, self.a, self.b, self.s, self.kind = j, a, b, s, kind
        self.broken = False
        self.bleed = 0.0
        self.target = 0.0


def b2v(x, y): return (x / U, y / U)


class Fish:
    def __init__(self, world, spec, x, y, facing, rng):
        self.spec, self.world = spec, world
        self.ox, self.oy, self.facing = x, y, facing
        self.parts, self.joints = [], []
        self.t = rng.random() * 10
        self.stun = 0.0
        self.alive = True
        self.dying = 0.0
        self.turn = 0.0
        self.goal = (x, y)
        self.rng = rng
        L = spec.L
        n = spec.nseg
        ss = [0.0, spec.head_frac] + [spec.head_frac + (1 - spec.head_frac) * (k + 1) / (n - 1) for k in range(n - 1)]
        self.ss = ss
        group = -rng.randint(1, 30000)
        total_area = 0
        segs = []
        for k in range(n):
            pts = self.seg_points(ss[k], ss[k + 1])
            segs.append(pts)
            total_area += abs(poly_area(pts))
        for k in range(n):
            pts = segs[k]
            m = spec.mass * abs(poly_area(pts)) / total_area * 0.86
            p = self.make_part(pts, m, group, "head" if k == 0 else "body", ss[k], ss[k + 1])
        # tail fin: two convex lobes on one body
        ped = spec.h(1.0)
        bx = spec.x(1.0) + 0.01 * L
        tl, th, fork = spec.tail_len, spec.tail_h, spec.fork
        up = [(bx, ped[0]), (bx - tl, th), (bx - tl * fork, 0), (bx, 0)]
        lo = [(bx, 0), (bx - tl * fork, 0), (bx - tl, -th), (bx, -ped[1])]
        self.tail_outline = [(bx + 2, ped[0] * 0.9), (bx - tl * 0.55, th * 0.7), (bx - tl, th), (bx - tl * 0.85, th * 0.55),
                             (bx - tl * fork, 0), (bx - tl * 0.85, -th * 0.55), (bx - tl, -th), (bx - tl * 0.55, -th * 0.7), (bx + 2, -ped[1] * 0.9)]
        self.make_part([up, lo], spec.mass * 0.07, group, "tail", 1.0, 1.0, multi=True)
        # dorsal fin on one mid segment
        d0, d1, dh = spec.dorsal
        k = max(1, min(n - 1, next(i for i in range(n) if ss[i + 1] > (d0 + d1) / 2)))
        a0, a1 = max(ss[k] + 0.01, d0), min(ss[k + 1] - 0.01, d1)
        top0, top1 = spec.h(a0)[0], spec.h(a1)[0]
        dpts = [(spec.x(a0), top0 - 3), (spec.x(a0) - (spec.x(a0) - spec.x(a1)) * 0.25, top0 + dh * spec.H),
                (spec.x(a1), top1 + dh * spec.H * 0.35), (spec.x(a1), top1 - 3)]
        self.make_part(dpts, spec.mass * 0.03, group, "dorsal", a0, a1)
        self.dorsal_seg = k
        # pectoral fin, on the side of the head (drawn over the body)
        hs = spec.head_frac * 0.92
        px, py = spec.x(hs), -spec.H * 0.15
        ppts = [(px + 2, py + 4), (px - spec.L * 0.13, py - spec.H * 0.10), (px - spec.L * 0.11, py - spec.H * 0.30), (px + 2, py - 4)]
        self.make_part(ppts, spec.mass * 0.02, group, "pectoral", hs, hs)
        # joints
        P = self.parts
        for k in range(n - 1):
            self.add_joint(P[k], P[k + 1], spec.x(ss[k + 1]), 0.0, ss[k + 1], "spine", 38)
        self.add_joint(P[n - 1], P[n], spec.x(1.0), 0.0, 1.0, "tail", 40)
        self.add_joint(P[self.dorsal_seg], P[n + 1], spec.x(a0), top0 - 2, a0, "fin", 25)
        self.add_joint(P[0], P[n + 2], px, py, hs, "fin", 45)

    def seg_points(self, s0, s1):
        sp = self.spec
        pts = []
        steps = 3 if s0 > 0 else 3
        ss = [s0 + (s1 - s0) * i / steps for i in range(steps + 1)]
        if s0 == 0: ss[0] = 0.02
        for s in ss: pts.append((sp.x(s), sp.h(s)[0]))
        for s in reversed(ss): pts.append((sp.x(s), -sp.h(s)[1]))
        return pts

    def to_world(self, lx, ly):
        f = self.facing
        return self.ox + lx * f, self.oy + ly

    def make_part(self, pts, mass, group, kind, s0, s1, multi=False):
        polys = pts if multi else [pts]
        body = self.world.CreateDynamicBody(position=b2v(self.ox, self.oy), angle=0.0, linearDamping=0.0, angularDamping=0.6)
        area = sum(abs(poly_area(pp)) for pp in polys)
        for pp in polys:
            wpts = [b2v(x * self.facing, y) for (x, y) in pp]
            if self.facing < 0: wpts.reverse()
            fd = b2FixtureDef(shape=b2PolygonShape(vertices=wpts), density=mass / (area / (U * U)), friction=0.35, restitution=0.1)
            fd.filter.groupIndex = group
            body.CreateFixture(fd)
        part = Part(body, kind, s0, s1, mass)
        part.fish = self
        part.edges = sum((poly_edges(pp) for pp in polys), [])
        part.perimeter = sum(math.hypot(e[1][0] - e[0][0], e[1][1] - e[0][1]) for e in part.edges)
        self.parts.append(part)
        return part

    def add_joint(self, a, b, lx, ly, s, kind, lim):
        wx, wy = self.to_world(lx, ly)
        j = self.world.CreateRevoluteJoint(bodyA=a.body, bodyB=b.body, anchor=b2v(wx, wy), enableLimit=True,
                                           lowerAngle=-math.radians(lim), upperAngle=math.radians(lim), collideConnected=False)
        jj = Joint(j, a, b, s, kind)
        jj.local = (lx, ly)
        self.joints.append(jj)


def joint_inertia(body, anchor):
    lc = body.localCenter
    icom = body.inertia - body.mass * (lc[0] ** 2 + lc[1] ** 2)
    wc = body.worldCenter
    d2 = (wc[0] - anchor[0]) ** 2 + (wc[1] - anchor[1]) ** 2
    return (icom + body.mass * d2) * U * U


def k_of(P, kind): return [i for i, p in enumerate(P) if p.kind == kind]


def poly_area(pts):
    return 0.5 * sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))


def poly_edges(pts):
    return [(pts[i], pts[(i + 1) % len(pts)]) for i in range(len(pts))]


# ------------------------------------------------------------------ game
class Game:
    def __init__(self, seed=2):
        self.rng = random.Random(seed)
        self.world = b2World(gravity=(0, 0), doSleep=False)
        self.fluid = Fluid()
        self.fish = []
        self.t = 0.0
        self.make_tank()
        layout = [(0, -480, -120, 1), (0, 150, -170, -1), (1, -250, -80, 1), (1, 430, -90, -1), (2, -600, -300, 1), (2, 600, -250, -1)]
        for si, x, y, f in layout:
            self.fish.append(Fish(self.world, SPECS[si], x, y, f, self.rng))
        self.mouse = None
        self.mouse_prev = None
        self.events = []

    def make_tank(self):
        def box(cx, cy, hw, hh):
            b = self.world.CreateStaticBody(position=b2v(cx, cy))
            b.CreatePolygonFixture(box=(hw / U, hh / U), friction=0.6)
        box(0, TANK_B - 15, 830, 15)
        box(0, (TANK_B + GRAVEL_TOP) / 2, 800, (GRAVEL_TOP - TANK_B) / 2)
        gh = (RIM - TANK_B + 30) / 2
        box(TANK_L - 15, TANK_B - 30 + gh, 15, gh)
        box(TANK_R + 15, TANK_B - 30 + gh, 15, gh)
        box(0, (TANK_B - 26 + FLOOR) / 2, 880, (TANK_B - 26 - FLOOR) / 2)
        box(0, FLOOR - 50, 1300, 50)
        box(-1200, 500, 50, 1200); box(1200, 500, 50, 1200); box(0, 730, 1300, 50)
        # rock arch with a real hole: two legs + lintel
        for pts in ARCH:
            b = self.world.CreateStaticBody()
            b.CreatePolygonFixture(vertices=[b2v(x, y) for x, y in pts], friction=0.6)
        for pts in ARCH:
            mark_solid(self.fluid, pts)

    def in_water(self, x, y):
        return TANK_L < x < TANK_R and y > TANK_B and y < self.surface_at(x)

    def surface_at(self, x):
        cx = (x - TANK_L) / DX
        i = int(min(max(cx, 0), NX - 1)); f = cx - i
        return SURFACE + self.fluid.surf[i] * (1 - f) + self.fluid.surf[min(i + 1, NX)] * f

    def step(self, dt):
        self.t += dt
        fl = self.fluid
        # mouse
        if self.mouse is not None:
            mx, my, down, punch = self.mouse
            if self.mouse_prev is not None:
                vx, vy = (mx - self.mouse_prev[0]) / dt, (my - self.mouse_prev[1]) / dt
                if TANK_L < mx < TANK_R and TANK_B < my < SURFACE:
                    sp = math.hypot(vx, vy); cap = 2600.0
                    if sp > cap: vx, vy = vx * cap / sp, vy * cap / sp
                    fl.drag_to(mx, my, vx, vy, C['mouse_radius'] * (1.5 if down else 1.0), 0.55 if down else 0.25)
            if punch:
                fl.radial(mx, my, C['punch'], 110)
            self.mouse_prev = (mx, my)
        self.fist_hits(dt)
        self.pending = []
        for f in self.fish:
            self.fish_ai(f, dt)
        for f in self.fish:
            for p in f.parts:
                self.couple(p, dt)
        sub = 4
        for _ in range(sub):
            for f in self.fish:
                self.muscles(f, dt / sub)
            for body, force, point in self.pending:
                if point is None: body.ApplyForceToCenter(force, True)
                else: body.ApplyForce(force, point, True)
            self.world.Step(dt / sub, 8, 3)
        self.check_breaks(dt)
        fl.step(dt)

    def fist_hits(self, dt):
        if self.mouse is None or self.mouse_prev is None:
            return
        mx, my, down, _ = self.mouse
        fv = ((mx - self.fist_last[0]) / dt, (my - self.fist_last[1]) / dt) if hasattr(self, 'fist_last') else (0, 0)
        if math.hypot(fv[0], fv[1]) * dt > 400: fv = (0, 0)  # cursor jumped, not a swing (same rule as the game)
        spd = math.hypot(fv[0], fv[1])
        if spd > 2600: fv = (fv[0] / spd * 2600, fv[1] / spd * 2600)  # same cap as the game
        self.fist_last = (mx, my)
        if down: fv = (fv[0] * 1.25, fv[1] * 1.25)
        for f in self.fish:
            f.hitcd = max(0.0, getattr(f, 'hitcd', 0.0) - dt)
            if f.hitcd > 0: continue
            best, struck, cpt = 26 * (1.15 if down else 1), None, None
            for p in f.parts:
                for fx in p.body.fixtures:
                    sh = fx.shape
                    lp = p.body.GetLocalPoint(b2v(mx, my))
                    verts = [(v[0] * U, v[1] * U) for v in sh.vertices]
                    d, c = dist_poly((lp[0] * U, lp[1] * U), verts)
                    if d < best:
                        best, struck = d, p
                        w = p.body.GetWorldPoint((c[0] / U, c[1] / U)); cpt = (w[0] * U, w[1] * U)
            if struck is None: continue
            pv = struck.body.GetLinearVelocityFromWorldPoint(b2v(*cpt))
            rx, ry = fv[0] - pv[0] * U, fv[1] - pv[1] * U
            sp = math.hypot(rx, ry)
            if sp < 220: continue
            if sp > 1300: rx, ry = rx / sp * 1300, ry / sp * 1300; sp = 1300
            maxup = math.sqrt(2 * G * max(0.0, 680 - 170 - cpt[1])) - pv[1] * U
            if ry * 0.5 > maxup: ry = max(0.0, maxup) / 0.5
            piece = self.piece_of(f, struck)
            struck.body.ApplyLinearImpulse((rx * struck.mass * 0.55 / U, ry * struck.mass * 0.55 / U), b2v(*cpt), True)
            for q in piece:
                if q is not struck:
                    q.body.ApplyLinearImpulse((rx * q.mass * 0.45 / U, ry * q.mass * 0.45 / U), q.body.worldCenter, True)
            if math.hypot(fv[0], fv[1]) >= 1150 and sp >= 920:
                tear = None
                for jj in f.joints:
                    if jj.broken or not (jj.a is struck or jj.b is struck): continue
                    if tear is None or (tear.kind == 'fin' and jj.kind != 'fin'): tear = jj
                if tear is not None: tear.damage = 1.5
            f.stun = max(f.stun, 1.2); f.hitcd = 0.09
            air = not self.in_water(*cpt)
            if air: f.combo = getattr(f, 'combo', 0) + 1
            self.events.append((round(self.t, 2), f.spec.name + str(self.fish.index(f)), 'HIT', int(math.hypot(fv[0], fv[1])), 'air' if air else 'water', getattr(f, 'combo', 0)))

    def piece_of(self, f, start):
        seen = {id(start)}; out = [start]; stack = [start]
        while stack:
            p = stack.pop()
            for jj in f.joints:
                if jj.broken: continue
                for a, b in ((jj.a, jj.b), (jj.b, jj.a)):
                    if a is p and id(b) not in seen:
                        seen.add(id(b)); out.append(b); stack.append(b)
        return out

    def fish_ai(self, f, dt):
        f.t += dt
        f.stun = max(0.0, f.stun - dt)
        f.dying = max(0.0, f.dying - dt)
        if not f.alive:
            return
        head = f.parts[0].body
        hx, hy = head.position[0] * U, head.position[1] * U
        gx, gy = f.goal
        if math.hypot(gx - hx, gy - hy) < 80 or f.rng.random() < dt * 0.08:
            f.goal = (f.rng.uniform(TANK_L + 150, TANK_R - 150), f.rng.uniform(GRAVEL_TOP + 90, SURFACE - 90))
            gx, gy = f.goal
        heading = head.angle + (0 if f.facing > 0 else math.pi)
        want = math.atan2(gy - hy, gx - hx)
        err = (want - heading + math.pi) % (2 * math.pi) - math.pi
        # positive err = turn left (counter-clockwise): bend the body so the head yaws left
        f.turn += (max(-0.6, min(0.6, err)) - f.turn) * min(1.0, dt * 2.0)
        f.out = not self.in_water(hx, hy)
        if f.stun > 0 or f.out:
            return
        # muscle thrust along the head, pulsing with the tail beat; relative to the water
        ux, uy = self.fluid.vel(hx, hy)
        hdx, hdy = math.cos(heading), math.sin(heading)
        vrel = (head.linearVelocity[0] * U - ux) * hdx + (head.linearVelocity[1] * U - uy) * hdy
        cruise = 170.0 * C['thrust']
        if vrel < cruise:
            beat = 0.6 + 0.4 * abs(math.sin(f.t * 2 * math.pi * C['swim_hz']))
            F = f.spec.mass * 900.0 * beat * (1 - max(vrel, 0) / cruise)
            self.pending.append((head, (F * hdx / U, F * hdy / U), None))
        f.out = not self.in_water(hx, hy)
        if f.stun > 0 or f.out:
            return
        # muscle thrust along the head, pulsing with the tail beat; relative to the water
        ux, uy = self.fluid.vel(hx, hy)
        hdx, hdy = math.cos(heading), math.sin(heading)
        vrel = (head.linearVelocity[0] * U - ux) * hdx + (head.linearVelocity[1] * U - uy) * hdy
        cruise = 170.0 * C['thrust']
        if vrel < cruise:
            beat = 0.6 + 0.4 * abs(math.sin(f.t * 2 * math.pi * C['swim_hz']))
            F = f.spec.mass * 900.0 * beat * (1 - max(vrel, 0) / cruise)
            self.pending.append((head, (F * hdx / U, F * hdy / U), None))

    def muscles(self, f, dt):
        sp = f.spec
        for jj in f.joints:
            if jj.broken: continue
            a, b = jj.a, jj.b
            head_attached = self.connected_to_head(f, b)
            alive = f.alive and head_attached and jj.kind != "fin"
            if jj.kind == "fin":
                hz, tgt = 3.0, math.sin(f.t * 7 + jj.s * 9) * 0.25
            elif alive and f.stun <= 0 and not getattr(f, 'out', False):
                idx = jj.s
                tgt = math.radians(sp.__dict__.get('amp', C['swim_amp'])) * (0.35 + idx) * math.sin(f.t * 2 * math.pi * C['swim_hz'] - idx * 5.5)
                tgt += -f.turn * 0.5 * f.facing
                hz = C['muscle_hz']
            elif alive or (f.dying > 0 and jj.kind != "fin"):  # also: out of water  # stunned or dying: violent flopping
                tgt = math.radians(36) * math.sin(f.t * 2 * math.pi * 3.2 - jj.s * 2.5) * (0.6 + 0.4 * math.sin(f.t * 1.7))
                hz = C['muscle_hz']
            else:
                tgt, hz = 0.0, C['limp_hz']
            jj.target = tgt
            ba, bb = a.body, b.body
            rel = bb.angle - ba.angle
            relw = bb.angularVelocity - ba.angularVelocity
            th = rel * f.facing
            ia = joint_inertia(ba, jj.j.anchorA); ib = joint_inertia(bb, jj.j.anchorB)
            ieff = ia * ib / (ia + ib)
            w = 2 * math.pi * hz
            tau = ieff * (w * w * (tgt - th) - 2 * C['damp'] * w * relw * f.facing) * f.facing
            ba.ApplyTorque(-tau / (U * U), True)
            bb.ApplyTorque(tau / (U * U), True)

    def connected_to_head(self, f, part):
        # BFS over unbroken joints from the head
        head = f.parts[0]
        seen = {id(head)}; stack = [head]
        while stack:
            p = stack.pop()
            if p is part: return True
            for jj in f.joints:
                if jj.broken: continue
                for q, r in ((jj.a, jj.b), (jj.b, jj.a)):
                    if q is p and id(r) not in seen:
                        seen.add(id(r)); stack.append(r)
        return part is head

    def couple(self, p, dt):
        b = p.body
        fl = self.fluid
        cx, cy = b.worldCenter[0] * U, b.worldCenter[1] * U
        m = p.mass
        inwater = self.in_water(cx, cy)
        buoy = 1.0 if (p.fish.alive and p.kind not in ("gore", "scrap")) else 0.92
        if not inwater:
            self.pending.append((b, (0, -m * G / U), None))
            return
        self.pending.append((b, (0, -m * G * (1 - buoy) / U), None))
        ang = b.angle
        ca, sa = math.cos(ang), math.sin(ang)
        tx, ty = 0.0, 0.0
        per = p.perimeter
        for (p0, p1) in p.edges:
            fac = 1 if getattr(p, 'facing_free', False) else p.fish.facing
            mxl, myl = (p0[0] + p1[0]) * 0.5 * fac, (p0[1] + p1[1]) * 0.5
            ex, ey = (p1[0] - p0[0]) * fac, p1[1] - p0[1]
            elen = math.hypot(ex, ey)
            if elen < 1e-3: continue
            wx = b.position[0] * U + mxl * ca - myl * sa
            wy = b.position[1] * U + mxl * sa + myl * ca
            nx, ny = (ex * sa + ey * ca) / elen, -(ex * ca - ey * sa) / elen
            if fac < 0: nx, ny = -nx, -ny
            vb = b.GetLinearVelocityFromWorldPoint(b2v(wx, wy))
            ux, uy = fl.vel(wx, wy)
            rx, ry = ux - vb[0] * U, uy - vb[1] * U
            vn = rx * nx + ry * ny
            vtx, vty = rx - vn * nx, ry - vn * ny
            # relaxation drag: a flat side facing the flow catches it fast, skin friction is slow
            share = m * elen / per
            kn = C['inv_tau_n'] if vn < 0 else C['inv_tau_n'] * 0.15
            fx = share * (kn * vn * nx + C['inv_tau_t'] * vtx)
            fy = share * (kn * vn * ny + C['inv_tau_t'] * vty)
            self.pending.append((b, (fx / U, fy / U), b2v(wx, wy)))
            tx += fx; ty += fy
        # wake: equal and opposite push into the water, no obstacle
        fl.splat(cx, cy, -tx * C['wake'] * dt, -ty * C['wake'] * dt, 28)

    def check_breaks(self, dt):
        inv = 1.0 / (dt / 4)
        for f in self.fish:
            f.grace = max(0.0, getattr(f, 'grace', 0.0) - dt)
            worst, worst_r = None, 0.0
            for jj in f.joints:
                if jj.broken:
                    if jj.bleed > 0:
                        x, y = jj.where
                        jj.where = self.joint_pos(jj)
                        self.fluid.splat(x, y, 0, 0, 22, dye=jj.bleed * dt * 3)
                        jj.bleed *= math.exp(-dt / 3.0)
                    continue
                F = jj.j.GetReactionForce(inv).length * U  # -> units
                T = abs(jj.j.GetReactionTorque(inv)) * U * U
                lim = C['break_force'] * f.spec.mass
                jj.damage = getattr(jj, 'damage', 0.0) * math.exp(-dt / 1.5)
                if F > lim * 0.35:
                    f.stun = max(f.stun, 1.8)
                if F > lim * 1.2:
                    jj.damage += (F - lim * 1.2) / (lim * 0.8)
                r = max(F / (lim * 2.0), getattr(jj, 'damage', 0.0))
                if r > 1.0 and r > worst_r:
                    worst, worst_r = jj, r
            # one break per fish per step: the rest of the body gets the load relieved
            if worst is not None and f.grace <= 0:
                self.break_joint(f, worst)
                f.grace = 0.12
                for jj in f.joints:
                    if not jj.broken: jj.damage = min(getattr(jj, 'damage', 0.0), 0.6)

    def rip_apart(self, f, jj):
        # same as Fish.RipApart: yank the halves apart, spin them, throw scraps
        a = jj.a.body.angle
        ax, ay = -f.facing * math.cos(a), -f.facing * math.sin(a)
        sx, sy = -ay, ax
        pop = 120.0 if jj.kind == 'fin' else 300.0
        lat = (random.random() - 0.5) * 160
        for piece, d in ((self.piece_of(f, jj.a), -1), (self.piece_of(f, jj.b), 1)):
            spin = d * math.radians(150 + random.random() * 250) * random.choice((-1, 1))
            for p in piece:
                kx, ky = ax * pop * d + sx * lat * d, ay * pop * d + sy * lat * d
                p.body.ApplyLinearImpulse((kx * p.mass / U, ky * p.mass / U), p.body.worldCenter, True)
                p.body.angularVelocity += spin
        if jj.kind == 'fin': return
        for i in range(2 + random.randint(0, 1)):
            off = (random.random() - 0.5) * f.spec.H * 1.2
            x, y = jj.where[0] + sx * off, jj.where[1] + sy * off
            r0 = 6 + f.spec.H * 0.16
            pts = []
            for k in range(7):
                ang = k * 2 * math.pi / 7; r = r0 * (0.7 + random.random() * 0.5)
                pts.append((math.cos(ang) * r * 1.7, math.sin(ang) * r * 0.6))
            body = self.world.CreateDynamicBody(position=b2v(x, y), angle=random.random() * 6.28, angularDamping=0.8)
            fd = b2FixtureDef(shape=b2PolygonShape(vertices=[(px / U, py / U) for px, py in pts]), density=0.015 / (abs(poly_area(pts)) / (U * U)), friction=0.5)
            fd.filter.groupIndex = jj.a.body.fixtures[0].filterData.groupIndex
            body.CreateFixture(fd)
            vx = sx * (random.random() - 0.5) * 500 + ax * (random.random() - 0.5) * 300
            vy = sy * (random.random() - 0.5) * 500 + ay * (random.random() - 0.5) * 300
            body.linearVelocity = (jj.a.body.linearVelocity[0] + vx / U, jj.a.body.linearVelocity[1] + vy / U)
            part = Part(body, 'scrap', mass=0.015); part.fish = f; part.poly = pts
            part.edges = poly_edges(pts); part.perimeter = sum(math.hypot(e[1][0] - e[0][0], e[1][1] - e[0][1]) for e in part.edges)
            part.facing_free = True
            f.parts.append(part)

    def joint_pos(self, jj):
        a = jj.a.body
        lx, ly = jj.local
        w = a.GetWorldPoint(b2v(lx * jj.a.fish.facing, ly))
        return w[0] * U, w[1] * U

    def break_joint(self, f, jj):
        jj.where = self.joint_pos(jj)
        self.world.DestroyJoint(jj.j)
        jj.broken = True
        jj.torn_at = self.t
        jj.seed = random.randint(1, 99999)
        self.rip_apart(f, jj)
        jj.bleed = 1.0 if jj.kind != "fin" else 0.25
        x, y = jj.where
        self.fluid.splat(x, y, 0, 0, 30, dye=2.5 if jj.kind != "fin" else 0.6)
        if f.alive and jj.kind == "spine":
            n = f.spec.nseg
            kept = sum(1 for k in range(1, n) if self.connected_to_head(f, f.parts[k]))
            if kept < (n - 1) * 0.6:
                f.alive = False
                f.dying = 3.5
        self.events.append((self.t, f.spec.name + str(self.fish.index(f)), jj.kind, round(jj.s, 2)))


_AB = (270, -431)
ARCH = [[(_AB[0] + x, _AB[1] + y) for x, y in pc] for pc in [
    [(-120, 0), (-62, 0), (-58, 92), (-112, 100)],
    [(62, 0), (120, 0), (112, 100), (58, 92)],
    [(-112, 100), (-58, 92), (-30, 118), (-40, 150), (-96, 150)],
    [(-30, 118), (30, 118), (40, 150), (-40, 150)],
    [(30, 118), (58, 92), (112, 100), (96, 150), (40, 150)]]]


def dist_poly(p, poly):
    if point_in_poly(p[0], p[1], poly): return 0.0, p
    best, bc = 1e9, p
    for i in range(len(poly)):
        a = poly[i]; b = poly[(i + 1) % len(poly)]
        abx, aby = b[0] - a[0], b[1] - a[1]
        t = max(0, min(1, ((p[0] - a[0]) * abx + (p[1] - a[1]) * aby) / max(abx * abx + aby * aby, 1e-6)))
        q = (a[0] + abx * t, a[1] + aby * t)
        d = math.hypot(p[0] - q[0], p[1] - q[1])
        if d < best: best, bc = d, q
    return best, bc


def mark_solid(fl, pts):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    for j in range(NY):
        for i in range(NX):
            x = TANK_L + (i + 0.5) * DX; y = TANK_B + (j + 0.5) * DY
            if point_in_poly(x, y, pts): fl.solid[j, i] = True


def point_in_poly(x, y, pts):
    ins = False
    for i in range(len(pts)):
        x0, y0 = pts[i]; x1, y1 = pts[(i + 1) % len(pts)]
        if (y0 > y) != (y1 > y) and x < (x1 - x0) * (y - y0) / (y1 - y0) + x0: ins = not ins
    return ins
