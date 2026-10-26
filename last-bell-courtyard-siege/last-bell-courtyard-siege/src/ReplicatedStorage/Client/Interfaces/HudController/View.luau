--!strict
local State = require(script.Parent.State)
local View = {}
local ivory = Color3.fromRGB(218, 215, 199)
local dark = Color3.fromRGB(23, 29, 27)
local green = Color3.fromRGB(163, 198, 83)
local red = Color3.fromRGB(216, 58, 54)
local function label(parent: Instance, name: string, y: number, height: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.BackgroundTransparency = 1
	text.Position = UDim2.new(0, 14, 0, y)
	text.Size = UDim2.new(1, -28, 0, height)
	text.Font = Enum.Font.GothamMedium
	text.TextColor3 = ivory
	text.TextScaled = true
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	local cap = Instance.new("UITextSizeConstraint")
	cap.MinTextSize = 10
	cap.MaxTextSize = 18
	cap.Parent = text
	text.Parent = parent
	return text
end
function View.build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "HudController"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local panel = Instance.new("Frame")
	panel.Name = "SurvivalPanel"
	panel.Position = UDim2.new(0.03, 0, 0.025, 0)
	panel.Size = UDim2.new(0.94, 0, 0, 292)
	panel.BackgroundColor3 = dark
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.Parent = screen
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(500, 292)
	limit.Parent = panel
	local accent = Instance.new("Frame")
	accent.Name = "PhaseAccent"
	accent.Size = UDim2.new(1, 0, 0, 4)
	accent.BorderSizePixel = 0
	accent.Parent = panel
	local brand = label(panel, "Brand", 12, 18)
	brand.Text = "DEAD PERIOD  /  SQUAD SURVIVAL"
	brand.TextColor3 = green
	local heading = label(panel, "Phase", 38, 30)
	local clock = label(panel, "Clock", 74, 24)
	local meters = label(panel, "Meters", 106, 28)
	local supplies = label(panel, "Supplies", 142, 40)
	local objective = label(panel, "Objective", 190, 46)
	local noise = label(panel, "Noise", 244, 36)
	local footer = Instance.new("Frame")
	footer.Name = "Actions"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0.03, 0, 0.98, 0)
	footer.Size = UDim2.new(0.94, 0, 0, 168)
	footer.BackgroundColor3 = dark
	footer.BackgroundTransparency = 0.08
	footer.BorderSizePixel = 0
	footer.Parent = screen
	local actionLimit = Instance.new("UISizeConstraint")
	actionLimit.MaxSize = Vector2.new(500, 168)
	actionLimit.Parent = footer
	local feedback = label(footer, "Feedback", 8, 38)
	local hint = label(footer, "InputHint", 146, 16)
	hint.Text = "Tap / click • keyboard • gamepad selection"
	local buttons: { [string]: TextButton } = {}
	local names = { "Melee", "Revive", "Medkit", "Ration", "Water", "Molotov" }
	local keys = { "F / RT", "R / X", "1 / ↑", "2 / ←", "3 / ↓", "4 / →" }
	for i, name in names do
		local button = Instance.new("TextButton")
		button.Name = name
		button.Position = UDim2.new((i - 1) % 3 / 3, 6, 0, 52 + math.floor((i - 1) / 3) * 46)
		button.Size = UDim2.new(1 / 3, -12, 0, 40)
		button.BackgroundColor3 = Color3.fromRGB(57, 67, 59)
		button.TextColor3 = ivory
		button.Font = Enum.Font.GothamBold
		button.TextScaled = true
		button.TextWrapped = true
		button.Text = name .. "\n" .. keys[i]
		button.Selectable = true
		button.Parent = footer
		local cap = Instance.new("UITextSizeConstraint")
		cap.MinTextSize = 10
		cap.MaxTextSize = 16
		cap.Parent = button
		buttons[name] = button
	end
	local function apply(s: State.Snapshot)
		accent.BackgroundColor3 = if s.phase == "Night" then red else green
		heading.Text = string.upper(s.mode) .. " / DAY " .. tostring(s.day)
		clock.Text = s.phase .. " " .. State.clock(s.seconds) .. "  •  Nights " .. tostring(s.nights) .. "/10"
		meters.Text = string.format("HUNGER %d   WATER %d   INFECTION %d", s.hunger, s.thirst, s.infection)
		local entries = {}
		for _, item in { "Scrap", "Medkit", "Ration", "Water", "Molotov", "Keycard", "Radio", "Fuel" } do
			table.insert(entries, item .. " " .. tostring(s.inventory[item] or 0))
		end
		supplies.Text = table.concat(entries, "  ·  ")
		if s.mode == "Downed" then
			objective.Text = "DOWNED / " .. State.clock(s.revive) .. "\nWaiting for a nearby teammate to revive you."
		elseif s.mode == "Result" then
			objective.Text = s.outcome .. " / Shared squad outcome\nAutomatic restart: " .. State.clock(s.seconds)
		elseif s.mode == "Evacuating" then
			objective.Text = "Roof / " .. s.evac .. "\n" .. s.assembly
		elseif s.mode == "Defending" then
			objective.Text = "Night " .. tostring(s.day) .. " siege / Protect teammates.\nRepair damaged barricades at their prompts."
		else
			objective.Text = (if s.roof then "Keycard secured" else "Find the office keycard") .. " / " .. (if s.provisioned then "Radio + fuel deposited" else "Deposit radio + fuel in Commons")
		end
		noise.Text = s.noise
		feedback.Text = s.feedback
		feedback.TextColor3 = if s.success then ivory else Color3.fromRGB(255, 164, 146)
	end
	apply(State.initial())
	return { screen = screen, apply = apply, buttons = buttons }
end
return table.freeze(View)
