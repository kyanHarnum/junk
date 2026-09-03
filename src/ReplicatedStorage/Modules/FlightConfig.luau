--[[
	FlightConfig
	==========================================================================
	Single source of truth for every tunable number in the prototype.

	No other script should hard-code a gameplay value. If you want to change
	how the ship handles, how far away the atmosphere starts, or how big the
	planet is, this is the only file you need to open.

	Units: studs, studs/second, studs/second^2, radians/second, seconds.
]]

local FlightConfig = {}

--------------------------------------------------------------------------
-- PLANET
--------------------------------------------------------------------------
-- A Roblox Part is capped at 2048 studs on any axis, which bounds both the
-- planet sphere and its glow shell:
--     Radius * 2 * AtmosphereShellScale  <=  2048
-- PlanetServer asserts this at startup so a bad edit fails loudly.
FlightConfig.Planet = {
	Name = "KEPLER-9C",
	Center = Vector3.new(0, 0, 0), -- keep each component a multiple of 4 (terrain voxel grid)
	Radius = 900,
	AtmosphereShellScale = 1.12,

	SurfaceColor = Color3.fromRGB(126, 98, 76),
	SurfaceMaterial = Enum.Material.Slate,
	AtmosphereColor = Color3.fromRGB(84, 152, 255),
	AtmosphereRimColor = Color3.fromRGB(158, 208, 255),

	--[[
		The walkable terrain cap.

		Roblox gravity is a single global -Y vector, so the only region of a
		spherical planet a character can actually stand on is the cap around
		the north pole. Everything else would have you sliding off sideways.
		Leave Direction as (0, 1, 0) until custom gravity is implemented.
	]]
	LandingZone = {
		Direction = Vector3.new(0, 1, 0),
		HalfWidth = 320,       -- cap spans HalfWidth*2 studs in X and Z
		MaxElevation = 210,    -- tallest peak above the ideal sphere surface
		NoiseScale = 130,      -- larger = broader, smoother landforms
		Octaves = 5,
		Seed = 20260903,
		VoxelSize = 4,         -- terrain resolution (4 is the Roblox voxel size)
		ChunkStuds = 64,       -- terrain is written in chunks this wide; must divide HalfWidth*2
		ShellThickness = 88,   -- how deep the terrain crust is written below the surface
		FlattenPad = 70,       -- radius of flat ground kept at the pole for a first landing;
		                       -- terrain reaches full height by twice this distance out
		RimFade = 0.18,        -- fraction of HalfWidth over which the cap blends back into
		                       -- the bare sphere at its rim
		BaseLift = 6,          -- studs the flat pad sits proud of the sphere, so the crust
		                       -- covers the sphere instead of z-fighting with it
	},
}

--------------------------------------------------------------------------
-- SPACE DRESSING
--------------------------------------------------------------------------
FlightConfig.Space = {
	StarCount = 260,                          -- parallax stars; the Sky object supplies the rest
	-- Must sit well outside Spawn.Altitude + Planet.Radius, or the player
	-- starts inside the star field.
	StarShellRadius = 60000,
	StarShellThickness = 30000,
	StarSizeRange = NumberRange.new(150, 520),
	StarColors = {
		Color3.fromRGB(255, 255, 255),
		Color3.fromRGB(190, 214, 255),
		Color3.fromRGB(255, 226, 186),
		Color3.fromRGB(255, 186, 186),
	},
	SunPosition = Vector3.new(-42000, 26000, -34000),
	SunSize = 2000, -- a Part caps at 2048 studs
	SunColor = Color3.fromRGB(255, 236, 190),
	SkyStarCount = 3000,
}

--------------------------------------------------------------------------
-- SPAWN
--------------------------------------------------------------------------
FlightConfig.Spawn = {
	Altitude = 30000,                      -- studs above the planet SURFACE
	-- From the planet centre toward the spawn point. Kept close to the pole
	-- axis so flying straight at the planet brings you down onto the flat
	-- landing apron rather than the mountains at the cap's rim.
	Direction = Vector3.new(0, 1, 0.10),
}

--------------------------------------------------------------------------
-- SHIP HANDLING
--------------------------------------------------------------------------
FlightConfig.Ship = {
	MaxSpeed = 650,
	BoostMultiplier = 2.4,
	BoostAcceleration = 2.2,
	AtmosphereSpeedCap = 420,   -- air resistance caps you lower than in vacuum

	ThrustAcceleration = 300,
	ReverseAcceleration = 190,

	-- Drag is split so the ship "grips" the direction it is pointing. Low
	-- forward drag keeps the coasting/inertia feel of a spacecraft; high
	-- lateral drag stops it drifting sideways like a hockey puck.
	LinearDrag = 0.10,
	LateralDrag = 2.40,
	AtmosphereDragMultiplier = 2.2,

	ThrottleResponse = 3.2,     -- how fast the throttle ramps toward the key input

	YawSpeed = 1.15,            -- rad/s
	PitchSpeed = 1.25,
	RollSpeed = 2.30,
	RotationResponse = 6.0,     -- how fast actual rotation catches the requested rate

	MouseSteering = true,
	MouseSensitivity = 0.055,
	MousePitchInvert = false,

	AtmosphereGravity = 26,     -- gentle pull toward the planet once inside the air

	CockpitOffset = CFrame.new(0, 1.15, -2.1), -- where the pilot sits, ship-relative
	ReplicationRate = 1 / 15,   -- how often the client tells the server where it is
}

--------------------------------------------------------------------------
-- FLIGHT PHASES (altitude above the planet SURFACE, not the centre)
--------------------------------------------------------------------------
--[[
	Each band is sized for the time it should take to cross, not for physical
	realism -- the atmosphere band is several planetary radii deep because
	that is what gives the fog, sky and particle ramps room to breathe. See
	tests/Spec.luau, which asserts the whole descent lands in a playable
	window, and re-run it after changing any of these.

	Roughly, at the default ship tuning:
	  SPACE            18,000 studs   ~15s boosted
	  PLANET APPROACH   9,400 studs   ~15s
	  ATMOSPHERE        1,800 studs   ~10s decelerating
]]
FlightConfig.Phases = {
	Approach = 12000,    -- above this: SPACE
	Atmosphere = 2600,   -- below this: ATMOSPHERE
	Landing = 800,       -- landing may become available below this
}

--------------------------------------------------------------------------
-- LANDING
--------------------------------------------------------------------------
FlightConfig.Landing = {
	MaxSpeed = 95,            -- must be flying slower than this to land
	MaxGroundDistance = 300,  -- and no higher than this above the ground
	MaxSlope = 38,            -- degrees; steeper ground refuses the landing
	RestHeight = 5.5,         -- how high the ship's root sits above the surface
	ScrapeFriction = 0.4,     -- speed kept per frame when scraping the ground
	SequenceTime = 2.6,       -- seconds for the automatic touchdown glide
	ProbeDepth = 6000,        -- raycast length used to find the surface
	ExitOffset = Vector3.new(10, 0, 0), -- where the pilot steps out, ship-relative
	EnterRadius = 20,         -- how close you must be on foot to board again
	TakeoffBoost = 90,        -- upward kick when lifting off
}

--------------------------------------------------------------------------
-- CAMERA
--------------------------------------------------------------------------
FlightConfig.Camera = {
	Offset = Vector3.new(0, 6.0, 24),  -- ship-relative; +Z is behind the ship
	Stiffness = 9,
	LookAhead = 40,
	FovBase = 70,
	FovBoost = 92,
	FovResponse = 4,
	ShakeStartSpeed = 240,
	ShakeIntensity = 0.65,
}

--------------------------------------------------------------------------
-- VISUAL EFFECTS
--------------------------------------------------------------------------
FlightConfig.Effects = {
	SpaceClockTime = 0,        -- night sky = deep space
	SurfaceClockTime = 14.2,   -- daylight once you are down in the air
	AtmosphereDensity = 0.38,
	AtmosphereHaze = 2.6,
	AtmosphereGlare = 0.4,
	FogEndSpace = 1e6,
	FogEndSurface = 4200,
	FogColorSurface = Color3.fromRGB(150, 178, 214),
	BloomSpace = 0.5,
	BloomAtmosphere = 1.7,
	EntryGlowSpeed = 300,      -- speed at which the re-entry glow reaches full strength
	SpeedStreakRate = 240,
	TransitionResponse = 1.6,  -- how fast visuals chase their target values
}

--------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------
FlightConfig.HUD = {
	Accent = Color3.fromRGB(120, 220, 255),
	Warning = Color3.fromRGB(255, 168, 80),
	Good = Color3.fromRGB(140, 255, 190),
	Panel = Color3.fromRGB(6, 12, 20),
	PanelTransparency = 0.35,
	Font = Enum.Font.Code,
}

--------------------------------------------------------------------------
-- DEBUG
--------------------------------------------------------------------------
FlightConfig.Debug = {
	VerboseServer = false,
}

return FlightConfig
