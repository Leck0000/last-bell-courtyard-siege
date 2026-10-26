--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local Interaction = require(ReplicatedStorage.Shared.Modules.Interaction)
local InteractionService = require(ReplicatedStorage.Shared.Systems.InteractionService)
local SupplyService = require(ServerScriptService.Server.Modules.SupplyService)
local SiegeService = require(ServerScriptService.Server.Modules.SiegeService)
local BarricadeService = require(ServerScriptService.Server.Modules.BarricadeService)
local SoundUtil = require(ReplicatedStorage.Shared.Utils.SoundUtil)

type Member = { Active: boolean, Seat: number }
local SessionService = {
 DaySeconds = 300, NightSeconds = 240, ResultSeconds = 20,
 Phase = "Day", Day = 1, SecondsLeft = 300, NightsSurvived = 0,
 Outcome = "Active", RoofUnlocked = false, Provisioned = false,
 EvacStatus = "Unrequested", ExtractionRequested = false, ResultCount = 0,
 Members = {} :: { [Player]: Member },
}
local started = false
local connections: { RBXScriptConnection } = {}
local interactions: { Interaction.Interaction } = {}
local barrier: Part? = nil
local warnings: { [string]: boolean } = {}
local function find(path: string): Instance?
 local node: Instance? = Workspace
 for name in string.gmatch(path, "[^.]+") do
  if node == nil then break end
  node = node:FindFirstChild(name)
 end
 if node == nil and not warnings[path] then warnings[path] = true; warn("SessionService missing " .. path) end
 return node
end
local function attribute(path: string, name: string, value: string | number | boolean)
 local node = find(path)
 if node then node:SetAttribute(name, value) end
end
local function root(player: Player): BasePart?
 local c = player.Character
 local r = if c then c:FindFirstChild("HumanoidRootPart") else nil
 return if r and r:IsA("BasePart") then r else nil
end
function SessionService.CanUse(player: Player): boolean
 local member = SessionService.Members[player]
 return SessionService.Outcome == "Active" and member ~= nil and member.Active and SiegeService.CanUse(player)
end
local function near(player: Player, path: string): boolean
 local r = root(player); local part = find(path)
 return SessionService.CanUse(player) and r ~= nil and part ~= nil and part:IsA("BasePart") and (r.Position - part.Position).Magnitude <= 12
end
function SessionService.Publish()
 local shared = SupplyService.GetSharedState()
 SessionService.RoofUnlocked = shared.Keycard
 SessionService.Provisioned = shared.Fuel >= 1 and shared.Radio >= 1
 if barrier and barrier.Parent then barrier.Anchored = true; barrier.CanCollide = not SessionService.RoofUnlocked; barrier.Transparency = if SessionService.RoofUnlocked then 1 else .1 end
 local values: { [string]: string | number | boolean } = { Phase = SessionService.Phase, Day = SessionService.Day, SecondsLeft = math.ceil(SessionService.SecondsLeft), NightsSurvived = SessionService.NightsSurvived, Outcome = SessionService.Outcome, RoofUnlocked = SessionService.RoofUnlocked, Provisioned = SessionService.Provisioned }
 for name, value in values do attribute("Commons.StatusBoard", name, value) end
 attribute("Roof.EvacConsole", "EvacStatus", SessionService.EvacStatus)
end
local function sound(path: string, position: Vector3?)
 local slot: Instance? = nil
 if string.sub(path,1,5) == "Roof." then slot = find(path)
 else
  local sounds = ReplicatedStorage.Shared.Assets:FindFirstChild("Sounds")
  slot = if sounds then sounds:FindFirstChild(path) else nil
 end
 if slot and slot:IsA("Sound") then
  if position then SoundUtil.playAt(slot.SoundId, position, { volume = slot.Volume })
  else SoundUtil.playOn(SoundService, slot.SoundId, { volume = slot.Volume }) end
 end
end
function SessionService.Finish(outcome: string)
 if SessionService.Outcome ~= "Active" then return end
 SessionService.Outcome = outcome; SessionService.Phase = "Result"
 SessionService.SecondsLeft = SessionService.ResultSeconds; SessionService.ResultCount += 1
 SupplyService.SetPhase("Result")
 -- Clear combat immediately; reset ownership and world defenses after the result interval.
 SiegeService.SetPhase("Result")
 for p in SessionService.Members do SupplyService.CancelSearch(p); BarricadeService.Release(p) end
 SessionService.Publish()
end
function SessionService.CheckWipe(): boolean
 local count = 0
 for player, member in SessionService.Members do
  if member.Active then
   count += 1
   local m = SiegeService.GetSurvival(player)
   if m and not m.Dead and not m.Downed and SiegeService.CanUse(player) then return false end
   -- Loading a dawn character is not an incapacitation.
   if m and not m.Dead and not m.Downed and player.Character == nil then return false end
  end
 end
 if count > 0 then SessionService.Finish("Lost"); return true end
 return false
end
function SessionService.CheckExtraction(): boolean
 if SessionService.Outcome ~= "Active" then return false end
 if SessionService.CheckWipe() then return false end
 SessionService.Publish()
 if SessionService.NightsSurvived < 10 then SessionService.EvacStatus = "WaitingForNights"
 elseif not SessionService.Provisioned then SessionService.EvacStatus = "WaitingForSupplies"
 elseif not SessionService.RoofUnlocked then SessionService.EvacStatus = "WaitingForKeycard"
 else
  local pad = find("Roof.Helipad")
  local living = 0; local assembled = true
  if pad == nil or not pad:IsA("BasePart") then return false end
  for p, member in SessionService.Members do
   local m = SiegeService.GetSurvival(p)
   if member.Active and m and not m.Dead then
    living += 1
    local r = root(p)
    if r == nil then assembled = false
    else
     local v = pad.CFrame:PointToObjectSpace(r.Position)
     if math.abs(v.X) > pad.Size.X/2 or math.abs(v.Z) > pad.Size.Z/2 or math.abs(v.Y) > pad.Size.Y/2 + 5 then assembled = false end
    end
   end
  end
  if living > 0 and assembled then
   SessionService.EvacStatus = "Evacuated"
   sound("Roof.Props.ExtractionRotor", pad.Position)
   SessionService.Finish("Evacuated"); return true
  end
  SessionService.EvacStatus = "WaitingForSquad"
 end
 SessionService.Publish(); return false
end
function SessionService.Deposit(player: Player): boolean
 if not near(player, "Commons.RadioConsole") then return false end
 local deposited = SupplyService.Deposit(player)
 SessionService.Publish(); return deposited
end
function SessionService.RequestExtraction(player: Player): boolean
 if not near(player, "Roof.EvacConsole") then return false end
 SessionService.ExtractionRequested = true
 return SessionService.CheckExtraction()
end
local spawnNames = { "SpawnOne", "SpawnTwo", "SpawnThree", "SpawnFour" }
local function admit(player: Player, member: Member, reload: boolean)
 member.Active = true
 local spawn = find("Commons." .. spawnNames[member.Seat])
 if spawn and spawn:IsA("SpawnLocation") then player.RespawnLocation = spawn end
 SiegeService.AddPlayer(player); SupplyService.AddPlayer(player)
 BarricadeService.SetIncapacitated(player, false)
 if reload and typeof(player) == "Instance" then player:LoadCharacter() end
end
function SessionService.AddPlayer(player: Player)
 if SessionService.Members[player] then return end
 local used: { [number]: boolean } = {}; local count = 0
 for _, member in SessionService.Members do used[member.Seat] = true; count += 1 end
 local seat = 1; for i = 1,4 do if not used[i] then seat = i; break end end
 local member = { Active = count == 0 and SessionService.Outcome == "Active", Seat = seat }
 SessionService.Members[player] = member
 if member.Active then admit(player, member, false) else SiegeService.Meters[player] = nil end
end
function SessionService.RemovePlayer(player: Player)
 SessionService.Members[player] = nil
 SupplyService.CancelSearch(player); BarricadeService.RemovePlayer(player)
 -- SupplyService's removal handler atomically drops and clears carried loot.
 SiegeService.Meters[player] = nil
 if SessionService.ExtractionRequested then SessionService.CheckExtraction() end
 SessionService.CheckWipe()
end
function SessionService.Dawn()
 SiegeService.Dawn(); SupplyService.SetPhase("Day")
 SessionService.Phase = "Day"; SessionService.Day = math.min(10, SessionService.NightsSurvived + 1)
 SessionService.SecondsLeft = SessionService.DaySeconds
 for p, member in SessionService.Members do if not member.Active then admit(p,member,true) end end
 SessionService.Publish()
end
function SessionService.ResetSession()
 SupplyService.ResetSession(); BarricadeService.ResetSession(); SiegeService.ResetSession()
 SessionService.Phase = "Day"; SessionService.Day = 1; SessionService.NightsSurvived = 0
 SessionService.Outcome = "Active"; SessionService.SecondsLeft = SessionService.DaySeconds
 SessionService.ExtractionRequested = false; SessionService.EvacStatus = "Unrequested"
 SiegeService.Night = 0; SiegeService.NightElapsed = 0; SiegeService.NextSpawn = 0
 SupplyService.SetPhase("Day")
 for p, member in SessionService.Members do admit(p, member, true) end
 SessionService.Publish()
end
function SessionService.Step(dt: number)
 if dt <= 0 or dt ~= dt or dt == math.huge then return end
 if SessionService.Outcome ~= "Active" then
  SessionService.SecondsLeft = math.max(0, SessionService.SecondsLeft - dt)
  if SessionService.SecondsLeft == 0 then SessionService.ResetSession() else SessionService.Publish() end
  return
 end
 if next(SessionService.Members) == nil then return end
 if SessionService.CheckWipe() then return end
 if SessionService.ExtractionRequested and SessionService.CheckExtraction() then return end
 -- After ten nights hold at dawn for extraction, never start an eleventh defense.
 if SessionService.NightsSurvived >= 10 then SessionService.Publish(); return end
 SessionService.SecondsLeft = math.max(0, SessionService.SecondsLeft - dt)
 if SessionService.SecondsLeft == 0 then
  if SessionService.Phase == "Day" then
   SessionService.Phase = "Night"; SessionService.SecondsLeft = SessionService.NightSeconds
   SiegeService.DefenseSeconds = SessionService.NightSeconds; SiegeService.BeginNight(SessionService.Day)
   SupplyService.SetPhase("Night"); sound("NightBell", nil)
  elseif SessionService.Phase == "Night" then
   local living = false
   for p, member in SessionService.Members do local m = SiegeService.GetSurvival(p); if member.Active and m and not m.Dead then living = true end end
   if living then SessionService.NightsSurvived += 1 end
   SessionService.Dawn()
   if SessionService.ExtractionRequested then SessionService.CheckExtraction() end
  end
 end
 SessionService.Publish()
end
local function install(path: string, name: string, action: (Player) -> ())
 local part = find(path)
 if part == nil or not part:IsA("BasePart") then return end
 local prompt = part:FindFirstChild(name)
 if prompt == nil or not prompt:IsA("ProximityPrompt") then warn("Missing session prompt " .. name); return end
 local duration = prompt.HoldDuration
 local interaction = Interaction.new({ Parent = part, ActionText = prompt.ActionText, ObjectText = prompt.ObjectText, MaxActivationDistance = 10, InstantActivation = true, OnActivated = action })
 local replacement = part:FindFirstChild(name)
 if replacement and replacement:IsA("ProximityPrompt") then replacement.HoldDuration = duration end
 table.insert(interactions,interaction)
end
function SessionService.Start()
 if started then return end; started = true
 -- Modal methods are client-only; the package has already booted this service.
 assert(type(InteractionService.AddModalRequest) == "function")
 SupplyService.Start(); BarricadeService.Start(); SiegeService.Start()
 local hooks = table.clone(SupplyService.Hooks); hooks.Keycard = SessionService.Publish; hooks.CanUse = SessionService.CanUse; SupplyService.Configure(hooks)
 BarricadeService.Configure({ CanUse = SessionService.CanUse })
 SiegeService.Configure({ OnDowned = function() SessionService.CheckWipe() end, OnDeath = function(p) SupplyService.OnDeath(p); SessionService.CheckWipe() end })
 local gate = find("Commons.Gates.Roof"); local portal = find("Roof.Seams.RoofStair.Portal")
 if gate and tostring(gate:GetAttribute("GateKind") or "") == "key" and tostring(gate:GetAttribute("GateRef") or "") == "SessionService" and portal then
  local cf: CFrame? = nil; local size: Vector3? = nil
  if portal:IsA("BasePart") then cf = portal.CFrame; size = portal.Size elseif portal:IsA("Model") then cf, size = portal:GetBoundingBox() end
  if cf and size then
   local wall = Instance.new("Part"); wall.Name = "RoofKeyBarrier"; wall.Anchored = true
   wall.Size = Vector3.new(size.X, math.max(size.Y,10), size.Z); wall.CFrame = cf + Vector3.new(0,(wall.Size.Y-size.Y)/2,0)
   wall.Color = Color3.fromRGB(98,104,107); wall.Material = Enum.Material.Metal; wall.Parent = gate; barrier = wall
  end
 end
 install("Commons.RadioConsole", "InstallPrompt", function(p) SessionService.Deposit(p) end)
 install("Roof.EvacConsole", "CallPrompt", function(p) SessionService.RequestExtraction(p) end)
 local function bind(p: Player)
  SessionService.AddPlayer(p)
  local function characterAdded(c: Model)
   local member = SessionService.Members[p]; local h = c:FindFirstChildOfClass("Humanoid")
   if member and not member.Active and h then h.WalkSpeed = 0; h.JumpPower = 0 end
  end
  table.insert(connections,p.CharacterAdded:Connect(characterAdded)); if p.Character then characterAdded(p.Character) end
 end
 table.insert(connections,Players.PlayerAdded:Connect(bind))
 for _, p in Players:GetPlayers() do
  bind(p)
  local member = SessionService.Members[p]
  if member then admit(p, member, false) end
  local c = p.Character; local h = if c then c:FindFirstChildOfClass("Humanoid") else nil
  if h then h.WalkSpeed = 16; h.JumpPower = 50 end
 end
 table.insert(connections,Players.PlayerRemoving:Connect(SessionService.RemovePlayer))
 local ambience: { [string]: string } = { Commons = "CommonsHum", Courtyard = "CourtyardWind", ScienceLab = "LabHiss", Gym = "GymEcho", AdminOffice = "OfficeStatic", Roof = "RoofWind" }
 for area, name in ambience do
  local slot = find(area .. ".Props." .. name)
  local host = find(area)
  if slot and slot:IsA("Sound") and host then
   local emitter = Instance.new("Part"); emitter.Name = name .. "Emitter"; emitter.Anchored = true; emitter.CanCollide = false; emitter.CanTouch = false; emitter.CanQuery = false; emitter.Transparency = 1
   local anchor = find(area .. ".Ground")
   if anchor then local p = anchor:FindFirstChildWhichIsA("BasePart"); if p then emitter.CFrame = p.CFrame end end
   emitter.Parent = host; local clone = slot:Clone(); clone.SoundGroup = SoundUtil.getMasterGroup(); clone.Parent = emitter; clone:Play()
  end
 end
 local elapsed = 0
 table.insert(connections,RunService.Heartbeat:Connect(function(dt) elapsed += dt; if elapsed >= .25 then local step = elapsed; elapsed = 0; SessionService.Step(step) end end))
 SessionService.Publish()
end
export type SessionService = typeof(SessionService)
return SessionService
