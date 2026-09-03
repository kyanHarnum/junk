--[[
	PlanetServer
	==========================================================================
	Builds the entire world at server start: the planet sphere, its glow
	shells, the procedurally generated terrain cap you can actually land on,
	the starfield, the sun, and the baseline Lighting.

	Nothing here is pre-authored in Studio -- run the place and the world
	assembles itself, which keeps the whole project as text in git.

	Signals readiness with the Workspace attribute "PlanetReady" so
	SpaceGameServer never spawns a ship into an empty void.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FlightConfig = require(Modules:WaitForChild("FlightConfig"))

local PLANET = FlightConfig.Planet
local LZ = PLANET.LandingZone
local SPACE = FlightConfig.Space
local EFFECTS = FlightConfig.Effects

local PART_SIZE_LIMIT = 2048

--------------------------------------------------------------------------
-- Config sanity checks. Fail loudly at startup rather than mysteriously
-- later: a Part silently clamps to 2048 studs and you would spend an hour
-- wondering why the atmosphere shell looks wrong.
--------------------------------------------------------------------------
local function validateConfig()
	local shellDiameter = PLANET.Radius * 2 * PLANET.AtmosphereShellScale
	assert(
		shellDiameter <= PART_SIZE_LIMIT,
		string.format(
			"FlightConfig.Planet: Radius * 2 * AtmosphereShellScale is %.0f studs, but a Part caps at %d. "
				.. "Lower Radius or AtmosphereShellScale.",
			shellDiameter,
			PART_SIZE_LIMIT
		)
	)

	local voxel = LZ.VoxelSize
	for _, axis in { PLANET.Center.X, PLANET.Center.Y, PLANET.Center.Z } do
		assert(axis % voxel == 0, "FlightConfig.Planet.Center must align to the terrain voxel grid (multiples of " .. voxel .. ")")
	end
	assert(LZ.ChunkStuds % voxel == 0, "LandingZone.ChunkStuds must be a multiple of VoxelSize")
	assert((LZ.HalfWidth * 2) % LZ.ChunkStuds == 0, "LandingZone.HalfWidth*2 must divide evenly by ChunkStuds")
	assert(LZ.Direction.Unit:Dot(Vector3.yAxis) > 0.99, "LandingZone.Direction must be (0,1,0) until custom gravity exists")
end

--------------------------------------------------------------------------
-- Planet body
--------------------------------------------------------------------------
local function buildPlanetBody(): Model
	local model = Instance.new("Model")
	model.Name = "Planet"

	-- The solid body. This is what you see from space and what stops you
	-- flying through the planet; the terrain cap sits on top of it.
	local surface = Instance.new("Part")
	surface.Name = "Surface"
	surface.Shape = Enum.PartType.Ball
	surface.Size = Vector3.one * (PLANET.Radius * 2)
	surface.Position = PLANET.Center
	surface.Anchored = true
	surface.CanCollide = true
	surface.Color = PLANET.SurfaceColor
	surface.Material = PLANET.SurfaceMaterial
	surface.TopSurface = Enum.SurfaceType.Smooth
	surface.BottomSurface = Enum.SurfaceType.Smooth
	surface.Parent = model
	model.PrimaryPart = surface

	-- Two nested translucent shells give the planet a soft rim of air when
	-- viewed from outside. Neon at high transparency reads as glow; the
	-- ForceField shell adds the outer haze.
	local inner = Instance.new("Part")
	inner.Name = "AtmosphereInner"
	inner.Shape = Enum.PartType.Ball
	inner.Size = Vector3.one * (PLANET.Radius * 2 * 1.03)
	inner.Position = PLANET.Center
	inner.Anchored = true
	inner.CanCollide = false
	inner.CanQuery = false      -- must never block a landing probe
	inner.CanTouch = false
	inner.CastShadow = false
	inner.Transparency = 0.92
	inner.Color = PLANET.AtmosphereRimColor
	inner.Material = Enum.Material.Neon
	inner.Parent = model

	local outer = inner:Clone()
	outer.Name = "AtmosphereOuter"
	outer.Size = Vector3.one * (PLANET.Radius * 2 * PLANET.AtmosphereShellScale)
	outer.Transparency = 0.78
	outer.Color = PLANET.AtmosphereColor
	outer.Material = Enum.Material.ForceField
	outer.Parent = model

	model.Parent = Workspace
	return model
end

--------------------------------------------------------------------------
-- Terrain
--------------------------------------------------------------------------
-- Layered Perlin noise. Five octaves at halving amplitude gives broad
-- landforms with fine detail on top, normalised back into -1..1.
local function fractalNoise(x: number, z: number, seedOffset: number): number
	local total, amplitude, normaliser = 0, 1, 0
	local frequency = 1 / LZ.NoiseScale
	local seed = (LZ.Seed % 1000) + seedOffset

	for _ = 1, LZ.Octaves do
		total += math.noise(x * frequency, z * frequency, seed) * amplitude
		normaliser += amplitude
		amplitude *= 0.5
		frequency *= 2.03
	end

	return total / normaliser
end

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

--- Height of the terrain above the ideal sphere at a point on the cap.
--- x and z are relative to the planet centre.
local function elevationAt(x: number, z: number): number
	local distance = math.sqrt(x * x + z * z)

	-- Fade the whole cap out at its rim so terrain tucks under the sphere
	-- instead of ending in a visible cliff. Past the rim it goes slightly
	-- NEGATIVE, hiding the seam inside the sphere entirely.
	local edge = smoothstep((LZ.HalfWidth - distance) / (LZ.HalfWidth * LZ.RimFade))

	-- Keep a flat apron around the pole so the player's first landing is not
	-- into the side of a mountain. Full-height terrain begins at twice
	-- FlattenPad out.
	local pad = smoothstep((distance - LZ.FlattenPad) / LZ.FlattenPad)

	-- Two noise fields: rolling hills, plus ridged noise for mountain spines.
	local rolling = fractalNoise(x, z, 0) * 0.5 + 0.5                        -- 0..1
	local ridged = 1 - math.abs(fractalNoise(x * 0.45 + 512, z * 0.45 - 512, 37)) -- 0..1

	-- Powers push the distributions apart: broad flats and plains from the
	-- rolling term, sharp peaks from the ridged term.
	local height = (rolling ^ 1.7) * 0.65 + (ridged ^ 3) * 0.35

	-- BaseLift keeps even the dead-flat apron proud of the sphere underneath,
	-- so the crust always occludes it instead of z-fighting.
	return height * LZ.MaxElevation * edge * pad + LZ.BaseLift * edge - 4 * (1 - edge)
end

--- Distance from the planet centre out to the terrain surface, expressed as
--- a world Y coordinate (the cap sits on the +Y pole).
local function surfaceYAt(x: number, z: number): number
	local r2 = x * x + z * z
	local sphere = math.sqrt(math.max(PLANET.Radius * PLANET.Radius - r2, 1))
	return sphere + elevationAt(x, z)
end

local function materialFor(surfaceY: number, sphereY: number, slopeDegrees: number): Enum.Material
	if slopeDegrees > 42 then
		return Enum.Material.Rock -- exposed cliff faces
	end
	local relative = (surfaceY - sphereY) / LZ.MaxElevation
	if relative > 0.72 then
		return Enum.Material.Snow
	elseif relative > 0.42 then
		return Enum.Material.Rock
	elseif relative > 0.14 then
		return Enum.Material.Ground
	end
	return Enum.Material.Sand
end

--- Writes the walkable terrain cap.
---
--- Uses WriteVoxels rather than thousands of FillBlock calls: one bulk write
--- per 64x64 stud chunk, with per-voxel occupancy so the surface comes out
--- smooth instead of stair-stepped. Each chunk only spans the Y range its
--- own columns need, which keeps the arrays small.
local function generateTerrainCap()
	local terrain = Workspace.Terrain
	terrain:Clear()

	local voxel = LZ.VoxelSize
	local chunk = LZ.ChunkStuds
	local half = LZ.HalfWidth
	local centre = PLANET.Center
	local perAxis = chunk // voxel

	local startClock = os.clock()
	local chunksWritten = 0

	for chunkX = -half, half - chunk, chunk do
		for chunkZ = -half, half - chunk, chunk do
			-- Pass 1: column heights and materials for this chunk.
			local heights, materials = {}, {}
			local minSurface, maxSurface = math.huge, -math.huge

			for i = 1, perAxis do
				heights[i], materials[i] = {}, {}
				local worldX = chunkX + (i - 0.5) * voxel

				for k = 1, perAxis do
					local worldZ = chunkZ + (k - 0.5) * voxel
					local surfaceY = surfaceYAt(worldX, worldZ)

					-- Central-difference slope, in studs of rise per stud of run.
					local dx = (surfaceYAt(worldX + voxel, worldZ) - surfaceYAt(worldX - voxel, worldZ)) / (2 * voxel)
					local dz = (surfaceYAt(worldX, worldZ + voxel) - surfaceYAt(worldX, worldZ - voxel)) / (2 * voxel)
					local slope = math.deg(math.atan(math.sqrt(dx * dx + dz * dz)))

					local sphereY = math.sqrt(math.max(PLANET.Radius ^ 2 - (worldX ^ 2 + worldZ ^ 2), 1))

					heights[i][k] = surfaceY
					materials[i][k] = materialFor(surfaceY, sphereY, slope)
					minSurface = math.min(minSurface, surfaceY)
					maxSurface = math.max(maxSurface, surfaceY)
				end
			end

			-- Pass 2: only span the Y range this chunk actually needs.
			local yMin = math.floor((minSurface - LZ.ShellThickness) / voxel) * voxel
			local yMax = math.ceil((maxSurface + voxel) / voxel) * voxel
			local yCount = (yMax - yMin) // voxel

			if yCount > 0 then
				local region = Region3.new(
					centre + Vector3.new(chunkX, yMin, chunkZ),
					centre + Vector3.new(chunkX + chunk, yMax, chunkZ + chunk)
				):ExpandToGrid(voxel)

				local materialGrid, occupancyGrid = {}, {}
				for i = 1, perAxis do
					local matColumn, occColumn = {}, {}
					materialGrid[i], occupancyGrid[i] = matColumn, occColumn

					for j = 1, yCount do
						local matRow, occRow = {}, {}
						matColumn[j], occColumn[j] = matRow, occRow
						-- Heights are measured from the planet centre, so the
						-- voxel bottom is compared in that same frame.
						local voxelBottom = yMin + (j - 1) * voxel

						for k = 1, perAxis do
							-- Fractional occupancy is what makes the surface
							-- smooth: a voxel the surface passes halfway
							-- through is half full, not empty or solid.
							local fill = math.clamp((heights[i][k] - voxelBottom) / voxel, 0, 1)
							occRow[k] = fill
							matRow[k] = fill > 0 and materials[i][k] or Enum.Material.Air
						end
					end
				end

				terrain:WriteVoxels(region, voxel, materialGrid, occupancyGrid)
				chunksWritten += 1
			end

			-- Yield periodically so the server stays responsive while building.
			if chunksWritten % 4 == 0 then
				task.wait()
			end
		end
	end

	-- An alien palette, applied to the stock materials.
	terrain:SetMaterialColor(Enum.Material.Sand, Color3.fromRGB(168, 122, 84))
	terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(112, 116, 72))
	terrain:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(104, 96, 106))
	terrain:SetMaterialColor(Enum.Material.Snow, Color3.fromRGB(214, 232, 240))

	print(string.format(
		"[PlanetServer] Terrain cap: %d chunks, %.0f x %.0f studs, %.2fs",
		chunksWritten, half * 2, half * 2, os.clock() - startClock
	))
end

--------------------------------------------------------------------------
-- Space dressing
--------------------------------------------------------------------------
local function buildSpace()
	local folder = Instance.new("Folder")
	folder.Name = "Space"

	-- Parallax stars. The Sky object already draws a static star field; these
	-- few hundred parts sit far out in world space so they shift slightly as
	-- you fly, which is what actually sells the sense of travel.
	local template = Instance.new("Part")
	template.Shape = Enum.PartType.Ball
	template.Anchored = true
	template.CanCollide = false
	template.CanQuery = false
	template.CanTouch = false
	template.CastShadow = false
	template.Material = Enum.Material.Neon

	local random = Random.new(LZ.Seed)
	local stars = Instance.new("Folder")
	stars.Name = "Stars"
	stars.Parent = folder

	for index = 1, SPACE.StarCount do
		local star = template:Clone()
		star.Name = "Star" .. index

		-- Uniform direction on a sphere, at a randomised shell radius.
		local direction = Vector3.new(
			random:NextNumber(-1, 1),
			random:NextNumber(-1, 1),
			random:NextNumber(-1, 1)
		)
		if direction.Magnitude < 1e-3 then
			direction = Vector3.yAxis
		end
		local radius = SPACE.StarShellRadius + random:NextNumber(0, SPACE.StarShellThickness)

		local size = random:NextNumber(SPACE.StarSizeRange.Min, SPACE.StarSizeRange.Max)
		star.Size = Vector3.one * size
		star.Position = PLANET.Center + direction.Unit * radius
		star.Color = SPACE.StarColors[random:NextInteger(1, #SPACE.StarColors)]
		star.Transparency = random:NextNumber(0, 0.35)
		star.Parent = stars
	end
	template:Destroy()

	-- A visible sun gives the player a fixed reference to orient against.
	local sun = Instance.new("Part")
	sun.Name = "Sun"
	sun.Shape = Enum.PartType.Ball
	sun.Size = Vector3.one * SPACE.SunSize
	sun.Position = PLANET.Center + SPACE.SunPosition
	sun.Anchored = true
	sun.CanCollide = false
	sun.CanQuery = false
	sun.CanTouch = false
	sun.CastShadow = false
	sun.Material = Enum.Material.Neon
	sun.Color = SPACE.SunColor
	sun.Parent = folder

	folder.Parent = Workspace
end

--------------------------------------------------------------------------
-- Lighting
--------------------------------------------------------------------------
--- Sets the baseline. From here the CLIENT takes over: AtmosphereController
--- drives ClockTime, fog and atmosphere density per player, so two players
--- at different altitudes each see their own correct sky.
local function setupLighting()
	Lighting.Ambient = Color3.fromRGB(12, 14, 22)
	Lighting.OutdoorAmbient = Color3.fromRGB(24, 28, 40)
	Lighting.Brightness = 2.2
	Lighting.ClockTime = EFFECTS.SpaceClockTime
	Lighting.GeographicLatitude = 12
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.1
	Lighting.EnvironmentSpecularScale = 0.1
	Lighting.ExposureCompensation = 0
	Lighting.FogStart = 0
	Lighting.FogEnd = EFFECTS.FogEndSpace
	Lighting.FogColor = EFFECTS.FogColorSurface

	local sky = Lighting:FindFirstChildOfClass("Sky") or Instance.new("Sky")
	sky.StarCount = SPACE.SkyStarCount
	sky.CelestialBodiesShown = false -- we render our own sun as a part
	sky.Parent = Lighting

	-- Created here at zero density so the client only has to animate it,
	-- never construct it mid-flight.
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmosphere.Density = 0
	atmosphere.Offset = 0
	atmosphere.Color = Color3.fromRGB(199, 209, 224)
	atmosphere.Decay = PLANET.AtmosphereColor
	atmosphere.Glare = 0
	atmosphere.Haze = 0
	atmosphere.Parent = Lighting
end

--------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------
validateConfig()

-- Nothing in this prototype should ever be destroyed for falling, and the
-- distances involved are far outside the default streaming envelope.
Workspace.FallenPartsDestroyHeight = -50000

setupLighting()
buildPlanetBody()
buildSpace()
generateTerrainCap()

Workspace:SetAttribute("PlanetReady", true)
print("[PlanetServer] World ready: " .. PLANET.Name)
