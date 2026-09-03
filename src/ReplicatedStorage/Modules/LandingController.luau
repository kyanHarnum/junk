--[[
	LandingController
	==========================================================================
	Everything that decides whether a landing is allowed and what a landed
	ship's pose should be.

	Deliberately shared: the CLIENT runs Evaluate() every frame to decide
	whether to show the "LANDING AVAILABLE" prompt, and the SERVER runs the
	exact same function when the player actually presses F. Because they run
	identical code against identical config, the prompt never lies -- and a
	client that skips the prompt entirely and fires the remote by hand still
	has to pass the server's copy of the checks.
]]

local FlightConfig = require(script.Parent:WaitForChild("FlightConfig"))
local PlanetController = require(script.Parent:WaitForChild("PlanetController"))

local LandingController = {}

local LANDING = FlightConfig.Landing
local PHASES = FlightConfig.Phases

export type Evaluation = {
	CanLand: boolean,
	Reason: string,                        -- empty when CanLand is true
	Surface: PlanetController.SurfaceInfo?,
}

--------------------------------------------------------------------------
-- Can this ship land, here, right now?
--------------------------------------------------------------------------
--- Runs every gate in order and reports the FIRST failure, so the HUD can
--- tell the player what to fix ("TOO FAST") instead of just staying silent.
function LandingController.Evaluate(shipCFrame: CFrame, velocity: Vector3): Evaluation
	local position = shipCFrame.Position
	local altitude = PlanetController.GetAltitude(position)

	-- 1. Must be low enough in the atmosphere for landing to be on the table.
	if altitude > PHASES.Landing then
		return { CanLand = false, Reason = "TOO HIGH", Surface = nil }
	end

	-- 2. Must be flying slowly enough to survive the touchdown.
	local speed = velocity.Magnitude
	if speed > LANDING.MaxSpeed then
		return { CanLand = false, Reason = "TOO FAST", Surface = nil }
	end

	-- 3. There must actually be ground underneath.
	local surface = PlanetController.ProbeSurface(position)
	if not surface then
		return { CanLand = false, Reason = "NO SURFACE BELOW", Surface = nil }
	end

	-- 4. And it must be close enough to glide down to.
	if surface.Distance > LANDING.MaxGroundDistance then
		return { CanLand = false, Reason = "TOO HIGH", Surface = surface }
	end

	-- 5. Refuse cliff faces and mountain walls -- the ship would end up
	--    embedded in, or sliding off, the geometry.
	if surface.Slope > LANDING.MaxSlope then
		return { CanLand = false, Reason = "TERRAIN TOO STEEP", Surface = surface }
	end

	-- 6. Never approve a landing from inside a mountain. Cheap guard against
	--    a ship that clipped into terrain during a fast descent.
	if PlanetController.IsInsideTerrain(position) then
		return { CanLand = false, Reason = "OBSTRUCTED", Surface = surface }
	end

	return { CanLand = true, Reason = "", Surface = surface }
end

--------------------------------------------------------------------------
-- Where should the ship end up?
--------------------------------------------------------------------------
--- Builds the resting pose: sitting RestHeight above the ground, its belly
--- flat against the surface normal, keeping as much of the pilot's current
--- heading as the slope allows.
function LandingController.BuildLandingCFrame(
	surface: PlanetController.SurfaceInfo,
	shipCFrame: CFrame
): CFrame
	local up = surface.Normal
	local position = surface.Position + up * LANDING.RestHeight

	-- Project the ship's current facing onto the ground plane so the ship
	-- keeps pointing roughly where the player left it instead of snapping to
	-- an arbitrary compass heading.
	local look = shipCFrame.LookVector
	local flattened = look - up * look:Dot(up)
	if flattened.Magnitude < 1e-3 then
		-- The ship was pointing straight down at the ground; fall back to
		-- its own up vector for a heading.
		flattened = shipCFrame.UpVector - up * shipCFrame.UpVector:Dot(up)
	end
	if flattened.Magnitude < 1e-3 then
		flattened = up:Cross(Vector3.xAxis)
	end
	flattened = flattened.Unit

	local right = flattened:Cross(up).Unit
	-- CFrame.fromMatrix wants the BACK vector third.
	return CFrame.fromMatrix(position, right, up, -flattened)
end

--------------------------------------------------------------------------
-- The touchdown glide
--------------------------------------------------------------------------
--- Eased interpolation for the automatic landing. Slow in, slow out, with a
--- slight bias toward finishing gently so the ship settles rather than
--- slamming into its final pose.
function LandingController.GetSequenceAlpha(elapsed: number): number
	local t = math.clamp(elapsed / LANDING.SequenceTime, 0, 1)
	-- Smootherstep: zero velocity AND zero acceleration at both ends.
	return t * t * t * (t * (t * 6 - 15) + 10)
end

--- One frame of the landing glide. Returns the pose and whether it finished.
--- The ship also arcs slightly upward through the middle of the move so a
--- ship that was descending fast does not scrape through a hill on its way
--- to the pad.
function LandingController.StepSequence(
	startCFrame: CFrame,
	targetCFrame: CFrame,
	elapsed: number
): (CFrame, boolean)
	local alpha = LandingController.GetSequenceAlpha(elapsed)
	local pose = startCFrame:Lerp(targetCFrame, alpha)

	-- Arc: peaks at the midpoint, zero at both ends.
	local arc = math.sin(alpha * math.pi) * (LANDING.RestHeight * 1.5)
	local up = PlanetController.GetUpVector(pose.Position)
	pose = pose + up * arc

	return pose, elapsed >= LANDING.SequenceTime
end

--------------------------------------------------------------------------
-- Getting out
--------------------------------------------------------------------------
--- Finds a safe patch of ground beside the ship for the pilot to stand on.
--- Falls back to the ship's own position if the offset spot has no ground
--- (better to drop the player on the hull than into the void).
function LandingController.GetExitCFrame(shipCFrame: CFrame): CFrame
	local candidate = shipCFrame * CFrame.new(LANDING.ExitOffset)
	local up = PlanetController.GetUpVector(candidate.Position)

	-- Start the probe above the offset point so we do not begin inside a rock.
	local probeStart = candidate.Position + up * 30
	local surface = PlanetController.ProbeSurface(probeStart, 200)

	if not surface then
		probeStart = shipCFrame.Position + up * 30
		surface = PlanetController.ProbeSurface(probeStart, 200)
	end

	local standPosition
	if surface then
		standPosition = surface.Position + surface.Normal * 3.5
	else
		standPosition = shipCFrame.Position + up * 5
	end

	-- Face the pilot toward the ship so stepping out reads as "getting out of"
	-- rather than "spawning next to".
	local toShip = shipCFrame.Position - standPosition
	local flattened = toShip - up * toShip:Dot(up)
	if flattened.Magnitude < 1e-3 then
		return CFrame.new(standPosition)
	end
	return CFrame.lookAt(standPosition, standPosition + flattened.Unit, up)
end

--- Is the player standing close enough to climb back in?
function LandingController.IsWithinBoardingRange(characterPosition: Vector3, shipCFrame: CFrame): boolean
	return (characterPosition - shipCFrame.Position).Magnitude <= LANDING.EnterRadius
end

return LandingController
