--[[
	FlightController
	==========================================================================
	The ship's flight model. A pure integrator: feed it input and a dt, it
	updates a CFrame and a velocity. It touches no Instances, no services and
	no UI, which means it can be driven by the client for responsiveness and
	re-run by the server later for validation without changing a line.

	Why it feels like a spacecraft rather than a Roblox car:

	  * Velocity is independent of facing. Turning does not turn your
	    momentum -- you keep drifting the way you were going and have to
	    thrust out of it.
	  * Drag is split into a forward component and a lateral component. Low
	    forward drag preserves the long coast of a vacuum; high lateral drag
	    gives the ship enough "grip" to be flyable instead of sliding like a
	    puck. Raising LateralDrag makes it arcadey, lowering it makes it
	    Newtonian.
	  * Rotation rates are smoothed rather than snapped, so the ship has
	    perceptible mass when you start and stop a turn.
	  * Inside an atmosphere both drag terms scale up and a gentle pull
	    toward the planet is added, so the same controls feel heavier in air.
]]

local FlightController = {}
FlightController.__index = FlightController

export type Input = {
	Forward: number,     -- 0..1  (W)
	Backward: number,    -- 0..1  (S)
	Yaw: number,         -- -1..1 (A/D, positive = left)
	Pitch: number,       -- -1..1 (arrow keys, positive = nose up)
	Roll: number,        -- -1..1 (Q/E)
	MouseDelta: Vector2, -- raw pixels this frame
	Boost: boolean,      -- (Space)
}

export type Environment = {
	AtmosphereFactor: number,  -- 0..1 from PlanetController
	GravityDirection: Vector3, -- unit vector toward the planet centre
}

local ZERO_INPUT: Input = {
	Forward = 0,
	Backward = 0,
	Yaw = 0,
	Pitch = 0,
	Roll = 0,
	MouseDelta = Vector2.zero,
	Boost = false,
}

--- Repeated CFrame.Angles multiplication accumulates floating point error
--- until the basis is no longer orthogonal and the ship visibly skews. Once
--- per frame we rebuild the rotation from clean, perpendicular axes.
local function orthonormalize(cf: CFrame): CFrame
	local position = cf.Position
	local look = cf.LookVector
	if look.Magnitude < 1e-5 then
		return cf
	end
	look = look.Unit

	local up = cf.UpVector
	local right = look:Cross(up)
	if right.Magnitude < 1e-5 then
		-- Degenerate (look and up collapsed); pick any perpendicular axis.
		right = look:Cross(Vector3.yAxis)
		if right.Magnitude < 1e-5 then
			right = look:Cross(Vector3.xAxis)
		end
	end
	right = right.Unit
	up = right:Cross(look).Unit

	return CFrame.fromMatrix(position, right, up, -look)
end

--- Frame-rate independent exponential approach. Returns the fraction to move
--- toward the target this frame, clamped so a long hitch cannot overshoot.
local function approach(rate: number, dt: number): number
	return math.clamp(rate * dt, 0, 1)
end

function FlightController.new(startCFrame: CFrame, config)
	local self = setmetatable({}, FlightController)

	self.Config = config
	self.CFrame = startCFrame
	self.Velocity = Vector3.zero

	self.Throttle = 0                       -- -1..1, smoothed
	self.AngularVelocity = Vector3.zero     -- (pitch, yaw, roll) rad/s, smoothed
	self.Boosting = false
	self.Enabled = true

	self.Input = table.clone(ZERO_INPUT)

	return self
end

function FlightController:SetInput(input: Input)
	self.Input = input
end

function FlightController:ClearInput()
	self.Input = table.clone(ZERO_INPUT)
end

function FlightController:GetSpeed(): number
	return self.Velocity.Magnitude
end

function FlightController:SetCFrame(cf: CFrame)
	self.CFrame = orthonormalize(cf)
end

function FlightController:SetPosition(position: Vector3)
	self.CFrame = self.CFrame.Rotation + position
end

--- Bring the ship to a dead stop, keeping its orientation. Used by the
--- landing sequence and on touchdown.
function FlightController:Halt()
	self.Velocity = Vector3.zero
	self.Throttle = 0
	self.AngularVelocity = Vector3.zero
	self:ClearInput()
end

--- The speed ceiling right now: boost raises it, atmosphere lowers it.
function FlightController:GetMaxSpeed(atmosphereFactor: number): number
	local cfg = self.Config
	local boost = self.Boosting and cfg.BoostMultiplier or 1
	local vacuumMax = cfg.MaxSpeed * boost
	local airMax = cfg.AtmosphereSpeedCap * boost
	-- Blend rather than switch, so crossing the boundary is not a jolt.
	return vacuumMax + (airMax - vacuumMax) * math.clamp(atmosphereFactor, 0, 1)
end

--------------------------------------------------------------------------
-- The integration step
--------------------------------------------------------------------------
function FlightController:Step(dt: number, env: Environment)
	-- A hitch (loading, alt-tab) must never teleport the ship across the map.
	dt = math.clamp(dt, 0, 1 / 20)
	if dt <= 0 then
		return self.CFrame
	end

	local cfg = self.Config
	local input = self.Input
	local atm = math.clamp(env.AtmosphereFactor or 0, 0, 1)

	if not self.Enabled then
		-- Controls are locked (landing sequence, landed, on foot). Keep
		-- coasting so the ship never freezes mid-air, but accept no input.
		self.CFrame = self.CFrame + self.Velocity * dt
		return self.CFrame
	end

	self.Boosting = input.Boost == true

	----------------------------------------------------------------------
	-- 1. Throttle: ramp toward the key state instead of snapping to it.
	----------------------------------------------------------------------
	local throttleTarget = (input.Forward or 0) - (input.Backward or 0)
	self.Throttle += (throttleTarget - self.Throttle) * approach(cfg.ThrottleResponse, dt)

	----------------------------------------------------------------------
	-- 2. Rotation.
	----------------------------------------------------------------------
	local mouse = input.MouseDelta or Vector2.zero
	local mousePitch, mouseYaw = 0, 0
	if cfg.MouseSteering then
		-- Screen Y grows downward, so moving the mouse up is a negative
		-- delta; negate it so "mouse up" is "nose up".
		mousePitch = -mouse.Y * cfg.MouseSensitivity
		if cfg.MousePitchInvert then
			mousePitch = -mousePitch
		end
		-- Moving the mouse right should yaw right, and positive yaw is left.
		mouseYaw = -mouse.X * cfg.MouseSensitivity
	end

	local desired = Vector3.new(
		math.clamp((input.Pitch or 0) + mousePitch, -1.5, 1.5) * cfg.PitchSpeed,
		math.clamp((input.Yaw or 0) + mouseYaw, -1.5, 1.5) * cfg.YawSpeed,
		(input.Roll or 0) * cfg.RollSpeed
	)

	self.AngularVelocity = self.AngularVelocity:Lerp(desired, approach(cfg.RotationResponse, dt))

	local rotated = self.CFrame * CFrame.Angles(
		self.AngularVelocity.X * dt,
		self.AngularVelocity.Y * dt,
		self.AngularVelocity.Z * dt
	)
	local cf = orthonormalize(rotated)

	----------------------------------------------------------------------
	-- 3. Velocity: drag, thrust, gravity, clamp.
	----------------------------------------------------------------------
	local look = cf.LookVector
	local velocity = self.Velocity

	-- Split the current velocity into "along the nose" and "sideways".
	local forwardSpeed = velocity:Dot(look)
	local forwardComponent = look * forwardSpeed
	local lateralComponent = velocity - forwardComponent

	local dragScale = 1 + atm * cfg.AtmosphereDragMultiplier
	forwardComponent *= math.max(0, 1 - cfg.LinearDrag * dragScale * dt)
	lateralComponent *= math.max(0, 1 - cfg.LateralDrag * dragScale * dt)
	velocity = forwardComponent + lateralComponent

	-- Thrust always acts along the nose.
	local acceleration = self.Throttle >= 0 and cfg.ThrustAcceleration or cfg.ReverseAcceleration
	if self.Boosting and self.Throttle > 0 then
		acceleration *= cfg.BoostAcceleration
	end
	velocity += look * (self.Throttle * acceleration * dt)

	-- Air has weight: sink gently once inside the atmosphere.
	if atm > 0 and env.GravityDirection then
		velocity += env.GravityDirection * (cfg.AtmosphereGravity * atm * dt)
	end

	local speed = velocity.Magnitude
	local maxSpeed = self:GetMaxSpeed(atm)
	if speed > maxSpeed then
		velocity *= (maxSpeed / speed)
	elseif speed < 0.05 then
		velocity = Vector3.zero
	end

	self.Velocity = velocity
	self.CFrame = cf + velocity * dt

	return self.CFrame
end

return FlightController
