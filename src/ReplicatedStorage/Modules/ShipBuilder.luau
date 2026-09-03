--[[
	ShipBuilder
	==========================================================================
	Builds the player's ship out of primitives at runtime.

	Everything in this prototype is constructed from code rather than shipped
	as a .rbxm, so the whole game lives in git as readable text and there is
	no binary model to keep in sync. Swap this module for a MeshPart import
	when you have real art -- as long as the replacement Model keeps the same
	PrimaryPart named "Root" and the same attachment names, nothing else in
	the project has to change.

	Conventions this model must honour:
	  * PrimaryPart is "Root", an invisible part at the ship's centre of mass.
	  * The nose points along -Z (Roblox's LookVector).
	  * Every part is Anchored (the ship is moved by CFrame, not by physics)
	    and has CanCollide/CanQuery off so it never blocks a surface probe.
]]

local ShipBuilder = {}

local HULL_COLOR = Color3.fromRGB(196, 202, 212)
local PANEL_COLOR = Color3.fromRGB(74, 84, 100)
local ACCENT_COLOR = Color3.fromRGB(90, 200, 255)
local GLASS_COLOR = Color3.fromRGB(28, 44, 68)

--- Creates one anchored, non-colliding, non-queryable hull part.
local function piece(parent: Model, name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material?)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false   -- keeps the ship invisible to its own surface raycasts
	part.CanTouch = false
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	-- Offset is stored, not applied; ApplyPose() positions everything at once.
	part:SetAttribute("Offset", offset)
	return part
end

--[[
	Moves the whole ship, keeping every part in its designed relative pose.
	This is the ONLY way the ship should ever be moved.

	Called every frame on the client, so it is written to allocate nothing on
	the hot path:
	  * the part list and their offsets are gathered once per model and
	    cached against it (weakly, so a destroyed ship is collected);
	  * the CFrame array is reused across calls rather than rebuilt;
	  * the parts move through BulkMoveTo, which is a single engine-side
	    write instead of ~25 individual property assignments, each of which
	    would otherwise fire its own change events.
]]
local poseCache: { [Model]: { Parts: { BasePart }, Offsets: { CFrame }, Buffer: { CFrame } } } =
	setmetatable({}, { __mode = "k" }) :: any

local function getPose(model: Model)
	local cached = poseCache[model]
	if cached then
		return cached
	end

	local parts, offsets = {}, {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local offset = descendant:GetAttribute("Offset")
			if typeof(offset) == "CFrame" then
				table.insert(parts, descendant)
				table.insert(offsets, offset)
			end
		end
	end

	cached = { Parts = parts, Offsets = offsets, Buffer = table.create(#parts) }
	poseCache[model] = cached
	return cached
end

function ShipBuilder.ApplyPose(model: Model, cf: CFrame)
	local pose = getPose(model)
	local parts, offsets, buffer = pose.Parts, pose.Offsets, pose.Buffer

	for index = 1, #parts do
		buffer[index] = cf * offsets[index]
	end

	workspace:BulkMoveTo(parts, buffer, Enum.BulkMoveMode.FireCFrameChanged)
end

function ShipBuilder.Build(name: string): Model
	local model = Instance.new("Model")
	model.Name = name

	------------------------------------------------------------------
	-- Root: the invisible reference part everything else hangs off.
	------------------------------------------------------------------
	local root = piece(model, "Root", Vector3.new(1, 1, 1), CFrame.new(), HULL_COLOR)
	root.Transparency = 1
	root.CastShadow = false
	model.PrimaryPart = root

	------------------------------------------------------------------
	-- Fuselage: a wide flat body with a three-stage taper for the nose.
	-- Stacked blocks rather than wedges, because block orientation is
	-- unambiguous and this is placeholder geometry either way.
	------------------------------------------------------------------
	piece(model, "Hull", Vector3.new(5.0, 1.9, 11.0), CFrame.new(0, 0, 0), HULL_COLOR)
	piece(model, "NoseA", Vector3.new(4.0, 1.5, 3.6), CFrame.new(0, -0.05, -7.2), HULL_COLOR)
	piece(model, "NoseB", Vector3.new(2.8, 1.15, 3.0), CFrame.new(0, -0.10, -10.2), HULL_COLOR)
	piece(model, "NoseTip", Vector3.new(1.5, 0.8, 2.4), CFrame.new(0, -0.15, -12.6), ACCENT_COLOR, Enum.Material.Neon)

	piece(model, "Spine", Vector3.new(2.2, 0.7, 8.0), CFrame.new(0, 1.05, 1.2), PANEL_COLOR)
	piece(model, "Belly", Vector3.new(3.6, 0.6, 7.5), CFrame.new(0, -1.15, 0.4), PANEL_COLOR)

	------------------------------------------------------------------
	-- Canopy: tinted glass so you can see the pilot sitting inside.
	------------------------------------------------------------------
	local canopy = piece(model, "Canopy", Vector3.new(2.6, 1.5, 4.2), CFrame.new(0, 1.15, -2.6), GLASS_COLOR, Enum.Material.Glass)
	canopy.Transparency = 0.45
	canopy.Reflectance = 0.15

	------------------------------------------------------------------
	-- Wings: swept back and dihedral, mirrored left and right.
	------------------------------------------------------------------
	for _, side in { -1, 1 } do
		local sideName = side < 0 and "Left" or "Right"

		local wingPose = CFrame.new(side * 5.4, -0.15, 1.6)
			* CFrame.Angles(0, math.rad(-side * 16), math.rad(side * 10))
		piece(model, "Wing" .. sideName, Vector3.new(7.2, 0.5, 4.4), wingPose, HULL_COLOR)

		local tipPose = CFrame.new(side * 8.6, 0.35, 2.4) * CFrame.Angles(0, 0, math.rad(side * 10))
		piece(model, "WingTip" .. sideName, Vector3.new(0.6, 1.8, 2.6), tipPose, PANEL_COLOR)

		local stripPose = CFrame.new(side * 5.4, 0.1, 0.4) * CFrame.Angles(0, math.rad(-side * 16), math.rad(side * 10))
		local strip = piece(model, "WingLight" .. sideName, Vector3.new(5.0, 0.16, 0.5), stripPose, ACCENT_COLOR, Enum.Material.Neon)
		strip.CastShadow = false

		------------------------------------------------------------------
		-- Engines: cylinders. A Roblox cylinder's axis runs along its X
		-- axis, so a 90 degree yaw lays it along the ship's Z axis.
		------------------------------------------------------------------
		local engine = piece(
			model,
			"Engine" .. sideName,
			Vector3.new(5.2, 2.2, 2.2),
			CFrame.new(side * 2.6, 0.05, 4.6) * CFrame.Angles(0, math.rad(90), 0),
			PANEL_COLOR,
			Enum.Material.Metal
		)
		engine.Shape = Enum.PartType.Cylinder

		local nozzle = piece(
			model,
			"Thruster" .. sideName,
			Vector3.new(0.7, 1.9, 1.9),
			CFrame.new(side * 2.6, 0.05, 7.3) * CFrame.Angles(0, math.rad(90), 0),
			ACCENT_COLOR,
			Enum.Material.Neon
		)
		nozzle.Shape = Enum.PartType.Cylinder
		nozzle.CastShadow = false

		-- Exhaust plume. Rate/size are driven every frame by FlightClient.
		local exhaustAttachment = Instance.new("Attachment")
		exhaustAttachment.Name = "Exhaust"
		-- The cylinder is yawed 90 degrees, so its local +X is the ship's +Z (aft).
		exhaustAttachment.CFrame = CFrame.new(0.6, 0, 0)
		exhaustAttachment.Parent = nozzle

		local flame = Instance.new("ParticleEmitter")
		flame.Name = "Flame"
		flame.Enabled = true
		flame.Rate = 0
		flame.Lifetime = NumberRange.new(0.14, 0.28)
		flame.Speed = NumberRange.new(24, 46)
		flame.SpreadAngle = Vector2.new(5, 5)
		flame.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2.0),
			NumberSequenceKeypoint.new(1, 0.1),
		})
		flame.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})
		flame.Color = ColorSequence.new(Color3.fromRGB(180, 235, 255), Color3.fromRGB(40, 120, 255))
		flame.LightEmission = 1
		flame.LightInfluence = 0
		flame.Acceleration = Vector3.zero
		flame.Parent = exhaustAttachment

		local glow = Instance.new("PointLight")
		glow.Name = "ThrusterGlow"
		glow.Color = ACCENT_COLOR
		glow.Range = 22
		glow.Brightness = 0
		glow.Parent = nozzle

		------------------------------------------------------------------
		-- Landing gear (cosmetic; the ship is never physically simulated).
		------------------------------------------------------------------
		piece(model, "Gear" .. sideName, Vector3.new(0.5, 2.0, 0.5), CFrame.new(side * 2.2, -2.2, 1.0), PANEL_COLOR, Enum.Material.Metal)
		piece(model, "Foot" .. sideName, Vector3.new(1.4, 0.4, 1.6), CFrame.new(side * 2.2, -3.2, 1.0), PANEL_COLOR, Enum.Material.Metal)
	end

	piece(model, "GearNose", Vector3.new(0.45, 1.8, 0.45), CFrame.new(0, -2.1, -6.2), PANEL_COLOR, Enum.Material.Metal)
	piece(model, "FootNose", Vector3.new(1.1, 0.4, 1.4), CFrame.new(0, -3.0, -6.2), PANEL_COLOR, Enum.Material.Metal)

	------------------------------------------------------------------
	-- Named attachments other systems look for by name.
	------------------------------------------------------------------
	local cockpit = Instance.new("Attachment")
	cockpit.Name = "Cockpit"
	cockpit.CFrame = CFrame.new(0, 1.15, -2.1)
	cockpit.Parent = root

	-- Where AtmosphereController parents the re-entry speed streaks.
	local effects = Instance.new("Attachment")
	effects.Name = "EffectOrigin"
	effects.CFrame = CFrame.new(0, 0, -4)
	effects.Parent = root

	return model
end

--------------------------------------------------------------------------
-- Runtime dressing
--------------------------------------------------------------------------
local thrusterCache: { [Model]: { Flames: { ParticleEmitter }, Glows: { PointLight } } } =
	setmetatable({}, { __mode = "k" }) :: any

local function getThrusters(model: Model)
	local cached = thrusterCache[model]
	if cached then
		return cached
	end

	local flames, glows = {}, {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ParticleEmitter") and descendant.Name == "Flame" then
			table.insert(flames, descendant)
		elseif descendant:IsA("PointLight") and descendant.Name == "ThrusterGlow" then
			table.insert(glows, descendant)
		end
	end

	cached = { Flames = flames, Glows = glows }
	thrusterCache[model] = cached
	return cached
end

--- Scales the exhaust plume with the throttle. Called every frame, so the
--- emitter list is cached and only two properties per thruster are written.
function ShipBuilder.SetThrusterIntensity(model: Model, intensity: number)
	intensity = math.clamp(intensity, 0, 1)
	local thrusters = getThrusters(model)

	for _, flame in thrusters.Flames do
		flame.Rate = 140 * intensity
		flame.Speed = NumberRange.new(20 * intensity + 4, 50 * intensity + 8)
	end
	for _, glow in thrusters.Glows do
		glow.Brightness = 3.2 * intensity
	end
end

return ShipBuilder
