# Fishy Flop (s&box)

A side-view fish tank, half full with an open top. Your mouse is a fist. Uppercut a fish out
of the water, then keep it in the air with more hits. Every airborne hit adds to the combo,
and hard hits tear the fish apart mid-juggle. There's no story and no score, just a combo
counter and your best.

## Open it

1. Copy this `fishflop` folder somewhere s&box can see it.
2. In the s&box editor, use **Open Project** and pick `fishflop.sbproj`.
3. Open `Assets/scenes/tank.scene` and press Play.

The scene's physics mode is **2D** (`"PhysicsMode": "Physics2D"` in the scene file). That
setting matters: everything runs on s&box's Box2D world in the screen plane, so fish can only
bend side to side in view. They can't twist or roll.

## Controls

| Input | What it does |
|---|---|
| Swing the mouse into a fish | Hit it: the fish takes your fist's speed. Uppercut from below to launch it out of the water |
| Hit it again while it's in the air | Air combo (+1). Normal hits only knock it around, so you can keep a fish up as long as you can |
| Smash it: fast swing with left mouse held | Tears the joint next to where you hit (head, tail, a chunk of body) |
| Move the mouse in the water | The fist drags the water along with it; big swipes throw fish around too |
| Hold left mouse | Clenched fist: hits 25% harder, pushes much more water |
| Right mouse | Punch: a shockwave out from the fist (in the water) |
| R | Refill the tank (fresh fish, clean water) |

A combo ends when the fish lands back in the water, comes to rest, or goes 3 seconds without
a hit. Fish that fly out of the tank land on the stand or the floor and flop there. Any living
fish out of water flops. Fish hitting the surface splash it.

## How it's built

- **Water** (`Fluid.cs`): one continuous velocity field on a 100×52 grid using stable
  fluids (advection plus a pressure solve), with a free surface on top. The water is never
  made of particles. The gravel and the rock arch are solid; the fish are not. Fish read the
  flow through drag and leave a small wake in it, so they never carve a hole in the water.
  Blood is a dye carried by the same flow.
- **Fish** (`Fish.cs`, `FishSpec.cs`): every fish is a set of separate rigid parts:
  - the head and 3–5 body segments, each with a convex hull collider cut from its slice of a
    tapered profile (widest near the head, pinching to a narrow tail root);
  - a forked tail made of two convex lobes on one body;
  - a dorsal fin and a pectoral fin.

  The parts are held by `HingeJoint`s with bend limits. The joints' springs are the muscles:
  - a living fish runs a travelling wave down its spine to swim;
  - a stunned fish flops in whole-body C-bends;
  - a dead fish goes limp.

  Joints build up damage from load spikes and tear when it runs out, at most one per fish per
  physics step, so a hard hit leaves recognisable chunks (a head, a tail section) instead of
  confetti. Every tear dumps blood dye, and the open wound keeps bleeding for a few seconds.
  Pieces stay in the tank and slowly sink to the gravel.
- **Skin** (`TankRenderer.cs`): one continuous outline per connected piece, driven by the part
  transforms and blended across intact joints. It bends smoothly with no gaps at the hinges.
  Where a joint has torn, the skin ends in a flesh cap with the spine showing.
- **Ecosystem**: three fish types (goldie, mackerel, tang), ribbon grass, sword plants and a
  rock arch with a real hole you can fling fish through. There's no food chain on purpose.
- **Supported, no clipping**:
  - plants are rooted below the gravel line and sit behind the fish;
  - every gravel pebble lies under the collision surface;
  - the rock sits on the gravel;
  - the tank stands on a cabinet.

## Tuning

All the feel constants live in `Fish.Tuning` at the top of `Code/Fish.cs`:

| Constant | Controls |
|---|---|
| `InvTauNormal`, `InvTauTangent` | How hard water grabs a fish (side-on vs along the body) |
| `BreakForce` | Joint strength, per unit of fish mass; lower it for more gore |
| `SwimHz`, `SwimAmpDeg`, `MuscleHz` | Swimming and floppiness |
| `Cruise`, `ThrustAccel` | How fast living fish swim |
| `MaxHitSpeed` | Cap on closing speed between fist and fish; also limits launch height |
| `HitStruckShare`, `HitBodyShare` | How much of a hit the struck part takes vs the rest of the fish (kept close, so normal hits barely strain the body) |
| `HitBreakSpeed` | A swing at least this fast tears the joint next to where it lands. In practice that's a fast clenched (left mouse) swing. Slower hits never tear |
| `ImpactBreak`, `StrainStart`, `StrainHealSeconds` | Slams into walls, the floor and other fish: only a single load of `ImpactBreak` × `BreakForce` tears at once. Loads above `StrainStart` leave strain, which heals within a couple of seconds, so knocks can't pile up |

Mouse push strength is in `TankGame.OnFixedUpdate`; the punch is `Fluid.Radial( m, 900f, 110f )`.

## Status: read this

This was written without being run in s&box. The build machine has no Steam login and no GPU,
so I couldn't launch the editor or record gameplay. What was checked:

- Every engine API call was checked by hand against the public s&box engine source (Box2D 2D
  scenes, `HingeJoint` springs, limits and break callbacks, `HullCollider` points,
  `PhysicsFilter`, `SceneCustomObject` + `Graphics.Draw`, `HudPainter`, the `Mouse` and
  `Input` actions).
- The code compiles against stubs with those exact signatures.
- The renderer was run offline on the real `Fish`/`TankRenderer` code with posed fish
  (mid-flop bends, a knocked-off head, a snapped mackerel) to check for gaps and wound caps.
- The physics constants were tuned in a Box2D + grid-fluid prototype of the same model
  (`tools/prototype/`).

What to watch for the first time you press Play:

1. **Nothing draws, or everything is pink.** The custom shader
   (`Assets/shaders/fishflop_vcolor.shader`) failed to compile in your s&box version. Change
   the path in `TankRenderer`'s constructor to `materials/default/vertex_color.vmat` to
   confirm everything else works.
2. **Fish swim backwards or turn the wrong way.** Flip the sign of `target * Facing` in
   `Fish.Muscles`.
3. **Fish never break, or break when you breathe on them.** Adjust `Tuning.BreakForce`.

## Recording the video (combo version)

Uppercut a goldfish out of the water and juggle it with normal swings for a while. Then hold
left mouse and smash it: chunks tear off where you hit, rain back into the tank and bleed
into the water.

## Recording the video (original notes)

Record a normal play session with OBS or Steam's game recording. For a demo clip, open with a
slow stir so the water visibly swirls. Then hold left mouse and swipe a fish hard into the
side glass a few times: it stuns and flops, then tears. The neck usually goes first, so the
head comes off. Finish with a few right-click punches through the blood cloud.
