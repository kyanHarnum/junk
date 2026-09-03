--[[
	FlightClient
	==========================================================================
	The pilot's hands. Reads input, runs the flight model, moves the ship,
	keeps the pilot's character in the cockpit, probes the ground, runs the
	landing glide, and publishes everything it knows to ShipState so the HUD,
	camera and atmosphere scripts can read it without knowing this script
	exists.

	Runs at render priority Input+10: after Roblox has gathered input, before
	CameraController reads the ship's new pose. That ordering is what stops
	the camera lagging a frame behind the ship.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FlightConfig = require(Modules:WaitForChild("FlightConfig"))
local FlightController = require(Modules:WaitForChild("FlightController"))
local PlanetController = require(Modules:WaitForChild("PlanetController"))
local LandingController = require(Modules:WaitForChild("LandingController"))
local ShipBuilder = require(Modules:WaitForChild("ShipBuilder"))
local ShipState = require(Modules:WaitForChild("ShipState"))
local Protocol = require(Modules:WaitForChild("Protocol"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FlightRemote = Remotes:WaitForChild("FlightRemote") :: RemoteEvent
local LandingRemote = Remotes:WaitForChild("LandingRemote") :: RemoteEvent

local player = Players.LocalPlayer
local SHIP_CFG = FlightConfig.Ship
local LANDING_CFG = FlightConfig.Landing
local PHASES = FlightConfig.Phases
local STATE = Protocol.State

--------------------------------------------------------------------------
-- Local state
--------------------------------------------------------------------------
local controller = nil
local ship: Model? = nil

local keys = {
	Forward = false,
	Backward = false,
	Left = false,
	Right = false,
	PitchUp = false,
	PitchDown = false,
	RollLeft = false,
	RollRight = false,
	Boost = false,
}

local syncAccumulator = 0
local landing = {
	Active = false,
	Elapsed = 0,
	Start = CFrame.new(),
	Target = CFrame.new(),
}

--------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------
local KEY_MAP = {
	[Enum.KeyCode.W] = "Forward",
	[Enum.KeyCode.S] = "Backward",
	[Enum.KeyCode.A] = "Left",
	[Enum.KeyCode.D] = "Right",
	[Enum.KeyCode.Up] = "PitchUp",
	[Enum.KeyCode.Down] = "PitchDown",
	[Enum.KeyCode.Q] = "RollLeft",
	[Enum.KeyCode.E] = "RollRight",
	[Enum.KeyCode.Space] = "Boost",
}

--- True while the player is flying: seated, and not mid-landing.
local function isPiloting(): boolean
	return ShipState.Ready
		and ShipState.Seated
		and ShipState.State ~= STATE.Landed
		and ShipState.State ~= STATE.OnFoot
		and not landing.Active
end

local function requestLanding()
	if not isPiloting() or not ShipState.CanLand then
		return
	end
	LandingRemote:FireServer(Protocol.Landing.RequestLand)
end

local function toggleShipOccupancy()
	if ShipState.State == STATE.Landed and ShipState.Seated then
		LandingRemote:FireServer(Protocol.Landing.ExitShip)
	elseif ShipState.State == STATE.OnFoot and ShipState.NearShip then
		LandingRemote:FireServer(Protocol.Landing.EnterShip)
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local action = KEY_MAP[input.KeyCode]
	if action then
		keys[action] = true
	end

	if input.KeyCode == Enum.KeyCode.F then
		requestLanding()
	elseif input.KeyCode == Enum.KeyCode.E then
		-- E doubles as roll-right while flying and enter/exit when parked.
		if ShipState.State == STATE.Landed or ShipState.State == STATE.OnFoot then
			toggleShipOccupancy()
		end
	elseif input.KeyCode == Enum.KeyCode.Space then
		-- Space is boost in flight and take-off when parked.
		if ShipState.State == STATE.Landed and ShipState.Seated then
			LandingRemote:FireServer(Protocol.Landing.TakeOff)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	local action = KEY_MAP[input.KeyCode]
	if action then
		keys[action] = false
	end
end)

-- Dropping focus (alt-tab, chat) must not leave the throttle stuck on.
UserInputService.WindowFocusReleased:Connect(function()
	for action in keys do
		keys[action] = false
	end
end)

--- The mouse is locked to the screen centre while flying so GetMouseDelta
--- returns steering input; it is released the moment the player is on foot
--- or parked so they can use the normal cursor.
local function updateMouseBehaviour()
	if isPiloting() and SHIP_CFG.MouseSteering then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

--------------------------------------------------------------------------
-- Character
--------------------------------------------------------------------------
--- Locks the pilot's character into the cockpit. Called every frame while
--- seated so the character never lags behind the ship. The server does the
--- same at its lower sync rate for the benefit of other clients.
local function pinCharacterToCockpit(shipCFrame: CFrame)
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root and root.Anchored then
		root.CFrame = shipCFrame * SHIP_CFG.CockpitOffset
	end
end

--------------------------------------------------------------------------
-- Ground clearance
--------------------------------------------------------------------------
--- Stops the ship flying through the planet, and produces the AGL reading
--- the HUD and the landing gate both need.
---
--- Only runs inside the atmosphere: a raycast per frame is cheap, but there
--- is no reason to pay for it while still thousands of studs out in vacuum.
local function updateGroundContact(): PlanetController.SurfaceInfo?
	if ShipState.Altitude > PHASES.Atmosphere then
		ShipState.GroundDistance = math.huge
		return nil
	end

	-- The landing glide flies its own path to the pad and must not be
	-- shoved around by the collision response.
	if landing.Active then
		local surface = PlanetController.ProbeSurface(controller.CFrame.Position)
		ShipState.GroundDistance = surface and surface.Distance or math.huge
		return surface
	end

	local position, velocity, surface = PlanetController.ResolveGroundContact(
		controller.CFrame.Position,
		controller.Velocity,
		LANDING_CFG.RestHeight
	)

	controller:SetPosition(position)
	controller.Velocity = velocity
	ShipState.GroundDistance = surface and surface.Distance or math.huge

	return surface
end

--------------------------------------------------------------------------
-- The frame update
--------------------------------------------------------------------------
local function buildInput(): FlightController.Input
	local mouseDelta = Vector2.zero
	if SHIP_CFG.MouseSteering and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		mouseDelta = UserInputService:GetMouseDelta()
	end

	return {
		Forward = keys.Forward and 1 or 0,
		Backward = keys.Backward and 1 or 0,
		-- Positive yaw is left, matching CFrame.Angles' sign convention.
		Yaw = (keys.Left and 1 or 0) - (keys.Right and 1 or 0),
		Pitch = (keys.PitchUp and 1 or 0) - (keys.PitchDown and 1 or 0),
		Roll = (keys.RollLeft and 1 or 0) - (keys.RollRight and 1 or 0),
		MouseDelta = mouseDelta,
		Boost = keys.Boost,
	}
end

local function updateLandingAvailability()
	if ShipState.State == STATE.Landing or ShipState.State == STATE.Landed or ShipState.State == STATE.OnFoot then
		ShipState.CanLand = false
		ShipState.LandBlockReason = ""
		return
	end

	local evaluation = LandingController.Evaluate(controller.CFrame, controller.Velocity)
	ShipState.CanLand = evaluation.CanLand
	ShipState.LandBlockReason = evaluation.Reason
	ShipState.SurfaceInfo = evaluation.Surface

	-- LANDING AVAILABLE is a display state layered on top of ATMOSPHERE, so
	-- the phase itself stays honest.
	if evaluation.CanLand then
		ShipState.SetState(STATE.LandingAvailable)
	else
		ShipState.SetState(ShipState.Phase)
	end
end

local function stepLandingSequence(dt: number)
	landing.Elapsed += dt

	local pose, finished = LandingController.StepSequence(landing.Start, landing.Target, landing.Elapsed)
	controller:SetCFrame(pose)
	-- Bleed the remaining velocity to zero across the glide rather than
	-- cutting it, so the HUD speed readout winds down instead of snapping.
	controller.Velocity *= math.max(0, 1 - 3 * dt)

	ShipBuilder.ApplyPose(ship, pose)
	pinCharacterToCockpit(pose)

	if finished then
		landing.Active = false
		controller:Halt()
		controller:SetCFrame(landing.Target)
		ShipBuilder.ApplyPose(ship, landing.Target)
		pinCharacterToCockpit(landing.Target)
		LandingRemote:FireServer(Protocol.Landing.LandComplete)
	end
end

local function updateOnFoot()
	-- Walking around: the only thing to track is whether the ship is close
	-- enough to board.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and ship then
		ShipState.NearShip = LandingController.IsWithinBoardingRange(root.Position, ship:GetPivot())
	else
		ShipState.NearShip = false
	end
	ShipState.Speed = 0
	ShipState.Throttle = 0
end

local function onRenderStep(dt: number)
	if not ShipState.Ready or not controller or not ship or not ship.Parent then
		return
	end

	updateMouseBehaviour()

	-- Position relative to the planet: the numbers everything else keys off.
	local position = controller.CFrame.Position
	ShipState.DistanceToCentre = PlanetController.GetDistanceToCentre(position)
	ShipState.Altitude = PlanetController.GetAltitude(position)
	ShipState.AtmosphereFactor = PlanetController.GetAtmosphereFactor(ShipState.Altitude)
	ShipState.ApproachFactor = PlanetController.GetApproachFactor(ShipState.Altitude)
	ShipState.Phase = PlanetController.GetPhase(ShipState.Altitude)

	if landing.Active then
		stepLandingSequence(dt)
		ShipState.CFrame = controller.CFrame
		ShipState.Velocity = controller.Velocity
		ShipState.Speed = controller.Velocity.Magnitude
		return
	end

	if ShipState.State == STATE.OnFoot then
		updateOnFoot()
		return
	end

	if ShipState.State == STATE.Landed then
		-- Parked. Hold the pose; do not integrate.
		controller.Enabled = false
		controller:ClearInput()
		ShipState.Speed = 0
		ShipState.Throttle = 0
		ShipBuilder.SetThrusterIntensity(ship, 0)
		pinCharacterToCockpit(controller.CFrame)
		return
	end

	----------------------------------------------------------------------
	-- Flying.
	----------------------------------------------------------------------
	controller.Enabled = true
	controller:SetInput(buildInput())
	controller:Step(dt, {
		AtmosphereFactor = ShipState.AtmosphereFactor,
		GravityDirection = PlanetController.GetDownVector(position),
	})

	updateGroundContact()

	ShipBuilder.ApplyPose(ship, controller.CFrame)
	pinCharacterToCockpit(controller.CFrame)

	-- Exhaust reacts to forward throttle only; reverse thrusters are not modelled.
	local thrust = math.max(controller.Throttle, 0)
	ShipBuilder.SetThrusterIntensity(ship, controller.Boosting and math.min(thrust * 1.6, 1) or thrust)

	ShipState.CFrame = controller.CFrame
	ShipState.Velocity = controller.Velocity
	ShipState.Speed = controller.Velocity.Magnitude
	ShipState.Throttle = controller.Throttle
	ShipState.Boosting = controller.Boosting

	updateLandingAvailability()

	----------------------------------------------------------------------
	-- Tell the server where we are, at a fixed rate independent of FPS.
	----------------------------------------------------------------------
	syncAccumulator += dt
	if syncAccumulator >= SHIP_CFG.ReplicationRate then
		syncAccumulator = 0
		FlightRemote:FireServer(Protocol.Flight.Sync, controller.CFrame, controller.Velocity)
	end
end

--------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------
FlightRemote.OnClientEvent:Connect(function(kind, a, b)
	if kind == Protocol.Flight.ShipReady then
		ship = a
		ShipState.Ship = a
		ShipState.Root = a.PrimaryPart
		ShipState.CFrame = b
		ShipState.Seated = true
		ShipState.Ready = true

		controller = FlightController.new(b, SHIP_CFG)
		ShipState.SetState(STATE.Space)

	elseif kind == Protocol.Flight.StateChanged then
		-- The server is the authority on the coarse phase. Landing display
		-- states are computed locally each frame, so do not clobber them.
		if a == STATE.Landed or a == STATE.OnFoot then
			ShipState.SetState(a)
			ShipState.Seated = (a == STATE.Landed)
		end

	elseif kind == Protocol.Flight.Correction then
		-- Server rejected our pose: snap back to its version.
		if controller then
			controller:SetCFrame(a)
			controller.Velocity = b
		end
	end
end)

LandingRemote.OnClientEvent:Connect(function(kind, a, b)
	if kind == Protocol.Landing.LandApproved then
		landing.Active = true
		landing.Elapsed = 0
		landing.Start = controller.CFrame
		landing.Target = a
		controller.Enabled = false
		controller:ClearInput()
		ShipState.SetState(STATE.Landing)
		ShipState.CanLand = false

	elseif kind == Protocol.Landing.LandDenied then
		ShipState.LandBlockReason = a
		ShipState.CanLand = false

	elseif kind == Protocol.Landing.Landed then
		landing.Active = false
		ShipState.Seated = true
		ShipState.SetState(STATE.Landed)

	elseif kind == Protocol.Landing.Exited then
		ShipState.Seated = false
		ShipState.SetState(STATE.OnFoot)

	elseif kind == Protocol.Landing.Entered then
		ShipState.Seated = true
		ShipState.SetState(STATE.Landed)
		if controller then
			controller:SetCFrame(a)
			controller:Halt()
		end

	elseif kind == Protocol.Landing.TookOff then
		ShipState.Seated = true
		if controller then
			controller:SetCFrame(a)
			controller.Velocity = b
			controller.Enabled = true
		end
		ShipState.SetState(ShipState.Phase)
	end
end)

--------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------
-- Input priority runs before Camera priority, so the camera in
-- CameraController always reads the pose produced this frame, not last one.
RunService:BindToRenderStep("SpaceFlight", Enum.RenderPriority.Input.Value + 10, onRenderStep)
