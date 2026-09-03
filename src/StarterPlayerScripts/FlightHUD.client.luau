--[[
	FlightHUD
	==========================================================================
	The cockpit readout. Builds its own ScreenGui at runtime and polls
	ShipState each frame -- it has no knowledge of FlightClient, remotes or
	the flight model, so it can be restyled or replaced without touching any
	gameplay code.

	Layout:
	  top left      telemetry block (speed / altitude / distance / mode)
	  centre        crosshair
	  bottom centre contextual prompt (LANDING AVAILABLE, [E] EXIT SHIP, ...)
	  bottom right  throttle bar
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FlightConfig = require(Modules:WaitForChild("FlightConfig"))
local ShipState = require(Modules:WaitForChild("ShipState"))
local Protocol = require(Modules:WaitForChild("Protocol"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local HUD = FlightConfig.HUD
local STATE = Protocol.State

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------
--- 1240 -> "1,240"
local function comma(value: number): string
	local digits = tostring(math.max(0, math.floor(value)))
	local reversed = digits:reverse():gsub("(%d%d%d)", "%1,")
	return (reversed:reverse():gsub("^,", ""))
end

local function makePanel(name: string): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = HUD.Panel
	frame.BackgroundTransparency = HUD.PanelTransparency
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = HUD.Accent
	stroke.Transparency = 0.65
	stroke.Thickness = 1
	stroke.Parent = frame

	return frame
end

local function makeLabel(parent: Instance, name: string, size: UDim2, position: UDim2, textSize: number)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Font = HUD.Font
	label.TextSize = textSize
	label.TextColor3 = HUD.Accent
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.Parent = parent
	return label
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "FlightHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- Telemetry -------------------------------------------------------------
local telemetry = makePanel("Telemetry")
telemetry.Size = UDim2.new(0, 268, 0, 116)
telemetry.Position = UDim2.new(0, 24, 0, 24)
telemetry.Parent = gui

local ROWS = { "SPEED", "ALTITUDE", "DISTANCE TO PLANET", "FLIGHT MODE" }
local rowValues: { [string]: TextLabel } = {}

for index, title in ROWS do
	local y = 10 + (index - 1) * 25

	local key = makeLabel(telemetry, title .. "Key", UDim2.new(0, 170, 0, 20), UDim2.new(0, 12, 0, y), 12)
	key.Text = title
	key.TextTransparency = 0.45

	local value = makeLabel(telemetry, title .. "Value", UDim2.new(0, 110, 0, 20), UDim2.new(1, -122, 0, y), 14)
	value.TextXAlignment = Enum.TextXAlignment.Right
	rowValues[title] = value
end

-- Crosshair -------------------------------------------------------------
local crosshair = Instance.new("Frame")
crosshair.Name = "Crosshair"
crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
crosshair.Position = UDim2.fromScale(0.5, 0.5)
crosshair.Size = UDim2.fromOffset(3, 3)
crosshair.BackgroundColor3 = HUD.Accent
crosshair.BackgroundTransparency = 0.2
crosshair.BorderSizePixel = 0
crosshair.Parent = gui

for _, spec in {
	{ UDim2.fromOffset(1, 14), UDim2.new(0.5, 0, 0.5, -22), Vector2.new(0.5, 0.5) },
	{ UDim2.fromOffset(1, 14), UDim2.new(0.5, 0, 0.5, 22), Vector2.new(0.5, 0.5) },
	{ UDim2.fromOffset(14, 1), UDim2.new(0.5, -22, 0.5, 0), Vector2.new(0.5, 0.5) },
	{ UDim2.fromOffset(14, 1), UDim2.new(0.5, 22, 0.5, 0), Vector2.new(0.5, 0.5) },
} do
	local tick = Instance.new("Frame")
	tick.Size = spec[1]
	tick.Position = spec[2]
	tick.AnchorPoint = spec[3]
	tick.BackgroundColor3 = HUD.Accent
	tick.BackgroundTransparency = 0.55
	tick.BorderSizePixel = 0
	tick.Parent = gui
end

-- Prompt ----------------------------------------------------------------
local prompt = makePanel("Prompt")
prompt.Size = UDim2.new(0, 320, 0, 66)
prompt.AnchorPoint = Vector2.new(0.5, 1)
prompt.Position = UDim2.new(0.5, 0, 1, -60)
prompt.Visible = false
prompt.Parent = gui

local promptTitle = makeLabel(prompt, "Title", UDim2.new(1, 0, 0, 24), UDim2.new(0, 0, 0, 10), 16)
promptTitle.TextXAlignment = Enum.TextXAlignment.Center

local promptAction = makeLabel(prompt, "Action", UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 0, 34), 14)
promptAction.TextXAlignment = Enum.TextXAlignment.Center
promptAction.TextColor3 = HUD.Good

-- Throttle --------------------------------------------------------------
local throttlePanel = makePanel("Throttle")
throttlePanel.Size = UDim2.new(0, 26, 0, 150)
throttlePanel.AnchorPoint = Vector2.new(1, 1)
throttlePanel.Position = UDim2.new(1, -28, 1, -60)
throttlePanel.Parent = gui

local throttleFill = Instance.new("Frame")
throttleFill.Name = "Fill"
throttleFill.AnchorPoint = Vector2.new(0.5, 1)
throttleFill.Position = UDim2.new(0.5, 0, 1, -4)
throttleFill.Size = UDim2.new(1, -8, 0, 0)
throttleFill.BackgroundColor3 = HUD.Accent
throttleFill.BorderSizePixel = 0
throttleFill.Parent = throttlePanel

local throttleCorner = Instance.new("UICorner")
throttleCorner.CornerRadius = UDim.new(0, 2)
throttleCorner.Parent = throttleFill

local boostLabel = makeLabel(gui, "Boost", UDim2.new(0, 120, 0, 20), UDim2.new(1, -160, 1, -36), 13)
boostLabel.AnchorPoint = Vector2.new(0, 1)
boostLabel.TextXAlignment = Enum.TextXAlignment.Right
boostLabel.TextColor3 = HUD.Warning
boostLabel.Text = ""

--------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------
--- What the prompt should say right now, or nil to hide it.
local function getPrompt(): (string?, string?, Color3?)
	if ShipState.State == STATE.OnFoot then
		if ShipState.NearShip then
			return "SHIP IN RANGE", "[E] ENTER SHIP", HUD.Good
		end
		return nil, nil, nil
	end

	if ShipState.State == STATE.Landed then
		return "STATUS: LANDED", "[E] EXIT SHIP    [SPACE] TAKE OFF", HUD.Good
	end

	if ShipState.State == STATE.Landing then
		return "LANDING SEQUENCE", "STAND BY", HUD.Warning
	end

	if ShipState.CanLand then
		return "LANDING AVAILABLE", "[F] LAND", HUD.Good
	end

	-- Below the landing ceiling but something is stopping us: say what.
	if ShipState.Altitude <= FlightConfig.Phases.Landing and ShipState.LandBlockReason ~= "" then
		return "LANDING UNAVAILABLE", ShipState.LandBlockReason, HUD.Warning
	end

	return nil, nil, nil
end

local function update()
	if not ShipState.Ready then
		return
	end

	local onFoot = ShipState.State == STATE.OnFoot

	telemetry.Visible = not onFoot
	throttlePanel.Visible = not onFoot
	crosshair.Visible = not onFoot

	if not onFoot then
		rowValues["SPEED"].Text = comma(ShipState.Speed)
		rowValues["ALTITUDE"].Text = comma(math.min(ShipState.Altitude, ShipState.GroundDistance))
		rowValues["DISTANCE TO PLANET"].Text = comma(ShipState.Altitude)
		rowValues["FLIGHT MODE"].Text = ShipState.State

		-- Colour the mode line by how committed the descent is.
		local modeColor = HUD.Accent
		if ShipState.State == STATE.LandingAvailable or ShipState.State == STATE.Landed then
			modeColor = HUD.Good
		elseif ShipState.State == STATE.Atmosphere or ShipState.State == STATE.Landing then
			modeColor = HUD.Warning
		end
		rowValues["FLIGHT MODE"].TextColor3 = modeColor

		local throttle = math.clamp(ShipState.Throttle, -1, 1)
		throttleFill.Size = UDim2.new(1, -8, math.abs(throttle) * 0.94, 0)
		throttleFill.BackgroundColor3 = throttle < 0 and HUD.Warning or HUD.Accent
		boostLabel.Text = ShipState.Boosting and "BOOST" or ""
	end

	local title, action, color = getPrompt()
	if title then
		prompt.Visible = true
		promptTitle.Text = title
		promptTitle.TextColor3 = color or HUD.Accent
		promptAction.Text = action or ""
		promptAction.TextColor3 = color or HUD.Good
	else
		prompt.Visible = false
	end
end

RunService.RenderStepped:Connect(update)
