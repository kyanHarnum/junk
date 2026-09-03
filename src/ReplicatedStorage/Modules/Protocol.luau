--[[
	Protocol
	==========================================================================
	Names of every message that crosses the client/server boundary.

	Both remotes use a single "kind" string as their first argument so the
	whole prototype needs only two RemoteEvents. Using constants instead of
	raw strings means a typo is a nil index rather than a silently ignored
	message.
]]

local Protocol = {}

-- FlightRemote: continuous ship state.
Protocol.Flight = {
	-- server -> client
	ShipReady = "ShipReady",       -- (shipModel: Model, spawnCFrame: CFrame)
	StateChanged = "StateChanged", -- (state: string)
	Correction = "Correction",     -- (cframe: CFrame, velocity: Vector3)

	-- client -> server
	Sync = "Sync",                 -- (cframe: CFrame, velocity: Vector3)
}

-- LandingRemote: discrete, validated actions.
Protocol.Landing = {
	-- client -> server
	RequestLand = "RequestLand",   -- ()
	LandComplete = "LandComplete", -- (finalCFrame: CFrame)
	ExitShip = "ExitShip",         -- ()
	EnterShip = "EnterShip",       -- ()
	TakeOff = "TakeOff",           -- ()

	-- server -> client
	LandApproved = "LandApproved", -- (targetCFrame: CFrame)
	LandDenied = "LandDenied",     -- (reason: string)
	Landed = "Landed",             -- ()
	Exited = "Exited",             -- ()
	Entered = "Entered",           -- ()
	TookOff = "TookOff",           -- ()
}

-- Flight states shared by client and server.
Protocol.State = {
	Space = "SPACE",
	Approach = "PLANET APPROACH",
	Atmosphere = "ATMOSPHERE",
	LandingAvailable = "LANDING AVAILABLE",
	Landing = "LANDING",
	Landed = "LANDED",
	OnFoot = "ON FOOT",
}

return Protocol
