--[[
	PlanetController
	==========================================================================
	All planet geometry: where the planet is, how far the ship is from it,
	which flight phase that distance implies, and where the ground is.

	Shared by the client (for visuals and prediction) and the server (for
	authority), so both sides always agree on the numbers. This is the module
	that will grow a planet *registry* when the prototype gains more than one
	world -- every function here already takes an explicit position, so the
	only change needed is choosing which planet to measure against.
]]

local Workspace = game:GetService("Workspace")

local FlightConfig = require(script.Parent:WaitForChild("FlightConfig"))
local Protocol = require(script.Parent:WaitForChild("Protocol"))

local PlanetController = {}

local PLANET_CFG = FlightConfig.Planet
local PHASES = FlightConfig.Phases

--------------------------------------------------------------------------
-- Instance lookup (cached)
--------------------------------------------------------------------------
local planetModel: Model? = nil
local raycastParams: RaycastParams? = nil

--- Returns the planet Model, waiting for it on first call.
function PlanetController.GetPlanet(): Model
	if planetModel and planetModel.Parent then
		return planetModel
	end
	planetModel = Workspace:WaitForChild("Planet") :: Model
	raycastParams = nil -- rebuild the filter against the new model
	return planetModel
end

--- Raycast params that hit ONLY the planet: its terrain crust and the
--- sphere underneath. Everything else (ships, characters, debris) is
--- invisible to surface probes, so no filter juggling is needed per call.
local function getParams(): RaycastParams
	if raycastParams then
		return raycastParams
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain, PlanetController.GetPlanet() }
	params.IgnoreWater = false
	raycastParams = params
	return params
end

--------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------
function PlanetController.GetCentre(): Vector3
	return PLANET_CFG.Center
end

function PlanetController.GetRadius(): number
	return PLANET_CFG.Radius
end

--- Distance from a world position to the planet's centre.
function PlanetController.GetDistanceToCentre(position: Vector3): number
	return (position - PLANET_CFG.Center).Magnitude
end

--- Distance above the planet's *ideal* surface (the sphere). This is the
--- number the HUD calls ALTITUDE and the number every phase threshold is
--- measured against. It can be slightly wrong over a tall mountain -- that
--- is what GroundDistance (the raycast) is for.
function PlanetController.GetAltitude(position: Vector3): number
	return PlanetController.GetDistanceToCentre(position) - PLANET_CFG.Radius
end

--- Local "up" at a world position: straight away from the planet's centre.
function PlanetController.GetUpVector(position: Vector3): Vector3
	local delta = position - PLANET_CFG.Center
	if delta.Magnitude < 1e-3 then
		return Vector3.yAxis
	end
	return delta.Unit
end

--- Local "down": the direction gravity would pull if we had spherical gravity.
function PlanetController.GetDownVector(position: Vector3): Vector3
	return -PlanetController.GetUpVector(position)
end

--------------------------------------------------------------------------
-- Flight phases
--------------------------------------------------------------------------
--- The altitude-derived phase. Landing states are layered on top of this by
--- LandingController; this function only answers "where in the sky am I".
function PlanetController.GetPhase(altitude: number): string
	if altitude > PHASES.Approach then
		return Protocol.State.Space
	elseif altitude > PHASES.Atmosphere then
		return Protocol.State.Approach
	end
	return Protocol.State.Atmosphere
end

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

--- 0 at the atmosphere boundary, 1 at the surface. Every atmospheric visual
--- (fog, sky colour, particles, drag, camera shake) is driven by this single
--- ramp so they all move together instead of popping in independently.
function PlanetController.GetAtmosphereFactor(altitude: number): number
	if altitude >= PHASES.Atmosphere then
		return 0
	end
	return smoothstep(1 - (altitude / PHASES.Atmosphere))
end

--- 0 at the approach boundary, 1 at the atmosphere boundary. Drives the very
--- subtle "the planet is getting real" effects that happen before entry.
function PlanetController.GetApproachFactor(altitude: number): number
	if altitude >= PHASES.Approach then
		return 0
	elseif altitude <= PHASES.Atmosphere then
		return 1
	end
	local span = PHASES.Approach - PHASES.Atmosphere
	return smoothstep(1 - ((altitude - PHASES.Atmosphere) / span))
end

--------------------------------------------------------------------------
-- Surface detection
--------------------------------------------------------------------------
export type SurfaceInfo = {
	Position: Vector3,
	Normal: Vector3,
	Distance: number,
	Slope: number,       -- degrees away from local "up"
	Instance: Instance,
}

--- Cast from a position straight "down" toward the planet centre and report
--- what is underneath. Returns nil if nothing was hit within ProbeDepth.
function PlanetController.ProbeSurface(position: Vector3, depth: number?): SurfaceInfo?
	local down = PlanetController.GetDownVector(position)
	local range = depth or FlightConfig.Landing.ProbeDepth
	local result = Workspace:Raycast(position, down * range, getParams())
	if not result then
		return nil
	end

	local up = -down
	-- The angle between the surface normal and local up. 0 = perfectly flat
	-- ground, 90 = a vertical cliff face.
	local slope = math.deg(math.acos(math.clamp(result.Normal:Dot(up), -1, 1)))

	return {
		Position = result.Position,
		Normal = result.Normal,
		Distance = (result.Position - position).Magnitude,
		Slope = slope,
		Instance = result.Instance,
	}
end

--- True if the position is underneath the terrain crust. Used as a cheap
--- sanity check so a landing can never be approved inside a mountain.
function PlanetController.IsInsideTerrain(position: Vector3): boolean
	local up = PlanetController.GetUpVector(position)
	-- Cast upward: if we hit the underside of something on the planet, we
	-- started inside it.
	local result = Workspace:Raycast(position, up * FlightConfig.Landing.ProbeDepth, getParams())
	return result ~= nil
end

--------------------------------------------------------------------------
-- Ground contact
--------------------------------------------------------------------------
--- Stops a ship flying through the planet.
---
--- Returns a corrected position and velocity, plus whatever is underneath.
--- If the ship is already clear of the ground both come back unchanged, so
--- the caller can assign unconditionally.
---
--- This lives here rather than in FlightClient so the flight loop and the
--- test suite exercise the same code: a collision rule that only exists
--- inside a LocalScript is a rule nothing else can check.
function PlanetController.ResolveGroundContact(
	position: Vector3,
	velocity: Vector3,
	clearance: number
): (Vector3, Vector3, SurfaceInfo?)
	local surface = PlanetController.ProbeSurface(position)
	if not surface or surface.Distance >= clearance then
		return position, velocity, surface
	end

	-- Lift back out to the minimum clearance along the surface normal.
	local corrected = surface.Position + surface.Normal * clearance

	-- Cancel only the component of velocity going INTO the ground, so a
	-- glancing pass skims along the surface instead of stopping dead.
	local intoGround = velocity:Dot(surface.Normal)
	if intoGround < 0 then
		velocity -= surface.Normal * intoGround
	end
	velocity *= FlightConfig.Landing.ScrapeFriction

	return corrected, velocity, surface
end

--- A world position on the ideal sphere, given a direction from the centre.
--- Useful for placing things (the spawn point, future landing beacons).
function PlanetController.GetSurfacePoint(direction: Vector3, extraAltitude: number?): Vector3
	local dir = direction.Magnitude > 1e-4 and direction.Unit or Vector3.yAxis
	return PLANET_CFG.Center + dir * (PLANET_CFG.Radius + (extraAltitude or 0))
end

--- Build a CFrame looking along `look` without the degenerate case that
--- CFrame.lookAt hits when the look direction is parallel to the up hint.
--- (Our ship spawns almost directly above the planet and looks straight
--- down, which is exactly that case.)
function PlanetController.LookAlong(position: Vector3, look: Vector3): CFrame
	local forward = look.Unit
	-- Pick a reference "up" that is not parallel to the look direction.
	local reference = math.abs(forward:Dot(Vector3.yAxis)) > 0.95 and Vector3.zAxis or Vector3.yAxis
	local right = forward:Cross(reference)
	if right.Magnitude < 1e-4 then
		right = forward:Cross(Vector3.xAxis)
	end
	right = right.Unit
	local up = right:Cross(forward).Unit
	-- CFrame.fromMatrix takes the BACK vector as its third axis, hence -forward.
	return CFrame.fromMatrix(position, right, up, -forward)
end

--- Where a ship starts: far out along Spawn.Direction, already looking at
--- the planet so the player sees their destination on frame one.
function PlanetController.GetSpawnCFrame(): CFrame
	local dir = FlightConfig.Spawn.Direction.Unit
	local position = PlanetController.GetSurfacePoint(dir, FlightConfig.Spawn.Altitude)
	return PlanetController.LookAlong(position, PLANET_CFG.Center - position)
end

return PlanetController
