--[[
	AtmosphereController
	==========================================================================
	Turns one number -- ShipState.AtmosphereFactor, which runs 0 at the
	atmosphere boundary to 1 at the surface -- into the whole sensation of
	entering a planet's air.

	Everything here is client-only. Lighting property changes never replicate,
	which is exactly what a space game needs: two players at different
	altitudes each get their own correct sky from the same server.

	What is driven, all off that single ramp so nothing ever pops in alone:
	  ClockTime      night (deep space) -> daylight (inside the air)
	  Fog            effectively infinite -> a few thousand studs of haze
	  Atmosphere     density, haze and glare fade up
	  Bloom          brighter as the air scatters light
	  ColorCorrect   slight warm shift and saturation lift on entry
	  Screen glow    a re-entry vignette, keyed to speed as well as density
	  Speed streaks  particles ripping past the cockpit
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FlightConfig = require(Modules:WaitForChild("FlightConfig"))
local ShipState = require(Modules:WaitForChild("ShipState"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local FX = FlightConfig.Effects
local PLANET = FlightConfig.Planet

--------------------------------------------------------------------------
-- Post-processing instances (created once, animated forever)
--------------------------------------------------------------------------
local function ensure(className: string, name: string): Instance
	local existing = Lighting:FindFirstChild(name)
	if existing then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = Lighting
	return instance
end

local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or ensure("Atmosphere", "PlanetAtmosphere")
local bloom = ensure("BloomEffect", "SpaceBloom") :: BloomEffect
bloom.Intensity = FX.BloomSpace
bloom.Size = 24
bloom.Threshold = 0.92

local colorCorrection = ensure("ColorCorrectionEffect", "SpaceColorCorrection") :: ColorCorrectionEffect
colorCorrection.Brightness = 0
colorCorrection.Contrast = 0.05
colorCorrection.Saturation = 0

--------------------------------------------------------------------------
-- Re-entry vignette
--------------------------------------------------------------------------
local glowGui = Instance.new("ScreenGui")
glowGui.Name = "AtmosphericEntry"
glowGui.ResetOnSpawn = false
glowGui.IgnoreGuiInset = true
glowGui.DisplayOrder = -1 -- always behind the HUD
glowGui.Parent = playerGui

local glow = Instance.new("Frame")
glow.Name = "Glow"
glow.Size = UDim2.fromScale(1, 1)
glow.BackgroundColor3 = Color3.fromRGB(255, 132, 54)
glow.BackgroundTransparency = 1
glow.BorderSizePixel = 0
glow.Parent = glowGui

-- A radial-ish gradient: transparent through the middle, hot at the edges,
-- so it reads as heat around the canopy rather than an orange filter.
local gradient = Instance.new("UIGradient")
gradient.Rotation = 90
gradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0.00, 0.15),
	NumberSequenceKeypoint.new(0.38, 1.00),
	NumberSequenceKeypoint.new(0.62, 1.00),
	NumberSequenceKeypoint.new(1.00, 0.25),
})
gradient.Parent = glow

--------------------------------------------------------------------------
-- Speed streaks
--------------------------------------------------------------------------
-- Created on the client and parented to the ship, so it costs no replication
-- and other players never see your personal air rushing past.
local streaks: ParticleEmitter? = nil

local function ensureStreaks()
	if streaks and streaks.Parent then
		return
	end
	local ship = ShipState.Ship
	if not ship then
		return
	end
	local origin = ship.PrimaryPart and ship.PrimaryPart:FindFirstChild("EffectOrigin")
	if not origin then
		return
	end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "SpeedStreaks"
	emitter.Enabled = true
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.28, 0.5)
	emitter.Speed = NumberRange.new(0, 0)
	emitter.Drag = 0
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0.0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0.0, 1.0),
		NumberSequenceKeypoint.new(0.2, 0.25),
		NumberSequenceKeypoint.new(1.0, 1.0),
	})
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 214, 178))
	emitter.LightEmission = 0.8
	emitter.LightInfluence = 0
	emitter.SpreadAngle = Vector2.new(24, 24)
	-- Squashed along its travel direction: this is what makes a dot read as
	-- a streak instead of a snowflake.
	emitter.Squash = NumberSequence.new(3)
	emitter.Parent = origin

	streaks = emitter
end

--------------------------------------------------------------------------
-- Smoothed follow
--------------------------------------------------------------------------
-- The effects chase the target value rather than snapping to it. Combined
-- with the smoothstep already inside GetAtmosphereFactor, this is what makes
-- entry feel like a transition instead of a switch being flipped.
local smoothed = 0
local smoothedApproach = 0

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function onRenderStep(dt: number)
	if not ShipState.Ready then
		return
	end

	local alpha = math.clamp(FX.TransitionResponse * dt, 0, 1)
	smoothed = lerp(smoothed, ShipState.AtmosphereFactor, alpha)
	smoothedApproach = lerp(smoothedApproach, ShipState.ApproachFactor, alpha)

	----------------------------------------------------------------------
	-- Sky and fog.
	----------------------------------------------------------------------
	Lighting.ClockTime = lerp(FX.SpaceClockTime, FX.SurfaceClockTime, smoothed)

	-- Fog end is interpolated in log space; a linear ramp from 1e6 would
	-- spend the entire descent doing nothing visible and then collapse.
	local logSpace = math.log(FX.FogEndSpace)
	local logSurface = math.log(FX.FogEndSurface)
	Lighting.FogEnd = math.exp(lerp(logSpace, logSurface, smoothed))
	Lighting.FogStart = Lighting.FogEnd * 0.15

	Lighting.Brightness = lerp(2.2, 3.0, smoothed)
	Lighting.OutdoorAmbient = Color3.fromRGB(24, 28, 40):Lerp(Color3.fromRGB(128, 138, 156), smoothed)

	----------------------------------------------------------------------
	-- Volumetric atmosphere.
	----------------------------------------------------------------------
	atmosphere.Density = FX.AtmosphereDensity * smoothed
	atmosphere.Haze = FX.AtmosphereHaze * smoothed
	atmosphere.Glare = FX.AtmosphereGlare * smoothed
	atmosphere.Decay = PLANET.AtmosphereColor

	----------------------------------------------------------------------
	-- Post-processing. The approach factor adds a hint of bloom before entry
	-- so the planet starts feeling present while still out in vacuum.
	----------------------------------------------------------------------
	bloom.Intensity = lerp(FX.BloomSpace, FX.BloomAtmosphere, math.max(smoothed, smoothedApproach * 0.35))
	colorCorrection.Saturation = lerp(-0.05, 0.12, smoothed)
	colorCorrection.Contrast = lerp(0.05, 0.12, smoothed)
	colorCorrection.TintColor = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(255, 240, 226), smoothed)

	----------------------------------------------------------------------
	-- Re-entry heat: needs BOTH air and speed, so a slow descent is calm and
	-- a fast one burns.
	----------------------------------------------------------------------
	local heat = smoothed * math.clamp(ShipState.Speed / FX.EntryGlowSpeed, 0, 1)
	glow.BackgroundTransparency = 1 - (heat * 0.55)

	----------------------------------------------------------------------
	-- Speed streaks.
	----------------------------------------------------------------------
	ensureStreaks()
	if streaks then
		streaks.Rate = FX.SpeedStreakRate * heat
		-- Particles are spawned stationary in world space; the ship flying
		-- past them is what creates the streak, so no velocity is needed.
		streaks.Lifetime = NumberRange.new(0.2, 0.35 + 0.3 * smoothed)
	end
end

RunService.RenderStepped:Connect(onRenderStep)
