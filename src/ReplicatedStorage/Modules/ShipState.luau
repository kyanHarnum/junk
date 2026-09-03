--[[
	ShipState
	==========================================================================
	A tiny client-side blackboard.

	FlightClient is the only writer. FlightHUD, CameraController and
	AtmosphereController are readers. Because a ModuleScript is cached per
	environment, every LocalScript that requires this gets the same table,
	which keeps the client scripts decoupled from each other -- no
	LocalScript needs a reference to any other LocalScript.

	(The server never requires this module; its authoritative copy of the
	same information lives in SpaceGameServer.)
]]

local Protocol = require(script.Parent:WaitForChild("Protocol"))

local ShipState = {
	-- Instances
	Ship = nil,             -- Model
	Root = nil,             -- BasePart (Ship.PrimaryPart)

	-- Kinematics
	CFrame = CFrame.new(),
	Velocity = Vector3.zero,
	Speed = 0,
	Throttle = 0,
	Boosting = false,

	-- Position relative to the planet
	Altitude = math.huge,        -- above the planet's ideal surface (sphere)
	DistanceToCentre = math.huge,
	GroundDistance = math.huge,  -- AGL: raycast distance to actual terrain

	-- Phase / state
	Phase = Protocol.State.Space,   -- purely altitude-derived
	State = Protocol.State.Space,   -- what the HUD shows, includes landing states
	AtmosphereFactor = 0,           -- 0..1 ramp used by every visual effect
	ApproachFactor = 0,             -- 0..1 ramp for the early, subtle effects

	-- Landing
	CanLand = false,
	LandBlockReason = "",
	SurfaceInfo = nil,      -- {Position, Normal, Distance, Slope}

	-- Pilot
	Seated = false,
	NearShip = false,
	Ready = false,
}

-- Fired whenever State changes, so the HUD can flash a transition without
-- diffing strings every frame.
ShipState.StateChanged = Instance.new("BindableEvent")

function ShipState.SetState(newState: string)
	if ShipState.State == newState then
		return
	end
	local old = ShipState.State
	ShipState.State = newState
	ShipState.StateChanged:Fire(newState, old)
end

return ShipState
