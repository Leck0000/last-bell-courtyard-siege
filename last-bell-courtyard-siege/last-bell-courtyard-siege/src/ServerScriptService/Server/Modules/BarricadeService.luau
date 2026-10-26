--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Interaction = require(ReplicatedStorage.Shared.Modules.Interaction)
-- Booted by the package; its modal methods are client-only.
local InteractionService = require(ReplicatedStorage.Shared.Systems.InteractionService)
local SupplyService = require(ServerScriptService.Server.Modules.SupplyService)
local SoundUtil = require(ReplicatedStorage.Shared.Utils.SoundUtil)

type Defense = { Part: BasePart, Maximum: number, Home: CFrame, Transparency: number, Socket: BasePart?, Holder: Player?, Character: Model?, Constraint: AlignPosition?, Attachment: Attachment?, RepairAt: number }
export type Hooks = { CanUse: ((Player) -> boolean)? }
local BarricadeService = { Hooks = {} :: Hooks, RepairCost = 2, RebuildCost = 6, RepairAmount = 100, BruteDamage = 160 }
local defenses: { [string]: Defense } = {}
local sockets: { [string]: BasePart } = {}
local leases: { [Player]: string } = {}
local incapacitated: { [Player]: boolean? } = {}
local interactions: { Interaction.Interaction } = {}
local connections: { RBXScriptConnection } = {}
local started = false
local commons = Workspace.Commons
local function root(player: Player): BasePart?
 if incapacitated[player] then return nil end
 if BarricadeService.Hooks.CanUse and not BarricadeService.Hooks.CanUse(player) then return nil end
 local character = player.Character
 if character == nil then return nil end
 local h = character:FindFirstChildOfClass("Humanoid")
 local r = character:FindFirstChild("HumanoidRootPart")
 if h == nil or h.Health <= 0 or r == nil or not r:IsA("BasePart") then return nil end
 return r
end
local function filter(d: Defense, character: Model?): RaycastParams
 local p = RaycastParams.new()
 p.FilterType = Enum.RaycastFilterType.Exclude
 local excluded: { Instance } = { d.Part }
 if character then table.insert(excluded, character) end
 for _, s in sockets do table.insert(excluded, s) end
 p.FilterDescendantsInstances = excluded
 p.RespectCanCollide = true
 return p
end
-- A real collidable ground beneath all four footprint corners must belong to
-- Commons, not the courtyard or a roof. Never infer a slab name or map origin.
local function inside(d: Defense, position: Vector3, character: Model?): boolean
 local p = filter(d, character or d.Character)
 for _, x in { -1, 1 } do
  for _, z in { -1, 1 } do
   local offset = Vector3.new(x * d.Part.Size.X / 2, 0, z * d.Part.Size.Z / 2)
   local hit = Workspace:Raycast(position + offset + Vector3.new(0, 4, 0), Vector3.new(0, -12, 0), p)
   if hit == nil or not hit.Instance:IsDescendantOf(commons.Ground) then return false end
  end
 end
 return true
end
local function clearPath(d: Defense, position: Vector3): boolean
 local delta = position - d.Part.Position
 if delta.Magnitude < 0.05 then return true end
 return Workspace:Blockcast(d.Part.CFrame, d.Part.Size * 0.85, delta, filter(d, d.Character)) == nil
end
local function cue(name: string, position: Vector3)
 local slot = ReplicatedStorage.Shared.Assets.Sounds:FindFirstChild(name)
 if slot and slot:IsA("Sound") then SoundUtil.playAt(slot.SoundId, position, { volume = slot.Volume }) end
end
function BarricadeService.Configure(hooks: Hooks) BarricadeService.Hooks = hooks end
function BarricadeService.Release(player: Player)
 local name = leases[player]
 if name == nil then return end
 local d = defenses[name]
 leases[player] = nil
 if d == nil then return end
 if d.Constraint then d.Constraint:Destroy() end
 if d.Attachment then d.Attachment:Destroy() end
 d.Constraint = nil; d.Attachment = nil; d.Holder = nil; d.Character = nil
 -- Remove drag energy without moving the body through anything.
 d.Part.AssemblyLinearVelocity = Vector3.zero
 d.Part.AssemblyAngularVelocity = Vector3.zero
end
function BarricadeService.SetIncapacitated(player: Player, value: boolean)
 incapacitated[player] = if value then true else nil
 if value then BarricadeService.Release(player) end
end
function BarricadeService.RemovePlayer(player: Player)
 BarricadeService.Release(player); incapacitated[player] = nil
end
function BarricadeService.BeginDrag(player: Player, name: string): boolean
 local d = defenses[name]; local r = root(player)
 if d == nil or r == nil or d.Holder ~= nil or leases[player] ~= nil or (r.Position - d.Part.Position).Magnitude > 12 or (tonumber(d.Part:GetAttribute("Durability")) or 0) <= 0 then return false end
 if not inside(d, d.Part.Position, player.Character) then return false end
 d.Socket = nil; d.Part:SetAttribute("Secured", false)
 d.Part.Anchored = false; d.Part:SetNetworkOwner(nil)
 d.Holder = player; d.Character = player.Character; leases[player] = name
 local a = Instance.new("Attachment"); a.Name = "ServerDragAttachment"; a.Parent = d.Part
 local c = Instance.new("AlignPosition"); c.Name = "ServerDragConstraint"; c.Mode = Enum.PositionAlignmentMode.OneAttachment
 c.Attachment0 = a; c.ApplyAtCenterOfMass = true; c.RigidityEnabled = false
 c.MaxForce = d.Part.AssemblyMass * 120; c.MaxVelocity = 9; c.Responsiveness = 12
 c.Position = d.Part.Position; c.Parent = d.Part
 d.Attachment = a; d.Constraint = c
 cue("FurnitureScrape", d.Part.Position)
 return true
end
function BarricadeService.ToggleDrag(player: Player, name: string): boolean
 if leases[player] == name then BarricadeService.Release(player); return true end
 return BarricadeService.BeginDrag(player, name)
end
function BarricadeService.Secure(player: Player, socketName: string): boolean
 local name = leases[player]; local s: BasePart? = sockets[socketName]; local r = root(player)
 if name == nil or s == nil or r == nil then return false end
 local d = defenses[name]
 if d == nil or (r.Position - s.Position).Magnitude > 12 or (d.Part.Position - s.Position).Magnitude > 9 then return false end
 for _, other in defenses do if other ~= d and other.Socket == s then return false end end
 local target = s.Position + Vector3.new(0, s.Size.Y / 2 + d.Part.Size.Y / 2, 0)
 if not inside(d, target) or not clearPath(d, target) then return false end
 BarricadeService.Release(player)
 d.Part.Anchored = true
 d.Part.CFrame = CFrame.new(target) * s.CFrame.Rotation
 d.Socket = s; d.Part:SetAttribute("Secured", true)
 return true
end
-- SiegeService calls Damage for actual enemy impacts, or BruteCharge for its
-- heavy structural attack. SessionService calls ResetSession; survival calls
-- SetIncapacitated, so no guessed attributes become a second state owner.
function BarricadeService.Damage(name: string, amount: number): boolean
 local d = defenses[name]
 if d == nil or d.Socket == nil or amount ~= amount or amount <= 0 or amount == math.huge then return false end
 local old = tonumber(d.Part:GetAttribute("Durability")) or 0
 if old <= 0 then return false end
 d.Part:SetAttribute("Durability", math.clamp(old - amount, 0, d.Maximum))
 d.Part:SetAttribute("DamageEvents", (tonumber(d.Part:GetAttribute("DamageEvents")) or 0) + 1)
 cue("BarricadeHit", d.Part.Position)
 if old <= amount then
  d.Part.CanCollide = false; d.Part.Transparency = 0.75; d.Part:SetAttribute("Secured", false)
 end
 return true
end
function BarricadeService.BruteCharge(name: string): boolean return BarricadeService.Damage(name, BarricadeService.BruteDamage) end
function BarricadeService.Repair(player: Player, name: string): boolean
 local d = defenses[name]; local r = root(player)
 if d == nil or r == nil or d.Holder ~= nil or (r.Position - d.Part.Position).Magnitude > 12 or os.clock() < d.RepairAt then return false end
 local old = tonumber(d.Part:GetAttribute("Durability")) or 0
 if old >= d.Maximum then return false end
 local cost = if old <= 0 then BarricadeService.RebuildCost else BarricadeService.RepairCost
 -- Atomic: this check, inventory debit and durability commit never yield.
 if not SupplyService.TryConsume(player, { Scrap = cost }) then return false end
 d.RepairAt = os.clock() + 0.75
 d.Part:SetAttribute("Durability", math.clamp(old + BarricadeService.RepairAmount, 0, d.Maximum))
 d.Part:SetAttribute("Repairs", (tonumber(d.Part:GetAttribute("Repairs")) or 0) + 1)
 d.Part.CanCollide = true; d.Part.Transparency = d.Transparency
 d.Part:SetAttribute("Secured", d.Socket ~= nil)
 return true
end
function BarricadeService.GetState(name: string): { Part: BasePart, Holder: Player?, Socket: BasePart?, Maximum: number, Durability: number, Secured: boolean }?
 local d = defenses[name]
 if d == nil then return nil end
 return { Part = d.Part, Holder = d.Holder, Socket = d.Socket, Maximum = d.Maximum, Durability = tonumber(d.Part:GetAttribute("Durability")) or 0, Secured = d.Part:GetAttribute("Secured") == true }
end
function BarricadeService.GetBarricades(): { BasePart }
 local result: { BasePart } = {}
 for _, d in defenses do if d.Part:GetAttribute("Secured") == true and d.Part.CanCollide then table.insert(result, d.Part) end end
 return result
end
function BarricadeService.ResetSession()
 for player in leases do BarricadeService.Release(player) end
 incapacitated = {}
 for _, d in defenses do
  d.Socket = nil; d.RepairAt = 0; d.Part.Anchored = true; d.Part.CFrame = d.Home
  d.Part.CanCollide = true; d.Part.Transparency = d.Transparency
  d.Part:SetAttribute("Durability", d.Maximum); d.Part:SetAttribute("Secured", false)
  d.Part:SetAttribute("DamageEvents", 0); d.Part:SetAttribute("Repairs", 0)
  d.Part.Anchored = false; d.Part:SetNetworkOwner(nil)
 end
end
local function install(part: BasePart, name: string, callback: (Player) -> ())
 local placeholder = part:FindFirstChild(name)
 if placeholder == nil or not placeholder:IsA("ProximityPrompt") then warn("Missing barricade prompt " .. name); return end
 local duration = placeholder.HoldDuration
 local marks: { [ProximityPrompt]: boolean } = {}
 for _, child in part:GetChildren() do
  if child:IsA("ProximityPrompt") then marks[child] = child:GetAttribute("ParalovAssignedKey") == true; child:SetAttribute("ParalovAssignedKey", child == placeholder) end
 end
 local interaction = Interaction.new({ Parent = part, ActionText = placeholder.ActionText, ObjectText = placeholder.ObjectText, InstantActivation = true, MaxActivationDistance = 10, OnActivated = callback })
 for prompt, mark in marks do if prompt.Parent then prompt:SetAttribute("ParalovAssignedKey", mark) end end
 local replacement = part:FindFirstChild(name)
 if replacement and replacement:IsA("ProximityPrompt") then replacement.HoldDuration = duration end
 table.insert(interactions, interaction)
end
local function bind(player: Player)
 table.insert(connections, player.CharacterRemoving:Connect(function() BarricadeService.Release(player) end))
 -- CharacterRemoving handles death/respawn, Heartbeat also validates health.
 if player.Character == nil then BarricadeService.Release(player) end
end
function BarricadeService.Start()
 if started then return end; started = true
 sockets.DoorSocket = commons.DoorSocket; sockets.WindowSocket = commons.WindowSocket
 local maxima: { [string]: number } = { Desk = 200, MovableLocker = 300 }
 for name, maximum in maxima do
  local part = commons:FindFirstChild(name)
  if part and part:IsA("BasePart") then
   defenses[name] = { Part = part, Maximum = maximum, Home = part.CFrame, Transparency = part.Transparency, RepairAt = 0 }
   part.Anchored = false; part:SetNetworkOwner(nil)
   install(part, "DragPrompt", function(p) BarricadeService.ToggleDrag(p, name) end)
   install(part, "RepairPrompt", function(p) BarricadeService.Repair(p, name) end)
  end
 end
 for name, s in sockets do install(s, "SecurePrompt", function(p) BarricadeService.Secure(p, name) end) end
 table.insert(connections, Players.PlayerAdded:Connect(bind))
 for _, player in Players:GetPlayers() do bind(player) end
 table.insert(connections, Players.PlayerRemoving:Connect(BarricadeService.RemovePlayer))
 table.insert(connections, RunService.Heartbeat:Connect(function(dt: number)
  -- Unleased bodies remain physical, but cannot be pushed out of Commons.
  -- Stop boundary-directed momentum before its swept footprint leaves ground;
  -- never rescue an escaped object by teleporting it through a wall.
  for _, d in defenses do
   if not d.Part.Anchored and d.Holder == nil then
    local velocity = d.Part.AssemblyLinearVelocity
    local nextPosition = d.Part.Position + Vector3.new(velocity.X, 0, velocity.Z) * math.min(dt + 0.1, 0.2)
    if velocity.Magnitude > 0.5 and not inside(d, nextPosition) then
     d.Part.AssemblyLinearVelocity = Vector3.new(0, math.min(velocity.Y, 0), 0)
    end
   end
  end
  for player, name in leases do
   local d = defenses[name]; local r = root(player)
   if d == nil then leases[player] = nil
   elseif r == nil or player.Character ~= d.Character or (r.Position - d.Part.Position).Magnitude > 18 then BarricadeService.Release(player)
   elseif d.Constraint then
    local behind = r.Position - r.CFrame.LookVector * 5
    local target = Vector3.new(behind.X, d.Part.Position.Y, behind.Z)
    if inside(d, target) and clearPath(d, target) then d.Constraint.Position = target
    else d.Constraint.Position = d.Part.Position; d.Part.AssemblyLinearVelocity = Vector3.zero end
   end
  end
 end))
end
return BarricadeService
