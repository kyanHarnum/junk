--[[
	RobloxStubs
	==========================================================================
	Just enough of the Roblox API to run the pure-logic modules (FlightConfig,
	FlightController, PlanetController, LandingController) outside Studio,
	under the standalone Luau interpreter.

	This is NOT an emulator. It exists so flight tuning and landing rules can
	be checked in a couple of seconds from the command line instead of a
	Studio round trip. Anything that touches Instances, rendering or
	replication is out of scope and stays untested here.

	Vector3 and CFrame are real implementations (3x3 basis + position), so
	the flight integrator is genuinely exercised, not faked.
]]

local Stubs = {}

--------------------------------------------------------------------------
-- Vector3
--------------------------------------------------------------------------
local Vector3 = {}
Vector3.__index = Vector3

local function v3(x, y, z)
	return setmetatable({ X = x, Y = y, Z = z }, Vector3)
end

function Vector3.__add(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
function Vector3.__sub(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
function Vector3.__unm(a) return v3(-a.X, -a.Y, -a.Z) end
function Vector3.__eq(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
function Vector3.__tostring(a) return string.format("(%.2f, %.2f, %.2f)", a.X, a.Y, a.Z) end

function Vector3.__mul(a, b)
	if type(b) == "number" then return v3(a.X * b, a.Y * b, a.Z * b) end
	if type(a) == "number" then return v3(b.X * a, b.Y * a, b.Z * a) end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end

function Vector3.__div(a, b)
	if type(b) == "number" then return v3(a.X / b, a.Y / b, a.Z / b) end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end

function Vector3.__index(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
	elseif key == "Unit" then
		local m = self.Magnitude
		if m == 0 then return v3(0, 0, 0) end
		return v3(self.X / m, self.Y / m, self.Z / m)
	end
	return rawget(Vector3, key)
end

function Vector3:Dot(o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
function Vector3:Cross(o)
	return v3(
		self.Y * o.Z - self.Z * o.Y,
		self.Z * o.X - self.X * o.Z,
		self.X * o.Y - self.Y * o.X
	)
end
function Vector3:Lerp(o, t) return self + (o - self) * t end

Stubs.Vector3 = setmetatable({
	new = function(x, y, z) return v3(x or 0, y or 0, z or 0) end,
	zero = v3(0, 0, 0),
	one = v3(1, 1, 1),
	xAxis = v3(1, 0, 0),
	yAxis = v3(0, 1, 0),
	zAxis = v3(0, 0, 1),
}, {})

--------------------------------------------------------------------------
-- Vector2
--------------------------------------------------------------------------
local Vector2 = {}
Vector2.__index = Vector2
local function v2(x, y) return setmetatable({ X = x, Y = y }, Vector2) end
Stubs.Vector2 = { new = function(x, y) return v2(x or 0, y or 0) end, zero = v2(0, 0) }

--------------------------------------------------------------------------
-- CFrame: position plus an orthonormal basis (right, up, back).
-- LookVector is -back, matching Roblox.
--------------------------------------------------------------------------
local CFrame = {}

local function cf(p, r, u, b)
	return setmetatable({ p = p, r = r, u = u, b = b }, CFrame)
end

function CFrame.__index(self, key)
	if key == "Position" or key == "p" and false then return self.p end
	if key == "Position" then return self.p end
	if key == "LookVector" then return -self.b end
	if key == "UpVector" then return self.u end
	if key == "RightVector" then return self.r end
	if key == "Rotation" then return cf(Stubs.Vector3.zero, self.r, self.u, self.b) end
	return rawget(CFrame, key)
end

function CFrame.__mul(a, b)
	if getmetatable(b) == CFrame then
		-- Rotate b's basis by a's, then translate.
		local function rot(v)
			return a.r * v.X + a.u * v.Y + a.b * v.Z
		end
		return cf(a.p + rot(b.p), rot(b.r), rot(b.u), rot(b.b))
	end
	-- CFrame * Vector3 -> transformed point
	return a.p + a.r * b.X + a.u * b.Y + a.b * b.Z
end

function CFrame.__add(a, v) return cf(a.p + v, a.r, a.u, a.b) end
function CFrame.__sub(a, v) return cf(a.p - v, a.r, a.u, a.b) end

function CFrame:Lerp(other, t)
	-- Good enough for tests: lerp the basis then re-orthonormalise.
	local p = self.p:Lerp(other.p, t)
	local b = (self.b:Lerp(other.b, t)).Unit
	local u = self.u:Lerp(other.u, t)
	local r = u:Cross(b)
	if r.Magnitude < 1e-6 then r = Stubs.Vector3.xAxis end
	r = r.Unit
	u = b:Cross(r).Unit
	return cf(p, r, u, b)
end

Stubs.CFrame = {
	new = function(a, b, c)
		local p
		if type(a) == "number" then
			p = Stubs.Vector3.new(a, b or 0, c or 0)
		else
			p = a or Stubs.Vector3.zero
		end
		return cf(p, Stubs.Vector3.xAxis, Stubs.Vector3.yAxis, Stubs.Vector3.zAxis)
	end,

	Angles = function(rx, ry, rz)
		-- Roblox composes as Rx * Ry * Rz.
		local function mul(m, n)
			local out = {}
			for i = 1, 3 do
				out[i] = {}
				for j = 1, 3 do
					local sum = 0
					for k = 1, 3 do sum += m[i][k] * n[k][j] end
					out[i][j] = sum
				end
			end
			return out
		end
		local cx, sx = math.cos(rx), math.sin(rx)
		local cy, sy = math.cos(ry), math.sin(ry)
		local cz, sz = math.cos(rz), math.sin(rz)
		local Rx = { { 1, 0, 0 }, { 0, cx, -sx }, { 0, sx, cx } }
		local Ry = { { cy, 0, sy }, { 0, 1, 0 }, { -sy, 0, cy } }
		local Rz = { { cz, -sz, 0 }, { sz, cz, 0 }, { 0, 0, 1 } }
		local m = mul(mul(Rx, Ry), Rz)
		-- Columns of the matrix are the basis vectors.
		return cf(
			Stubs.Vector3.zero,
			Stubs.Vector3.new(m[1][1], m[2][1], m[3][1]),
			Stubs.Vector3.new(m[1][2], m[2][2], m[3][2]),
			Stubs.Vector3.new(m[1][3], m[2][3], m[3][3])
		)
	end,

	fromMatrix = function(p, vx, vy, vz)
		return cf(p, vx, vy, vz)
	end,

	lookAt = function(from, to, up)
		local forward = (to - from).Unit
		up = up or Stubs.Vector3.yAxis
		local right = forward:Cross(up)
		if right.Magnitude < 1e-6 then right = forward:Cross(Stubs.Vector3.xAxis) end
		right = right.Unit
		local realUp = right:Cross(forward).Unit
		return cf(from, right, realUp, -forward)
	end,
}

--------------------------------------------------------------------------
-- Misc value types used by FlightConfig
--------------------------------------------------------------------------
Stubs.Color3 = {
	new = function(r, g, b) return { R = r, G = g, B = b } end,
	fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end,
}
Stubs.NumberRange = { new = function(a, b) return { Min = a, Max = b or a } end }
Stubs.UDim = { new = function(s, o) return { Scale = s, Offset = o } end }

-- Enums are only ever compared for identity in the modules under test, so a
-- table that mints a stable object per name is sufficient.
local function enumFamily()
	return setmetatable({}, {
		__index = function(self, name)
			local value = { Name = name }
			rawset(self, name, value)
			return value
		end,
	})
end
Stubs.Enum = setmetatable({}, {
	__index = function(self, family)
		local f = enumFamily()
		rawset(self, family, f)
		return f
	end,
})

--------------------------------------------------------------------------
-- math.noise (Roblox extension; not in standalone Luau)
--------------------------------------------------------------------------
-- Classic Perlin, matching Roblox's contract: smooth, deterministic, and
-- bounded well inside -1..1. Values will NOT match Roblox exactly, so this
-- verifies the SHAPE of the terrain envelope, not the exact hills.
local perm = {}
do
	local rng = 1
	local function nextInt(n)
		rng = (rng * 1103515245 + 12345) % 2147483648
		return rng % n
	end
	for i = 0, 255 do perm[i] = i end
	for i = 255, 1, -1 do
		local j = nextInt(i + 1)
		perm[i], perm[j] = perm[j], perm[i]
	end
	for i = 0, 255 do perm[256 + i] = perm[i] end
end

local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end
local function grad(hash, x, y, z)
	local h = hash % 16
	local u = h < 8 and x or y
	local v = h < 4 and y or ((h == 12 or h == 14) and x or z)
	return ((h % 2) == 0 and u or -u) + ((h % 4) < 2 and v or -v)
end

function Stubs.noise(x, y, z)
	x, y, z = x or 0, y or 0, z or 0
	local xi, yi, zi = math.floor(x) % 256, math.floor(y) % 256, math.floor(z) % 256
	local xf, yf, zf = x - math.floor(x), y - math.floor(y), z - math.floor(z)
	local u, v, w = fade(xf), fade(yf), fade(zf)

	local a = perm[xi] + yi
	local aa, ab = perm[a] + zi, perm[a + 1] + zi
	local b = perm[xi + 1] + yi
	local ba, bb = perm[b] + zi, perm[b + 1] + zi

	local function lerp(t, p, q) return p + t * (q - p) end

	return lerp(w,
		lerp(v,
			lerp(u, grad(perm[aa], xf, yf, zf), grad(perm[ba], xf - 1, yf, zf)),
			lerp(u, grad(perm[ab], xf, yf - 1, zf), grad(perm[bb], xf - 1, yf - 1, zf))
		),
		lerp(v,
			lerp(u, grad(perm[aa + 1], xf, yf, zf - 1), grad(perm[ba + 1], xf - 1, yf, zf - 1)),
			lerp(u, grad(perm[ab + 1], xf, yf - 1, zf - 1), grad(perm[bb + 1], xf - 1, yf - 1, zf - 1))
		)
	)
end

--------------------------------------------------------------------------
-- Instance / service stubs
--------------------------------------------------------------------------
--- Installs the stubs as globals and returns a `require` shim that resolves
--- the module names the real scripts ask for via script.Parent:WaitForChild.
function Stubs.install(moduleDir)
	local g = getfenv and getfenv(0) or _G

	_G.Vector3 = Stubs.Vector3
	_G.Vector2 = Stubs.Vector2
	_G.CFrame = Stubs.CFrame
	_G.Color3 = Stubs.Color3
	_G.NumberRange = Stubs.NumberRange
	_G.UDim = Stubs.UDim
	_G.Enum = Stubs.Enum
	_G.typeof = function(value)
		if type(value) == "table" then
			if getmetatable(value) == CFrame then return "CFrame" end
			if getmetatable(value) == Vector3 then return "Vector3" end
		end
		return type(value)
	end

	-- NOTE: math is frozen in the standalone Luau sandbox, so math.noise
	-- cannot be installed globally. Tests that need it use Stubs.noise
	-- directly. None of the modules under test call math.noise.

	return g
end

Stubs.CFrameMeta = CFrame
Stubs.Vector3Meta = Vector3

return Stubs
