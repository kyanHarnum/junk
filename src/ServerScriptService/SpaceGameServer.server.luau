--[[
	SpaceGameServer
	==========================================================================
	Authority for everything that matters: who owns which ship, what state
	each pilot is in, and whether a requested landing is legal.

	Division of labour with the client:

	  * The CLIENT flies the ship. Input, integration and rendering all
	    happen locally at frame rate, because anything else feels like flying
	    through treacle. It streams its pose to the server ~15x a second.
	  * The SERVER owns the ship Instance. It applies the streamed pose (so
	    other players see the ship move), rejects poses that imply impossible
	    speed, and is the only thing that can move a player between the
	    SPACE / ATMOSPHERE / LANDING / LANDED / ON FOOT states.

	A client that lies about its position gets snapped back. A client that
	fires RequestLand from the console still has to satisfy the same
	LandingController.Evaluate() checks the HUD used, so the worst it can do
	is land somewhere it could already have landed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FlightConfig = require(Modules:WaitForChild("FlightConfig"))
local PlanetController = require(Modules:WaitForChild("PlanetController"))
local LandingController = require(Modules:WaitForChild("LandingController"))
local ShipBuilder = require(Modules:WaitForChild("ShipBuilder"))
local Protocol = require(Modules:WaitForChild("Protocol"))

-- Set before anything can yield: the ship must exist before the character
-- does, otherwise the player spawns for a frame inside the planet.
Players.CharacterAutoLoads = false

local STATE = Protocol.State
local SHIP_CFG = FlightConfig.Ship
local LANDING_CFG = FlightConfig.Landing

--------------------------------------------------------------------------
-- Remotes (created here so the project also works as a plain copy-paste
-- into Studio, with no Rojo instance tree required).
--------------------------------------------------------------------------
local function ensureRemote(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local FlightRemote = ensureRemote(remotesFolder, "FlightRemote")
local LandingRemote = ensureRemote(remotesFolder, "LandingRemote")

--------------------------------------------------------------------------
-- Per-player record
--------------------------------------------------------------------------
type Record = {
	Ship: Model,
	State: string,
	LastSync: number,
	LastPosition: Vector3,
	Velocity: Vector3,
	LandTarget: CFrame?,
}

local records: { [Player]: Record } = {}

local shipsFolder = Instance.new("Folder")
shipsFolder.Name = "Ships"
shipsFolder.Parent = Workspace

local function log(...)
	if FlightConfig.Debug.VerboseServer then
		print("[SpaceGameServer]", ...)
	end
end

local function setState(player: Player, newState: string)
	local record = records[player]
	if not record or record.State == newState then
		return
	end
	record.State = newState
	log(player.Name, "->", newState)
	FlightRemote:FireClient(player, Protocol.Flight.StateChanged, newState)
end

--- Puts the character in the pilot's seat.
---
--- The HumanoidRootPart is ANCHORED rather than welded to the ship. A weld
--- to an anchored part that is being CFramed every frame fights the physics
--- solver and jitters; anchoring and setting the CFrame explicitly is
--- deterministic. The client re-applies this every RenderStepped for its own
--- smoothness, and the server re-applies it on each sync so everyone ELSE
--- sees the pilot move with the ship too.
local function seatCharacter(player: Player, shipCFrame: CFrame)
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root then
		return
	end

	-- This runs on every sync packet, so only write the properties that
	-- actually changed.
	if humanoid and not humanoid.PlatformStand then
		humanoid.PlatformStand = true
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end
	if not root.Anchored then
		root.Anchored = true
	end
	root.CFrame = shipCFrame * SHIP_CFG.CockpitOffset
end

local function unseatCharacter(player: Player, targetCFrame: CFrame)
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root then
		return
	end

	root.CFrame = targetCFrame
	root.Anchored = false
	root.AssemblyLinearVelocity = Vector3.zero
	if humanoid then
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

--------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------
local function spawnShip(player: Player)
	local existing = records[player]
	if existing and existing.Ship then
		existing.Ship:Destroy()
	end

	local ship = ShipBuilder.Build("PlayerShip_" .. player.UserId)
	local spawnCFrame = PlanetController.GetSpawnCFrame()
	-- Parent BEFORE posing: ApplyPose moves the parts through
	-- Workspace:BulkMoveTo, which only acts on parts already in the world.
	ship.Parent = shipsFolder
	ShipBuilder.ApplyPose(ship, spawnCFrame)

	records[player] = {
		Ship = ship,
		State = STATE.Space,
		LastSync = os.clock(),
		LastPosition = spawnCFrame.Position,
		Velocity = Vector3.zero,
		LandTarget = nil,
	}

	return ship, spawnCFrame
end

local function onCharacterAdded(player: Player, character: Model)
	local record = records[player]
	if not record then
		return
	end
	-- Wait for the root before touching it; CharacterAdded can fire early.
	character:WaitForChild("HumanoidRootPart", 10)

	local shipCFrame = record.Ship:GetPivot()
	seatCharacter(player, shipCFrame)
	FlightRemote:FireClient(player, Protocol.Flight.ShipReady, record.Ship, shipCFrame)
	setState(player, PlanetController.GetPhase(PlanetController.GetAltitude(shipCFrame.Position)))
end

local function onPlayerAdded(player: Player)
	spawnShip(player)

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	-- CharacterAutoLoads is off (set at the top of this script) so the ship
	-- always exists before the character does -- otherwise the player spawns
	-- for a frame inside the planet at the world origin.
	player:LoadCharacter()
end

local function onPlayerRemoving(player: Player)
	local record = records[player]
	if record then
		if record.Ship then
			record.Ship:Destroy()
		end
		records[player] = nil
	end
end

--------------------------------------------------------------------------
-- Flight sync
--------------------------------------------------------------------------
--- Basic anti-teleport: a pose is only accepted if the distance moved since
--- the last accepted pose is achievable at the ship's maximum boosted speed,
--- with generous headroom for lag spikes. Anything else is rejected and the
--- client is corrected. This is a prototype-grade guard, not anti-cheat --
--- it exists so the shape of authoritative validation is in place before
--- there is anything worth cheating for.
local function isPlausibleMove(record: Record, newPosition: Vector3, now: number): boolean
	local dt = math.clamp(now - record.LastSync, 0, 2)
	local ceiling = SHIP_CFG.MaxSpeed * SHIP_CFG.BoostMultiplier
	local allowance = ceiling * dt * 1.75 + 60 -- slack for jitter and the landing glide
	return (newPosition - record.LastPosition).Magnitude <= allowance
end

local function handleSync(player: Player, cframe: CFrame, velocity: Vector3)
	local record = records[player]
	if not record or not record.Ship.Parent then
		return
	end
	if typeof(cframe) ~= "CFrame" or typeof(velocity) ~= "Vector3" then
		return
	end
	-- Reject non-finite values outright; NaN in a CFrame corrupts everything
	-- downstream, including other players' rendering.
	local p = cframe.Position
	if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z then
		return
	end

	local now = os.clock()

	if record.State == STATE.Landed or record.State == STATE.OnFoot then
		-- A landed ship does not move. Ignore stale packets in flight.
		return
	end

	if not isPlausibleMove(record, p, now) then
		log("rejected implausible move from", player.Name)
		FlightRemote:FireClient(player, Protocol.Flight.Correction, record.Ship:GetPivot(), record.Velocity)
		return
	end

	record.LastSync = now
	record.LastPosition = p
	record.Velocity = velocity
	ShipBuilder.ApplyPose(record.Ship, cframe)

	-- Keep the pilot's character with the ship for every other client.
	seatCharacter(player, cframe)

	-- Server-side phase authority. The client predicts the same transition
	-- locally for instant visuals; this is the copy that gates landing.
	local altitude = PlanetController.GetAltitude(p)
	local phase = PlanetController.GetPhase(altitude)
	if record.State ~= STATE.Landing and record.State ~= phase then
		setState(player, phase)
	end
end

FlightRemote.OnServerEvent:Connect(function(player, kind, a, b)
	if kind == Protocol.Flight.Sync then
		handleSync(player, a, b)
	end
end)

--------------------------------------------------------------------------
-- Landing
--------------------------------------------------------------------------
local function handleRequestLand(player: Player)
	local record = records[player]
	if not record then
		return
	end
	if record.State == STATE.Landing or record.State == STATE.Landed or record.State == STATE.OnFoot then
		LandingRemote:FireClient(player, Protocol.Landing.LandDenied, "ALREADY LANDED")
		return
	end

	local shipCFrame = record.Ship:GetPivot()
	-- The exact same evaluation the client's HUD ran. If the client showed a
	-- prompt it should not have, this is where the lie is caught.
	local evaluation = LandingController.Evaluate(shipCFrame, record.Velocity)

	if not evaluation.CanLand or not evaluation.Surface then
		LandingRemote:FireClient(player, Protocol.Landing.LandDenied, evaluation.Reason)
		return
	end

	local target = LandingController.BuildLandingCFrame(evaluation.Surface, shipCFrame)
	record.LandTarget = target
	setState(player, STATE.Landing)
	LandingRemote:FireClient(player, Protocol.Landing.LandApproved, target)
end

local function handleLandComplete(player: Player)
	local record = records[player]
	if not record or record.State ~= STATE.Landing or not record.LandTarget then
		return
	end

	-- The server places the ship at the target IT computed, not at whatever
	-- pose the client reports having finished at.
	local target = record.LandTarget
	ShipBuilder.ApplyPose(record.Ship, target)
	record.LastPosition = target.Position
	record.LastSync = os.clock()
	record.Velocity = Vector3.zero
	record.LandTarget = nil

	seatCharacter(player, target)
	setState(player, STATE.Landed)
	LandingRemote:FireClient(player, Protocol.Landing.Landed)
end

local function handleExitShip(player: Player)
	local record = records[player]
	if not record or record.State ~= STATE.Landed then
		return
	end

	local shipCFrame = record.Ship:GetPivot()
	local exitCFrame = LandingController.GetExitCFrame(shipCFrame)
	unseatCharacter(player, exitCFrame)
	setState(player, STATE.OnFoot)
	LandingRemote:FireClient(player, Protocol.Landing.Exited, exitCFrame)
end

local function handleEnterShip(player: Player)
	local record = records[player]
	if not record or record.State ~= STATE.OnFoot then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	local shipCFrame = record.Ship:GetPivot()
	-- Proximity is validated on the server; the client's prompt is only a hint.
	if not LandingController.IsWithinBoardingRange(root.Position, shipCFrame) then
		return
	end

	seatCharacter(player, shipCFrame)
	setState(player, STATE.Landed)
	LandingRemote:FireClient(player, Protocol.Landing.Entered, shipCFrame)
end

local function handleTakeOff(player: Player)
	local record = records[player]
	if not record or record.State ~= STATE.Landed then
		return
	end

	local shipCFrame = record.Ship:GetPivot()
	local up = PlanetController.GetUpVector(shipCFrame.Position)
	record.Velocity = up * LANDING_CFG.TakeoffBoost
	record.LastSync = os.clock()
	record.LastPosition = shipCFrame.Position

	setState(player, PlanetController.GetPhase(PlanetController.GetAltitude(shipCFrame.Position)))
	LandingRemote:FireClient(player, Protocol.Landing.TookOff, shipCFrame, record.Velocity)
end

LandingRemote.OnServerEvent:Connect(function(player, kind)
	if kind == Protocol.Landing.RequestLand then
		handleRequestLand(player)
	elseif kind == Protocol.Landing.LandComplete then
		handleLandComplete(player)
	elseif kind == Protocol.Landing.ExitShip then
		handleExitShip(player)
	elseif kind == Protocol.Landing.EnterShip then
		handleEnterShip(player)
	elseif kind == Protocol.Landing.TakeOff then
		handleTakeOff(player)
	end
end)

--------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------
-- The world must exist before anyone is dropped into it.
if not Workspace:GetAttribute("PlanetReady") then
	Workspace:GetAttributeChangedSignal("PlanetReady"):Wait()
end
Workspace:WaitForChild("Planet")

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

print("[SpaceGameServer] Ready.")
