--[[
	Spec
	==========================================================================
	Exercises the real FlightConfig / PlanetController / LandingController /
	FlightController sources against the stub planet in Prelude.

	Run:  python3 tests/harness.py [path/to/luau]

	Scope: pure logic only -- geometry, phase thresholds, the landing gate and
	the flight integrator. Anything involving Instances, rendering or
	replication is Studio's job and is not covered here.
]]

local SHIP = FlightConfig.Ship
local PHASES = FlightConfig.Phases
local LANDING = FlightConfig.Landing
local RADIUS = FlightConfig.Planet.Radius

World.Radius = RADIUS

local function up(altitude)
	-- A point straight above the planet's north pole.
	return Vector3.new(0, RADIUS + altitude, 0)
end

--------------------------------------------------------------------------
section("PlanetController: geometry")
--------------------------------------------------------------------------
near("altitude at the surface is 0", PlanetController.GetAltitude(up(0)), 0, 1e-6)
near("altitude 2500 studs up", PlanetController.GetAltitude(up(2500)), 2500, 1e-6)
near("up vector at the pole is +Y", PlanetController.GetUpVector(up(100)).Y, 1, 1e-9)
near("down vector at the pole is -Y", PlanetController.GetDownVector(up(100)).Y, -1, 1e-9)

local spawn = PlanetController.GetSpawnCFrame()
near("spawn altitude matches config", PlanetController.GetAltitude(spawn.Position), FlightConfig.Spawn.Altitude, 1e-3)
check(
	"spawn is pointed at the planet",
	spawn.LookVector:Dot((FlightConfig.Planet.Center - spawn.Position).Unit) > 0.999,
	"look vector is not aimed at the centre"
)
near("spawn basis is orthonormal", spawn.LookVector:Dot(spawn.UpVector), 0, 1e-6)
near("spawn look vector is unit length", spawn.LookVector.Magnitude, 1, 1e-6)

--------------------------------------------------------------------------
section("PlanetController: flight phases")
--------------------------------------------------------------------------
check("far out is SPACE", PlanetController.GetPhase(PHASES.Approach + 1) == Protocol.State.Space)
check("inside approach band is PLANET APPROACH", PlanetController.GetPhase(PHASES.Atmosphere + 1) == Protocol.State.Approach)
check("below the atmosphere line is ATMOSPHERE", PlanetController.GetPhase(PHASES.Atmosphere - 1) == Protocol.State.Atmosphere)
check("at the surface is ATMOSPHERE", PlanetController.GetPhase(0) == Protocol.State.Atmosphere)

near("atmosphere factor is 0 at the boundary", PlanetController.GetAtmosphereFactor(PHASES.Atmosphere), 0, 1e-9)
near("atmosphere factor is 1 at the surface", PlanetController.GetAtmosphereFactor(0), 1, 1e-9)
near("atmosphere factor is 0 out in space", PlanetController.GetAtmosphereFactor(PHASES.Approach), 0, 1e-9)

-- The ramp must be monotonic, or effects would flicker on a steady descent.
local monotonic = true
local previous = -1
for altitude = PHASES.Atmosphere, 0, -25 do
	local factor = PlanetController.GetAtmosphereFactor(altitude)
	if factor < previous - 1e-9 then monotonic = false end
	previous = factor
end
check("atmosphere factor rises monotonically on descent", monotonic)

near("approach factor is 0 at the approach line", PlanetController.GetApproachFactor(PHASES.Approach), 0, 1e-9)
near("approach factor is 1 at the atmosphere line", PlanetController.GetApproachFactor(PHASES.Atmosphere), 1, 1e-9)

--------------------------------------------------------------------------
section("PlanetController: surface probes")
--------------------------------------------------------------------------
World.SurfaceOffset = 0
World.NormalTilt = 0

local probe = PlanetController.ProbeSurface(up(400))
check("probe finds ground below the ship", probe ~= nil)
if probe then
	near("probe distance equals altitude over flat ground", probe.Distance, 400, 0.5)
	near("probe reports a flat slope", probe.Slope, 0, 0.01)
end

check("a point above ground is not inside terrain", PlanetController.IsInsideTerrain(up(50)) == false)
check("a point below the surface is inside terrain", PlanetController.IsInsideTerrain(up(-50)) == true)

--------------------------------------------------------------------------
section("LandingController: the landing gate")
--------------------------------------------------------------------------
local slow = Vector3.new(0, -10, 0)
local fast = Vector3.new(0, -(LANDING.MaxSpeed + 50), 0)

local function at(altitude)
	return CFrame.new(up(altitude))
end

check(
	"rejected above the landing ceiling",
	LandingController.Evaluate(at(PHASES.Landing + 10), slow).Reason == "TOO HIGH"
)
check(
	"rejected when flying too fast",
	LandingController.Evaluate(at(100), fast).Reason == "TOO FAST"
)
check(
	"rejected when too high above the ground",
	LandingController.Evaluate(at(LANDING.MaxGroundDistance + 50), slow).Reason == "TOO HIGH"
)

World.NormalTilt = LANDING.MaxSlope + 10
check(
	"rejected on ground steeper than MaxSlope",
	LandingController.Evaluate(at(100), slow).Reason == "TERRAIN TOO STEEP"
)

World.NormalTilt = 0
local approved = LandingController.Evaluate(at(100), slow)
check("approved when slow, low and level", approved.CanLand == true, approved.Reason)

check(
	"rejected from underneath the terrain",
	LandingController.Evaluate(at(-20), slow).CanLand == false
)

--------------------------------------------------------------------------
section("LandingController: resting pose")
--------------------------------------------------------------------------
World.NormalTilt = 0
local surface = PlanetController.ProbeSurface(up(100))
local heading = CFrame.lookAt(up(100), up(100) + Vector3.new(0, 0, -1), Vector3.new(0, 1, 0))
local resting = LandingController.BuildLandingCFrame(surface, heading)

near(
	"ship rests RestHeight above the surface",
	PlanetController.GetAltitude(resting.Position),
	LANDING.RestHeight,
	0.01
)
near("ship's belly is flat to the ground", resting.UpVector:Dot(surface.Normal), 1, 1e-6)
near("ship keeps its heading", resting.LookVector:Dot(Vector3.new(0, 0, -1)), 1, 1e-6)
near("resting basis stays orthonormal", resting.LookVector:Dot(resting.UpVector), 0, 1e-6)

--------------------------------------------------------------------------
section("FlightController: input conventions")
--------------------------------------------------------------------------
local function newShip(cf)
	return FlightController.new(cf or CFrame.new(up(5000)), SHIP)
end

local function makeInput(overrides)
	local input = {
		Forward = 0, Backward = 0, Yaw = 0, Pitch = 0, Roll = 0,
		MouseDelta = Vector2.new(0, 0), Boost = false,
	}
	for key, value in overrides do input[key] = value end
	return input
end

local vacuum = { AtmosphereFactor = 0, GravityDirection = Vector3.new(0, -1, 0) }

-- Start facing -Z (Roblox's default forward) and confirm each axis turns the
-- way the control scheme promises.
local function facingForward()
	return CFrame.fromMatrix(Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1))
end

local yawShip = newShip(facingForward())
yawShip:SetInput(makeInput({ Yaw = 1 }))
for _ = 1, 60 do yawShip:Step(1 / 60, vacuum) end
check("A yaws the nose to the left (+X side falls back)", yawShip.CFrame.LookVector.X < -0.1,
	string.format("look = %s", tostring(yawShip.CFrame.LookVector)))

local pitchShip = newShip(facingForward())
pitchShip:SetInput(makeInput({ Pitch = 1 }))
for _ = 1, 60 do pitchShip:Step(1 / 60, vacuum) end
check("arrow-up pitches the nose up", pitchShip.CFrame.LookVector.Y > 0.1,
	string.format("look = %s", tostring(pitchShip.CFrame.LookVector)))

local mouseShip = newShip(facingForward())
mouseShip:SetInput(makeInput({ MouseDelta = Vector2.new(0, -6) }))
for _ = 1, 60 do mouseShip:Step(1 / 60, vacuum) end
check("mouse up pitches the nose up", mouseShip.CFrame.LookVector.Y > 0.1,
	string.format("look = %s", tostring(mouseShip.CFrame.LookVector)))

local rollShip = newShip(facingForward())
rollShip:SetInput(makeInput({ Roll = 1 }))
for _ = 1, 30 do rollShip:Step(1 / 60, vacuum) end
check("Q rolls the ship", math.abs(rollShip.CFrame.UpVector.Y - 1) > 0.01)

--------------------------------------------------------------------------
section("FlightController: acceleration and limits")
--------------------------------------------------------------------------
local ship = newShip()
ship:SetInput(makeInput({ Forward = 1 }))

local timeToNinety = nil
for frame = 1, 60 * 30 do
	ship:Step(1 / 60, vacuum)
	if not timeToNinety and ship:GetSpeed() >= SHIP.MaxSpeed * 0.9 then
		timeToNinety = frame / 60
	end
end

check("throttle reaches full", ship.Throttle > 0.99)
check(
	"terminal speed settles just under MaxSpeed",
	ship:GetSpeed() > SHIP.MaxSpeed * 0.85 and ship:GetSpeed() <= SHIP.MaxSpeed + 1e-6,
	string.format("terminal speed %.1f of max %.0f", ship:GetSpeed(), SHIP.MaxSpeed)
)
check(
	"reaches 90% of max speed in a playable time",
	timeToNinety ~= nil and timeToNinety < 12,
	timeToNinety and string.format("%.1fs", timeToNinety) or "never reached"
)
print(string.format("        (90%% of max speed after %.1fs, terminal %.0f studs/s)", timeToNinety or -1, ship:GetSpeed()))

-- Boost must actually exceed the unboosted ceiling.
local boosted = newShip()
boosted:SetInput(makeInput({ Forward = 1, Boost = true }))
for _ = 1, 60 * 40 do boosted:Step(1 / 60, vacuum) end
check(
	"boost raises the speed ceiling",
	boosted:GetSpeed() > SHIP.MaxSpeed * 1.5,
	string.format("boosted to %.0f", boosted:GetSpeed())
)

-- Coasting must bleed off, but slowly enough to feel like vacuum.
local coasting = newShip()
coasting.Velocity = Vector3.new(0, 0, -SHIP.MaxSpeed)
coasting:SetInput(makeInput({}))
for _ = 1, 60 * 5 do coasting:Step(1 / 60, vacuum) end
check(
	"coasting keeps most of its speed for 5s in vacuum",
	coasting:GetSpeed() > SHIP.MaxSpeed * 0.6,
	string.format("%.0f after 5s", coasting:GetSpeed())
)

-- The same coast inside the atmosphere must decay much faster.
local air = { AtmosphereFactor = 1, GravityDirection = Vector3.new(0, -1, 0) }
local inAir = newShip()
inAir.Velocity = Vector3.new(0, 0, -SHIP.AtmosphereSpeedCap)
inAir:SetInput(makeInput({}))
for _ = 1, 60 * 5 do inAir:Step(1 / 60, air) end
check(
	"the atmosphere bleeds speed noticeably faster than vacuum",
	inAir:GetSpeed() < coasting:GetSpeed() * 0.8,
	string.format("air %.0f vs vacuum %.0f", inAir:GetSpeed(), coasting:GetSpeed())
)

--------------------------------------------------------------------------
section("FlightController: numerical stability")
--------------------------------------------------------------------------
-- 10,000 frames of hard manoeuvring: the basis must stay orthonormal and no
-- value may go non-finite.
local stress = newShip()
local worstOrthogonality, worstUnit = 0, 0
local finite = true

for frame = 1, 10000 do
	stress:SetInput(makeInput({
		Forward = 1,
		Yaw = math.sin(frame / 37),
		Pitch = math.cos(frame / 23),
		Roll = math.sin(frame / 11),
		Boost = (frame % 200) < 100,
	}))
	stress:Step(1 / 60, frame % 2 == 0 and vacuum or air)

	local cf = stress.CFrame
	worstOrthogonality = math.max(worstOrthogonality, math.abs(cf.LookVector:Dot(cf.UpVector)))
	worstUnit = math.max(worstUnit, math.abs(cf.LookVector.Magnitude - 1))

	local p = cf.Position
	if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z then finite = false end
	if stress:GetSpeed() ~= stress:GetSpeed() then finite = false end
end

check("no NaN after 10,000 frames of hard manoeuvring", finite)
check(
	"basis stays orthogonal (no skew drift)",
	worstOrthogonality < 1e-6,
	string.format("worst dot = %.3e", worstOrthogonality)
)
check(
	"basis stays unit length (no scale drift)",
	worstUnit < 1e-6,
	string.format("worst error = %.3e", worstUnit)
)

-- A long frame hitch must not teleport the ship across the system.
local hitch = newShip()
hitch.Velocity = Vector3.new(0, 0, -SHIP.MaxSpeed)
local before = hitch.CFrame.Position
hitch:SetInput(makeInput({ Forward = 1 }))
hitch:Step(5.0, vacuum) -- a five second stall
check(
	"a 5s frame hitch is clamped, not integrated",
	(hitch.CFrame.Position - before).Magnitude < SHIP.MaxSpeed * 0.1,
	string.format("moved %.0f studs", (hitch.CFrame.Position - before).Magnitude)
)

--------------------------------------------------------------------------
section("End to end: space -> approach -> atmosphere -> landing")
--------------------------------------------------------------------------
-- Fly the actual spawn pose to the actual planet with the actual config and
-- confirm the intended experience is reachable, and how long each leg takes.
World.SurfaceOffset = 0
World.NormalTilt = 0

local VERBOSE = false

local pilot = FlightController.new(PlanetController.GetSpawnCFrame(), SHIP)
local phaseTimes = {}
local lastPhase = nil
local elapsed = 0
local landedAt = nil
local deepestBreach = 0

for frame = 1, 60 * 400 do
	local position = pilot.CFrame.Position
	local altitude = PlanetController.GetAltitude(position)
	local factor = PlanetController.GetAtmosphereFactor(altitude)

	local phase = PlanetController.GetPhase(altitude)
	if phase ~= lastPhase then
		phaseTimes[phase] = elapsed
		lastPhase = phase
	end

	-- A rough autopilot standing in for a player: boost out in the black,
	-- cruise on the approach, then brake on reverse thrust once the
	-- atmosphere starts biting, exactly as the HUD prompts you to.
	local throttle, reverse = 1, 0
	if altitude < PHASES.Atmosphere then
		throttle = 0
		if pilot:GetSpeed() > LANDING.MaxSpeed * 0.7 then
			reverse = 1
		end
	end

	pilot:SetInput(makeInput({
		Forward = throttle,
		Backward = reverse,
		Boost = altitude > PHASES.Approach,
	}))
	pilot:Step(1 / 60, {
		AtmosphereFactor = factor,
		GravityDirection = PlanetController.GetDownVector(position),
	})

	-- The same collision response FlightClient applies every frame.
	local corrected, velocity = PlanetController.ResolveGroundContact(
		pilot.CFrame.Position,
		pilot.Velocity,
		LANDING.RestHeight
	)
	deepestBreach = math.min(deepestBreach, PlanetController.GetAltitude(pilot.CFrame.Position))
	pilot:SetPosition(corrected)
	pilot.Velocity = velocity

	elapsed += 1 / 60

	if VERBOSE and frame % 120 == 0 then
		local ev = LandingController.Evaluate(pilot.CFrame, pilot.Velocity)
		print(string.format("        t=%5.1fs alt=%9.0f spd=%6.0f  %s",
			elapsed, altitude, pilot:GetSpeed(), ev.Reason))
	end

	local evaluation = LandingController.Evaluate(pilot.CFrame, pilot.Velocity)
	if evaluation.CanLand then
		landedAt = elapsed
		break
	end
end

check("SPACE phase entered at spawn", phaseTimes[Protocol.State.Space] ~= nil)
check("PLANET APPROACH is reached by flying", phaseTimes[Protocol.State.Approach] ~= nil)
check("ATMOSPHERE is reached by flying", phaseTimes[Protocol.State.Atmosphere] ~= nil)
check("a landing becomes available without any teleport", landedAt ~= nil,
	"never satisfied the landing gate within 400s")

if landedAt then
	print("")
	print(string.format("        spawn -> approach     %5.1fs", phaseTimes[Protocol.State.Approach] or -1))
	print(string.format("        spawn -> atmosphere   %5.1fs", phaseTimes[Protocol.State.Atmosphere] or -1))
	print(string.format("        spawn -> can land     %5.1fs", landedAt))
	check("the whole descent takes between 30s and 4 minutes",
		landedAt > 30 and landedAt < 240,
		string.format("%.0fs", landedAt))
end

check(
	"ground contact keeps the ship out of the planet on a fast dive",
	deepestBreach > -LANDING.RestHeight,
	string.format("sank %.1f studs below the surface", -deepestBreach)
)

--------------------------------------------------------------------------
print("")
print(string.rep("=", 60))
print(string.format("  %d passed, %d failed", passed, failed))
print(string.rep("=", 60))
if failed > 0 then
	error(string.format("%d check(s) failed", failed), 0)
end
