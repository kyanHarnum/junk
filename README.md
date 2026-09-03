# Space Exploration Prototype

A playable vertical slice of a No Man's Sky-style exploration loop in Roblox:
start in deep space, fly toward a planet, watch it grow, enter the
atmosphere, descend through the weather, land manually, and step out onto
the surface — with no loading screen and no teleport anywhere in the chain.

Roughly a minute of continuous flight from spawn to touchdown at the default
tuning:

| Leg | Distance | Time |
| --- | --- | --- |
| `SPACE` → `PLANET APPROACH` | 18,000 studs | ~13s |
| `PLANET APPROACH` → `ATMOSPHERE` | 9,400 studs | ~15s |
| `ATMOSPHERE` → landing prompt | 1,800 studs | ~25s |

Those numbers are measured, not estimated — `tests/Spec.luau` flies the real
config with the real flight model and asserts them.

---

## Running it

**With Rojo** (recommended — everything stays in git as text):

```bash
rojo serve          # then connect from the Rojo plugin in Studio
# or build a place file:
rojo build -o prototype.rbxlx
```

**Without Rojo:** create the instances by hand and paste the file contents
in. The tree mirrors `src/` exactly:

| File | Goes in | As |
| --- | --- | --- |
| `src/ReplicatedStorage/Modules/*.luau` | `ReplicatedStorage/Modules` | `ModuleScript` |
| `src/ServerScriptService/*.server.luau` | `ServerScriptService` | `Script` |
| `src/StarterPlayerScripts/*.client.luau` | `StarterPlayer/StarterPlayerScripts` | `LocalScript` |

You do not need to create the `Remotes` folder, the planet, the ship, or
anything in `Workspace` — the server builds all of it at runtime.

One place setting matters: **`Workspace.StreamingEnabled` must be off.** The
flight path spans 30,000 studs and streaming will unload the planet out from
under you.

---

## Controls

| Key | Action |
| --- | --- |
| `W` / `S` | Throttle forward / reverse (reverse is also your brake) |
| `A` / `D` | Yaw left / right |
| Mouse, or `↑` / `↓` | Pitch |
| `Q` / `E` | Roll |
| `Space` | Boost (in flight) · Take off (when landed) |
| `F` | Land, when the prompt offers it |
| `E` | Exit / enter the ship, when landed |

---

## What gets created, and where

### Scripts you install

```
ReplicatedStorage/Modules/
├── FlightConfig       every tunable number in the prototype
├── Protocol           names of every client/server message + the state list
├── PlanetController   planet geometry, phase thresholds, surface raycasting
├── LandingController  the landing gate, the resting pose, the touchdown glide
├── FlightController   the flight model (a pure integrator, no Instances)
├── ShipBuilder        builds the ship out of primitives
└── ShipState          client-side blackboard the UI/camera/effects read

ServerScriptService/
├── PlanetServer       builds the world at startup
└── SpaceGameServer    authority: ships, states, landing validation

StarterPlayer/StarterPlayerScripts/
├── FlightClient       input, integration, ground contact, landing sequence
├── FlightHUD          the cockpit readout
├── CameraController   chase camera, FOV, shake
└── AtmosphereController  sky, fog, bloom, re-entry glow, speed streaks
```

### Instances created at runtime

Nothing below is authored in Studio; `PlanetServer` and `SpaceGameServer`
build it all when the server starts.

```
Workspace/
├── Planet/                      built by PlanetServer
│   ├── Surface                  a 1,800-stud Ball part — the planet body
│   ├── AtmosphereInner          Neon shell, the bright rim of air
│   └── AtmosphereOuter          ForceField shell, the outer haze
├── Terrain                      the walkable cap, written with WriteVoxels
├── Space/
│   ├── Stars/                   260 parallax star parts on a distant shell
│   └── Sun                      a Neon sphere to orient against
└── Ships/
    └── PlayerShip_<UserId>      one per player, built by ShipBuilder

ReplicatedStorage/Remotes/
├── FlightRemote                 continuous pose streaming
└── LandingRemote                discrete, validated actions

Lighting/                        Sky, Atmosphere, Bloom, ColorCorrection
```

---

## How the systems talk to each other

```
                    ┌──────────────────────────────────────┐
                    │  ReplicatedStorage/Modules           │
                    │  FlightConfig · Protocol             │
                    │  PlanetController · LandingController│
                    └───────┬──────────────────┬───────────┘
             required by    │                  │   required by
                            ▼                  ▼
     ┌──────────────────────────┐      ┌────────────────────────┐
     │  CLIENT                  │      │  SERVER                │
     │                          │      │                        │
     │  FlightClient            │      │  SpaceGameServer       │
     │   input → FlightController      │   owns the ship Model  │
     │   → ship pose            │      │   owns the state       │
     │   → ShipState  ──────────┼──┐   │   validates landings   │
     │                          │  │   │                        │
     │  FlightHUD        ◄──────┼──┤   │  PlanetServer          │
     │  CameraController ◄──────┼──┤   │   builds the world     │
     │  AtmosphereController ◄──┼──┘   │                        │
     └──────────┬───────────────┘      └───────────┬────────────┘
                │                                  │
                │  FlightRemote  "Sync" (pose + velocity, 15 Hz)
                ├─────────────────────────────────►│
                │  FlightRemote  "ShipReady" / "StateChanged" / "Correction"
                │◄─────────────────────────────────┤
                │  LandingRemote "RequestLand" / "LandComplete" / "ExitShip" …
                ├─────────────────────────────────►│
                │  LandingRemote "LandApproved" / "LandDenied" / "Landed" …
                │◄─────────────────────────────────┘
```

Three ideas hold this together:

**1. The client flies, the server rules.** Input, integration and rendering
all happen locally at frame rate, because anything else feels like flying
through treacle. The client streams its pose to the server 15 times a
second; the server applies it (so other players see the ship), rejects poses
that imply impossible speed, and is the only thing that can change your
state.

**2. The landing gate is one function, used by both sides.**
`LandingController.Evaluate()` runs on the client every frame to decide
whether to show `LANDING AVAILABLE`, and runs again on the server when you
actually press `F`. Same code, same config, so the prompt never lies — and a
client that skips the prompt and fires the remote by hand still has to pass
the server's copy.

**3. Client scripts share a blackboard, not references.** `FlightClient` is
the only writer to `ShipState`; the HUD, camera and atmosphere scripts only
read it. None of them holds a reference to any other, so any one can be
rewritten or deleted without touching the rest.

### One number drives the whole atmosphere

`PlanetController.GetAtmosphereFactor(altitude)` returns a smoothstepped 0→1
ramp — 0 at the atmosphere boundary, 1 at the surface. Everything keys off
it: fog distance, `ClockTime` (night in space → daylight in the air),
`Atmosphere.Density`, bloom, saturation, drag, the speed cap, gravity,
camera shake, the re-entry glow and the speed streaks. That is why entry
reads as one continuous transition rather than a stack of effects each
popping in at its own threshold.

The re-entry glow and the speed streaks multiply that ramp by **speed**, so
a careful descent is calm and a fast one burns.

---

## Tuning

Every gameplay value lives in `FlightConfig`. Nothing else hard-codes a
number. The ones worth reaching for first:

```lua
FlightConfig.Phases = {
    Approach   = 12000,  -- above this: SPACE
    Atmosphere = 2600,   -- below this: ATMOSPHERE
    Landing    = 800,    -- landing may become available below this
}

FlightConfig.Spawn.Altitude = 30000   -- how long the trip out there is

FlightConfig.Ship = {
    MaxSpeed   = 650,
    LinearDrag = 0.10,   -- low: the ship coasts like it is in vacuum
    LateralDrag = 2.40,  -- high: the ship grips the way it is pointing
}

FlightConfig.Landing = {
    MaxSpeed = 95,            -- must be slower than this to land
    MaxGroundDistance = 300,  -- and no higher than this above the ground
    MaxSlope = 38,            -- degrees; steeper ground refuses the landing
}
```

`LinearDrag` and `LateralDrag` are the two dials that decide how the ship
feels. Velocity is independent of facing — turning does not turn your
momentum — so low forward drag gives you a long vacuum coast, and high
lateral drag gives just enough grip to be flyable instead of sliding like a
puck. Raise `LateralDrag` for arcade, lower it for Newtonian.

After changing anything, re-run the tests.

---

## Tests

```bash
python3 tests/harness.py /path/to/luau
```

The [standalone Luau CLI](https://github.com/luau-lang/luau/releases)
sandboxes its global table, so Roblox globals cannot be injected into a
required module. `tests/harness.py` instead assembles the **real module
sources** into one chunk behind a prelude of stub locals, and runs that. No
module source is rewritten except its `require` lines.

53 checks cover planet geometry, the phase thresholds, surface probing, the
landing gate, the resting pose, control-sign conventions, acceleration
limits, numerical stability, and a full spawn-to-touchdown flight. Stubs
include real `Vector3` and `CFrame` implementations and an analytic
raycastable planet, so the flight integrator is genuinely exercised.

Anything involving Instances, rendering or replication is Studio's job and is
deliberately out of scope.

Two things this suite has already caught that would otherwise have surfaced
only in playtesting: a drag coefficient that bled a full-speed coast down to
17% in five seconds, and a spawn distance that put the entire journey at 17
seconds with `PLANET APPROACH` lasting four of them.

---

## Known limitations

These are deliberate scope calls for a prototype, not oversights.

**You can only land on the north pole cap.** Roblox gravity is a single
global `-Y` vector, so the only part of a spherical planet a character can
stand on is the cap around the pole. The cap is 640 studs across, tilting to
about 21° at its rim, with a flat apron at the centre for your first
landing. Widening `LandingZone.HalfWidth` makes the rim feel steeper, because
the ground is curving away from a gravity vector that does not follow it.
Real spherical gravity means a custom character controller — worth doing, and
a much bigger job than this slice.

**The visible atmosphere shell is capped at 2,048 studs.** That is Roblox's
part size limit, so the glow around the planet is only ~110 studs deep while
the *gameplay* atmosphere band is 2,600. The shell is what the planet looks
like from outside; the band is what you fly through, and it is driven by
`Lighting` rather than geometry. They are tuned independently on purpose.

**The ship is anchored and moved by CFrame, not simulated.** This gives exact
control over the flight feel and sidesteps zero-gravity physics entirely. The
cost is that the ship does not collide with anything except through the
explicit ground probe in `PlanetController.ResolveGroundContact`.

**Other players see your ship at 15 Hz.** Smooth for you, slightly steppy for
them. Interpolating remote ships on the client is the fix, and is a
worthwhile next task if multiplayer matters.

**No audio.** Engine hum and wind rush would do a lot of the work here, but
they need asset IDs, which cannot be created from code.

---

## Where this goes next

The structure is already shaped for these:

- **Multiple planets** — `PlanetController` takes an explicit position in
  every function; it needs a registry and a "nearest planet" query, not a
  rewrite. `FlightConfig.Planet` becomes `FlightConfig.Planets[id]`.
- **Procedural terrain** — `PlanetServer.elevationAt()` is already a seeded
  noise function. Give each planet its own seed and material palette.
- **Fuel, resources, inventory** — the server already owns a per-player
  record and validates every discrete action through one remote handler.
- **Ship upgrades** — `FlightConfig.Ship` is passed into
  `FlightController.new()` as a plain table, so per-player stat blocks need
  no changes to the flight model.
- **Warp / FTL** — a fourth flight state alongside the existing four, and a
  fifth entry in `Protocol.State`.
- **Space stations, base building** — `ShipBuilder` shows the pattern for
  building models from code and keeping them in git as text.
