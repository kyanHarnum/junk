--[[
	Prelude
	==========================================================================
	Locals the assembled module bodies close over in place of Roblox globals.
	Assembled ahead of the modules by tests/harness.py.
]]

local Stubs = require("./RobloxStubs")

local Vector3 = Stubs.Vector3
local Vector2 = Stubs.Vector2
local CFrame = Stubs.CFrame
local Color3 = Stubs.Color3
local NumberRange = Stubs.NumberRange
local UDim = Stubs.UDim
local Enum = Stubs.Enum
local noise = Stubs.noise

local function typeof(value)
	if type(value) == "table" then
		if getmetatable(value) == Stubs.CFrameMeta then return "CFrame" end
		if getmetatable(value) == Stubs.Vector3Meta then return "Vector3" end
	end
	return type(value)
end

--------------------------------------------------------------------------
-- A raycastable planet.
--
-- The real world is terrain voxels; here it is the analytic surface those
-- voxels approximate -- a sphere of PLANET_RADIUS with an optional height
-- offset -- solved directly. Tests can tilt the reported normal to exercise
-- the slope gate without building geometry.
--------------------------------------------------------------------------
local World = {
	Radius = 900,
	SurfaceOffset = 0,   -- raises/lowers the surface, simulating terrain height
	NormalTilt = 0,      -- degrees the surface normal leans away from radial
	HitInstance = { Name = "StubTerrain" },
}

local function raycastSphere(origin, delta)
	-- |origin + t*delta| = R, solved for the nearest t in (0, 1].
	local radius = World.Radius + World.SurfaceOffset
	local a = delta:Dot(delta)
	if a == 0 then return nil end
	local b = 2 * origin:Dot(delta)
	local c = origin:Dot(origin) - radius * radius
	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then return nil end

	local root = math.sqrt(discriminant)
	local t1 = (-b - root) / (2 * a)
	local t2 = (-b + root) / (2 * a)

	local t = nil
	if t1 > 1e-6 and t1 <= 1 then
		t = t1
	elseif t2 > 1e-6 and t2 <= 1 then
		t = t2
	end
	if not t then return nil end

	local position = origin + delta * t
	local normal = position.Unit

	if World.NormalTilt ~= 0 then
		-- Lean the normal away from radial by NormalTilt degrees, around any
		-- axis perpendicular to it.
		local angle = math.rad(World.NormalTilt)
		local axis = normal:Cross(Vector3.xAxis)
		if axis.Magnitude < 1e-4 then axis = normal:Cross(Vector3.zAxis) end
		axis = axis.Unit
		local tangent = axis:Cross(normal).Unit
		normal = (normal * math.cos(angle) + tangent * math.sin(angle)).Unit
	end

	return { Position = position, Normal = normal, Instance = World.HitInstance, Distance = (position - origin).Magnitude }
end

local workspace = {
	Terrain = { Name = "Terrain" },
	Raycast = function(_, origin, direction, _params)
		return raycastSphere(origin, direction)
	end,
	WaitForChild = function(_, name)
		return { Name = name }
	end,
	GetAttribute = function() return true end,
}
local Workspace = workspace

local game = {
	GetService = function(_, name)
		if name == "Workspace" then return workspace end
		return { Name = name }
	end,
}

local RaycastParams = {
	new = function()
		return {
			FilterType = nil,
			FilterDescendantsInstances = {},
			IgnoreWater = false,
		}
	end,
}

--------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------
local passed, failed = 0, 0
local currentSection = ""

local function section(name)
	currentSection = name
	print("")
	print("-- " .. name)
end

local function check(label, condition, detail)
	if condition then
		passed += 1
		print(string.format("   ok    %s", label))
	else
		failed += 1
		print(string.format("   FAIL  %s%s", label, detail and ("  <- " .. detail) or ""))
	end
end

local function near(label, actual, expected, tolerance)
	local delta = math.abs(actual - expected)
	check(
		label,
		delta <= tolerance,
		string.format("got %.4f, expected %.4f +/- %.4f", actual, expected, tolerance)
	)
end
