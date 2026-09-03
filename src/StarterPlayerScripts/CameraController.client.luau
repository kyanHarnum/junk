--[[
	CameraController
	==========================================================================
	Chase camera for the ship, and nothing else -- it hands control straight
	back to Roblox's default camera the moment the player is on foot.

	Three things do the heavy lifting for "this feels fast":
	  * the camera trails the ship on a spring rather than being rigidly
	    attached, so hard turns swing it out;
	  * FOV widens with speed;
	  * shake scales with speed AND atmosphere density, so the same 400
	    studs/s is serene in vacuum and violent in air.

	Bound at Camera render priority, which runs after FlightClient's Input+10
	binding, so it always reads the pose produced this frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FlightConfig = require(Modules:WaitForChild("FlightConfig"))
local ShipState = require(Modules:WaitForChild("ShipState"))
local Protocol = require(Modules:WaitForChild("Protocol"))

local player = Players.LocalPlayer
local CAM = FlightConfig.Camera
local STATE = Protocol.State

local camera = Workspace.CurrentCamera
local currentCFrame: CFrame? = nil
local currentFov = CAM.FovBase

--- Restores Roblox's default over-the-shoulder camera for walking around.
local function releaseCamera()
	if camera.CameraType ~= Enum.CameraType.Custom then
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = CAM.FovBase
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
		currentCFrame = nil
	end
end

--- Small, fast, unbiased jitter. Perlin noise rather than pure random so the
--- shake reads as vibration instead of static.
local function shakeOffset(intensity: number, clock: number): Vector3
	if intensity <= 0 then
		return Vector3.zero
	end
	return Vector3.new(
		math.noise(clock * 9.1, 0.0, 0.0),
		math.noise(0.0, clock * 8.3, 0.0),
		math.noise(0.0, 0.0, clock * 7.7)
	) * intensity
end

local function onCameraStep(dt: number)
	camera = Workspace.CurrentCamera

	local ship = ShipState.Ship
	if not ShipState.Ready or not ship or not ship.Parent or ShipState.State == STATE.OnFoot then
		releaseCamera()
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	local shipCFrame = ShipState.CFrame

	-- Desired pose: sat behind and above the ship, aimed slightly ahead of it.
	local desiredPosition = shipCFrame * CAM.Offset
	local focus = shipCFrame.Position + shipCFrame.LookVector * CAM.LookAhead
	local desired = CFrame.lookAt(desiredPosition, focus, shipCFrame.UpVector)

	-- Spring toward it. Framerate-independent, clamped so a hitch cannot
	-- overshoot past the target.
	if currentCFrame then
		currentCFrame = currentCFrame:Lerp(desired, math.clamp(CAM.Stiffness * dt, 0, 1))
	else
		currentCFrame = desired
	end

	-- Speed shake, amplified by the air.
	local overSpeed = math.max(ShipState.Speed - CAM.ShakeStartSpeed, 0)
	local speedRange = math.max(FlightConfig.Ship.MaxSpeed - CAM.ShakeStartSpeed, 1)
	local intensity = math.clamp(overSpeed / speedRange, 0, 1)
		* CAM.ShakeIntensity
		* (0.25 + 0.75 * ShipState.AtmosphereFactor)

	local shaken = currentCFrame + shakeOffset(intensity, os.clock())
	camera.CFrame = shaken
	camera.Focus = CFrame.new(focus)

	-- FOV: widen with actual speed, not with throttle, so coasting fast still
	-- looks fast.
	local speedFraction = math.clamp(ShipState.Speed / math.max(FlightConfig.Ship.MaxSpeed, 1), 0, 1.4)
	local targetFov = CAM.FovBase + (CAM.FovBoost - CAM.FovBase) * speedFraction
	currentFov += (targetFov - currentFov) * math.clamp(CAM.FovResponse * dt, 0, 1)
	camera.FieldOfView = currentFov
end

RunService:BindToRenderStep("SpaceCamera", Enum.RenderPriority.Camera.Value, onCameraStep)
