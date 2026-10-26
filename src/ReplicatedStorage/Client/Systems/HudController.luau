--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")
local HudControllerView = require(ReplicatedStorage.Client.Interfaces.HudController.View)
local HudControllerState = require(ReplicatedStorage.Client.Interfaces.HudController.State)
local HudController = {}
local actions: { [string]: { kind: string, keyboard: Enum.KeyCode, gamepad: Enum.KeyCode } } = table.freeze({
	Melee = table.freeze({ kind = "Combat", keyboard = Enum.KeyCode.F, gamepad = Enum.KeyCode.ButtonR2 }),
	Revive = table.freeze({ kind = "Combat", keyboard = Enum.KeyCode.R, gamepad = Enum.KeyCode.ButtonX }),
	Medkit = table.freeze({ kind = "Item", keyboard = Enum.KeyCode.One, gamepad = Enum.KeyCode.DPadUp }),
	Ration = table.freeze({ kind = "Item", keyboard = Enum.KeyCode.Two, gamepad = Enum.KeyCode.DPadLeft }),
	Water = table.freeze({ kind = "Item", keyboard = Enum.KeyCode.Three, gamepad = Enum.KeyCode.DPadDown }),
	Molotov = table.freeze({ kind = "Item", keyboard = Enum.KeyCode.Four, gamepad = Enum.KeyCode.DPadRight }),
})
-- These slots are owned by server playback. WorldCue is visual feedback only;
-- replaying the same slot here would double it for the listener.
local cues: { [string]: string } = table.freeze({
	LockerSearch = "server", FurnitureScrape = "server", BarricadeHit = "server",
	CraftComplete = "server", NightBell = "server", BruteCharge = "server",
	StaffExplosion = "server", MeleeSwing = "server", ExtractionRotor = "server",
})
HudController.Actions = actions
HudController.Cues = cues
HudController.State = HudControllerState
function HudController.CueOwner(cue: string): string?
	return cues[cue]
end
function HudController.ProfileFor(phase: string): string
	return if phase == "Night" then "EmergencyNight" else "SicklyDay"
end
function HudController.ActionRequest(name: string, aim: Vector3, s: HudControllerState.Snapshot): { kind: string, name: string, aim: Vector3 }?
	local action = actions[name]
	if action == nil or s.downed or s.mode == "Result" then return nil end
	if aim.X ~= aim.X or aim.Y ~= aim.Y or aim.Z ~= aim.Z or aim.Magnitude == math.huge then return nil end
	return { kind = action.kind, name = name, aim = aim }
end
local started = false
local disconnectors: { () -> () } = {}
local cachedView: { screen: ScreenGui, apply: (HudControllerState.Snapshot) -> (), buttons: { [string]: TextButton } }? = nil
local state = HudControllerState.initial()
local warned: { [string]: boolean } = {}
local function missing(path: string)
	if warned[path] then return end
	warned[path] = true
	warn("HudController: missing " .. path .. "; skipping its side effects until available")
end
local function find(root: Instance, path: { string }): Instance?
	local current = root
	for _, name in path do
		local child = current:FindFirstChild(name)
		if child == nil then return nil end
		current = child
	end
	return current
end
function HudController.Start(): ()
	if started then return end
	local player = Players.LocalPlayer
	if player == nil then return end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		local found = player:WaitForChild("PlayerGui", 10)
		if found == nil or not found:IsA("PlayerGui") then missing("PlayerGui"); return end
		playerGui = found
	end
	-- Installed controllers are client-only: never require them on server spec load.
	local LightingController = require(ReplicatedStorage.Client.Systems.LightingController)
	local SoundController = require(ReplicatedStorage.Client.Systems.SoundController)
	local MusicController = require(ReplicatedStorage.Client.Systems.MusicController)
	local Screens = require(ReplicatedStorage.Packages.Screens)
	local Remotes = require(ReplicatedStorage.Shared.Network.Remotes)
	local Debris = game:GetService("Debris")
	local SoundUtil = require(ReplicatedStorage.Shared.Utils.SoundUtil)
	started = true
	state = HudControllerState.initial()
	if cachedView == nil then
		local created = HudControllerView.build()
		cachedView = created
		created.screen.Parent = playerGui
		Screens.register("HudController", "hud", created.screen)
	end
	local built = cachedView
	if built == nil then return end
	built.apply(state)
	Screens.show("HudController")
	-- SiegeScore intentionally has no track. Stop, never invent a fallback asset.
	MusicController:Stop(0.5)
	local function push(event: HudControllerState.Event)
		state = HudControllerState.transition(state, event)
		built.apply(state)
	end
	local function request(name: string)
		local camera = Workspace.CurrentCamera
		if camera == nil then return end
		local aim = camera.CFrame.Position + camera.CFrame.LookVector * 60
		local requestData = HudController.ActionRequest(name, aim, state)
		if requestData == nil then return end
		if requestData.kind == "Item" then
			Remotes.HudController.UseItem:fire({ Item = requestData.name, Aim = requestData.aim })
		else
			Remotes.HudController.CombatAction:fire({ Action = requestData.name, Aim = requestData.aim })
		end
	end
	for name, binding in actions do
		local connection = built.buttons[name].Activated:Connect(function() request(name) end)
		table.insert(disconnectors, function() connection:Disconnect() end)
		ContextActionService:BindAction("HudController/" .. name, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then request(name) end
			return Enum.ContextActionResult.Sink
		end, false, binding.keyboard, binding.gamepad)
	end
	table.insert(disconnectors, Remotes.SiegeService.SurvivalState:connect(function(payload)
		push({ kind = "Survival", hunger = payload.Hunger, thirst = payload.Thirst, infection = payload.Infection, downed = payload.Downed, revive = payload.ReviveSeconds })
	end))
	table.insert(disconnectors, Remotes.SupplyService.InventoryItem:connect(function(payload)
		push({ kind = "Inventory", item = payload.Item, count = payload.Count })
	end))
	table.insert(disconnectors, Remotes.SupplyService.SupplyFeedback:connect(function(payload)
		push({ kind = "Feedback", message = payload.Message, success = payload.Success })
	end))
	table.insert(disconnectors, Remotes.SiegeService.WorldCue:connect(function(payload)
		local owner = HudController.CueOwner(payload.Cue)
		if owner == nil then return end
		push({ kind = "Cue", cue = payload.Cue })
		-- No currently declared cue has client ownership. This integration is
		-- deliberately closed until the contract assigns a client-played slot.
		if owner ~= "client" then return end
		local sound = SoundController:PlayAtPosition(payload.Cue, payload.Position, false)
		if sound ~= nil then
			sound.SoundGroup = SoundUtil.getMasterGroup()
			if sound.Parent ~= nil then Debris:AddItem(sound.Parent, 10) end
		end
	end))
	-- Sample replicated clocks; no local subtraction or synthetic phase changes.
	-- Re-resolving the two paths also backfills late streaming and replacements.
	local function sample()
		local board = find(Workspace, { "Commons", "StatusBoard" })
		if board == nil then missing("Workspace.Commons.StatusBoard") else
			push({ kind = "Session", phase = tostring(board:GetAttribute("Phase") or ""),
				day = tonumber(board:GetAttribute("Day")) or 0, seconds = tonumber(board:GetAttribute("SecondsLeft")) or 0,
				nights = tonumber(board:GetAttribute("NightsSurvived")) or 0, outcome = tostring(board:GetAttribute("Outcome") or ""),
				roof = board:GetAttribute("RoofUnlocked") == true, provisioned = board:GetAttribute("Provisioned") == true })
		end
		local console = find(Workspace, { "Roof", "EvacConsole" })
		if console == nil then missing("Workspace.Roof.EvacConsole") else
			push({ kind = "Evac", evac = tostring(console:GetAttribute("EvacStatus") or "") })
		end
		if state.mode == "Evacuating" then
			local pad = find(Workspace, { "Roof", "Helipad" })
			if pad == nil or not pad:IsA("BasePart") then
				missing("Workspace.Roof.Helipad")
				push({ kind = "Assembly", assembly = "Climb to the helipad; squad locations unavailable." })
			else
				local absent: { string } = {}
				for _, member in Players:GetPlayers() do
					local character = member.Character
					local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
					local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
					if humanoid ~= nil and humanoid.Health > 0 then
						local onPad = false
						if root ~= nil and root:IsA("BasePart") then
							local offset = pad:GetPivot():PointToObjectSpace(root.Position)
							onPad = math.abs(offset.X) <= pad.Size.X / 2 and math.abs(offset.Z) <= pad.Size.Z / 2 and math.abs(offset.Y) <= pad.Size.Y / 2 + 8
						end
						if not onPad then table.insert(absent, member.DisplayName) end
					end
				end
				-- Observed positions are guidance only; SessionService decides extraction.
				push({ kind = "Assembly", assembly = if #absent == 0 then "Squad appears assembled — call the console." else "Awaiting on helipad: " .. table.concat(absent, ", ") })
			end
		end
		local profile = HudController.ProfileFor(state.phase)
		if LightingController:GetCurrentProfile() ~= profile then
			local ok, err = pcall(function() LightingController:UpdateLighting(profile, false, 3) end)
			if not ok then missing("lighting profile " .. profile .. ": " .. tostring(err)) end
		end
	end
	sample()
	local elapsed = 0
	local heartbeat = game:GetService("RunService").Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 0.25 then return end
		elapsed = 0
		sample()
	end)
	table.insert(disconnectors, function() heartbeat:Disconnect() end)
end
function HudController.Stop(): ()
	if not started then return end
	started = false
	for _, disconnect in disconnectors do disconnect() end
	table.clear(disconnectors)
	for name in actions do ContextActionService:UnbindAction("HudController/" .. name) end
	local Screens = require(ReplicatedStorage.Packages.Screens)
	Screens.hide("HudController")
	-- Screens keeps its registration: reuse this same tree on a later Start.
end
export type HudController = typeof(HudController)
return HudController
