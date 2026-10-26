--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local InventoryService = require(ServerScriptService.Server.Systems.InventoryService)
local Interaction = require(ReplicatedStorage.Shared.Modules.Interaction)
-- Its modal methods are client-only; Interaction consumes this service internally.
local InteractionService = require(ReplicatedStorage.Shared.Systems.InteractionService)
local DataService = require(ServerScriptService.Server.Systems.DataService)
local Remotes = require(ReplicatedStorage.Shared.Network.Remotes)
local SoundUtil = require(ReplicatedStorage.Shared.Utils.SoundUtil)

type Inventory = { [string]: number }
type Search = { cache: string, started: number, character: Model, generation: number }
export type ItemEffect = { Health: number, Infection: number, Hunger: number, Thirst: number }
local itemEffects: { [string]: ItemEffect } = {
 Medkit = { Health = 45, Infection = -25, Hunger = 0, Thirst = 0 },
 Ration = { Health = 0, Infection = 0, Hunger = 35, Thirst = 0 },
 Water = { Health = 0, Infection = 0, Hunger = 0, Thirst = 40 },
 Molotov = { Health = 0, Infection = 0, Hunger = 0, Thirst = 0 },
}
-- SessionService installs Keycard, reads GetSharedState after Deposit, and calls
-- ResetSession on wipe. BarricadeService uses TryConsume after its proximity check.
-- SiegeService installs Noise/CanUse/ApplyItem: ApplyItem clamps the signed meter
-- deltas below and creates the authoritative Molotov hazard for the given aim.
export type Hooks = {
 Noise: ((Player, Vector3, string, string) -> ())?,
 Keycard: (() -> ())?,
 CanUse: ((Player) -> boolean)?,
 ApplyItem: ((Player, string, Vector3, ItemEffect) -> ())?,
}
local SupplyService = {
 SearchSeconds = 3, CacheCooldown = 45, Phase = "Day",
 Inventories = {} :: { [string]: Inventory },
 Cooldowns = {} :: { [string]: { [string]: number } },
 Pending = {} :: { [string]: Search },
 UseCooldowns = {} :: { [string]: number },
 Reserves = { Fuel = 0, Radio = 0 }, HasKeycard = false,
 Hooks = {} :: Hooks,
 NoiseEvents = {} :: { { UserId: number, Position: Vector3, Cache: string, Stage: string } },
 Drops = {} :: { [string]: { Items: Inventory, Part: BasePart } },
}
local loot: { [string]: Inventory } = {
 SalvageLocker = { Scrap = 12, Cloth = 3, Chemicals = 3 },
 SupplyCrate = { Fuel = 3, Scrap = 4 },
 ChemicalLocker = { Chemicals = 4, Cloth = 1 },
 WeaponRack = { Bat = 1 }, RecordsCabinet = { Keycard = 1, Radio = 1 },
}
local recipes: { [string]: Inventory } = { Medkit = { Cloth = 2, Chemicals = 1 }, Molotov = { Cloth = 1, Chemicals = 2 } }
local items = { "Pipe", "Bat", "Scrap", "Cloth", "Chemicals", "Fuel", "Radio", "Medkit", "Molotov", "Ration", "Water" }
local caches: { [string]: BasePart? } = {}
local bench: BasePart? = nil
local counter: BasePart? = nil
local food: { [string]: { at: number, count: number } } = {}
local generation = 0
local dropSerial = 0
local started = false
local interactions: { Interaction.Interaction } = {}
local connections: { RBXScriptConnection } = {}
local playersById: { [string]: Player? } = {}
local function key(player: Player): string return tostring(player.UserId) end
local function feedback(player: Player, message: string, success: boolean)
 Remotes.SupplyService.SupplyFeedback:fire(player, { Message = message, Success = success })
end
local function publish(player: Player)
 local inv = SupplyService.Inventories[key(player)]
 if inv == nil then return end
 for _, item in items do Remotes.SupplyService.InventoryItem:fire(player, { Item = item, Count = inv[item] or 0 }) end
end
local function root(player: Player): BasePart?
 local character = player.Character
 if character == nil then return nil end
 local humanoid = character:FindFirstChildOfClass("Humanoid")
 local part = character:FindFirstChild("HumanoidRootPart")
 if humanoid == nil or humanoid.Health <= 0 or part == nil or not part:IsA("BasePart") then return nil end
 if SupplyService.Hooks.CanUse and not SupplyService.Hooks.CanUse(player) then return nil end
 return part
end
local function near(player: Player, part: BasePart): boolean
 local r = root(player)
 return r ~= nil and (r.Position - part.Position).Magnitude <= 12
end
local function noise(player: Player, cache: string, stage: string)
 local part = caches[cache]
 if part == nil then return end
 table.insert(SupplyService.NoiseEvents, { UserId = player.UserId, Position = part.Position, Cache = cache, Stage = stage })
 if #SupplyService.NoiseEvents > 100 then table.remove(SupplyService.NoiseEvents, 1) end
 local slot = ReplicatedStorage.Shared.Assets.Sounds.LockerSearch
 SoundUtil.playAt(slot.SoundId, part.Position, { volume = slot.Volume })
 local callback = SupplyService.Hooks.Noise
 if callback then callback(player, part.Position, cache, stage) end
end
function SupplyService.Configure(hooks: Hooks) SupplyService.Hooks = hooks end
function SupplyService.SetPhase(phase: string) SupplyService.Phase = phase end
function SupplyService.GetInventory(player: Player): Inventory return table.clone(SupplyService.Inventories[key(player)] or {}) end
function SupplyService.GetLoot(cache: string): Inventory return table.clone(loot[cache] or {}) end
function SupplyService.GetWeapon(player: Player): string
 local inv = SupplyService.Inventories[key(player)]
 return if inv and (inv.Bat or 0) > 0 then "Bat" else "Pipe"
end
function SupplyService.GetMeleeDamage(player: Player): number return if SupplyService.GetWeapon(player) == "Bat" then 30 else 12 end
function SupplyService.AddPlayer(player: Player)
 local id = key(player)
 if SupplyService.Inventories[id] then return end
 playersById[id] = player
 SupplyService.Inventories[id] = { Pipe = 1 }
 SupplyService.Cooldowns[id] = {}
 publish(player)
end
function SupplyService.TryConsume(player: Player, costs: Inventory): boolean
 local inv = SupplyService.Inventories[key(player)]
 if inv == nil then return false end
 for item, amount in costs do
  if amount ~= amount or amount < 0 or amount % 1 ~= 0 or (inv[item] or 0) < amount then return false end
 end
 for item, amount in costs do inv[item] = (inv[item] or 0) - amount end
 publish(player)
 return true
end
function SupplyService.BeginSearch(player: Player, cache: string): boolean
 local id = key(player)
 local part = caches[cache]
 local cd = SupplyService.Cooldowns[id]
 local character = player.Character
 if part == nil or cd == nil or character == nil or not near(player, part) or SupplyService.Phase ~= "Day" or SupplyService.Pending[id] ~= nil or os.clock() < (cd[cache] or 0) then
  feedback(player, "Search unavailable", false) return false
 end
 SupplyService.Pending[id] = { cache = cache, started = os.clock(), character = character, generation = generation }
 noise(player, cache, "Start")
 return true
end
function SupplyService.CancelSearch(player: Player) SupplyService.Pending[key(player)] = nil end
local function complete(player: Player, search: Search)
 local id = key(player)
 local part = caches[search.cache]
 local inv = SupplyService.Inventories[id]
 local cd = SupplyService.Cooldowns[id]
 if part == nil or inv == nil or cd == nil then return end
 -- No yielding between releasing the lease, setting the cooldown and applying loot.
 SupplyService.Pending[id] = nil
 cd[search.cache] = os.clock() + SupplyService.CacheCooldown
 local unlock = false
 for item, count in loot[search.cache] do
  if item == "Keycard" then unlock = not SupplyService.HasKeycard; SupplyService.HasKeycard = true
  elseif item == "Bat" then inv.Bat = 1
  else inv[item] = (inv[item] or 0) + count end
 end
 part:SetAttribute("Searches", (tonumber(part:GetAttribute("Searches")) or 0) + 1)
 publish(player)
 noise(player, search.cache, "Complete")
 if unlock and SupplyService.Hooks.Keycard then SupplyService.Hooks.Keycard() end
 feedback(player, "Supplies recovered", true)
end
function SupplyService.Craft(player: Player, recipe: string): boolean
 local b = bench
 local costs = recipes[recipe]
 if b == nil or costs == nil or not near(player, b) or not SupplyService.TryConsume(player, costs) then feedback(player, "Missing ingredients or too far from bench", false) return false end
 local inv = SupplyService.Inventories[key(player)]
 inv[recipe] = (inv[recipe] or 0) + 1
 local attribute = if recipe == "Medkit" then "MedkitsCrafted" else "MolotovsCrafted"
 b:SetAttribute(attribute, (tonumber(b:GetAttribute(attribute)) or 0) + 1)
 publish(player)
 local gui = player:FindFirstChildOfClass("PlayerGui")
 local slot = ReplicatedStorage.Shared.Assets.Sounds.CraftComplete
 if gui then SoundUtil.playOn(gui, slot.SoundId, { volume = slot.Volume }) end
 feedback(player, recipe .. " crafted", true)
 return true
end
-- Call only from a server-validated install interaction. Carried resources and reserves never alias.
function SupplyService.Deposit(player: Player): boolean
 local inv = SupplyService.Inventories[key(player)]
 if inv == nil then return false end
 local fuel, radio = inv.Fuel or 0, inv.Radio or 0
 if fuel + radio == 0 then return false end
 inv.Fuel = 0; inv.Radio = 0
 SupplyService.Reserves.Fuel += fuel; SupplyService.Reserves.Radio += radio
 publish(player)
 return true
end
function SupplyService.GetSharedState() return { Keycard = SupplyService.HasKeycard, Fuel = SupplyService.Reserves.Fuel, Radio = SupplyService.Reserves.Radio } end
function SupplyService.TakeRations(player: Player): boolean
 local c = counter
 if c == nil or not near(player, c) or SupplyService.Phase ~= "Day" then return false end
 local id = key(player)
 local stock = food[id]
 if stock == nil or os.clock() >= stock.at then stock = { at = os.clock() + 45, count = 2 }; food[id] = stock end
 if stock.count <= 0 then feedback(player, "Counter replenishing", false) return false end
 stock.count -= 1
 local inv = SupplyService.Inventories[id]
 if inv == nil then return false end
 inv.Ration = (inv.Ration or 0) + 1; inv.Water = (inv.Water or 0) + 1
 publish(player) return true
end
function SupplyService.UseItem(player: Player, item: string, aim: Vector3): boolean
 local r = root(player)
 local id = key(player)
 if r == nil or os.clock() < (SupplyService.UseCooldowns[id] or 0) then return false end
 if item ~= "Medkit" and item ~= "Ration" and item ~= "Water" and item ~= "Molotov" then return false end
 if aim.X ~= aim.X or aim.Y ~= aim.Y or aim.Z ~= aim.Z or (aim - r.Position).Magnitude > 80 then return false end
 -- SiegeService owns meters and Molotov damage; require its handler before spending.
 local apply = SupplyService.Hooks.ApplyItem
 if apply == nil then feedback(player, "Survival system unavailable", false) return false end
 if not SupplyService.TryConsume(player, { [item] = 1 }) then feedback(player, "Item not carried", false) return false end
 SupplyService.UseCooldowns[id] = os.clock() + 1
 apply(player, item, aim, table.clone(itemEffects[item]))
 feedback(player, item .. " used", true) return true
end
function SupplyService.RecoverDrop(player: Player, dropId: string): boolean
 local drop = SupplyService.Drops[dropId]
 local inv = SupplyService.Inventories[key(player)]
 if drop == nil or inv == nil or not near(player, drop.Part) then return false end
 SupplyService.Drops[dropId] = nil
 for item, count in drop.Items do inv[item] = (inv[item] or 0) + count end
 drop.Part:Destroy(); publish(player) return true
end
function SupplyService.OnDeath(player: Player)
 local id = key(player)
 SupplyService.Pending[id] = nil
 local inv = SupplyService.Inventories[id]
 if inv == nil then return end
 local carried: Inventory = {}
 for item, count in inv do if item ~= "Pipe" and count > 0 then carried[item] = count end end
 SupplyService.Inventories[id] = { Pipe = 1 }
 local character = player.Character
 if character and next(carried) then
  dropSerial += 1
  local dropId = tostring(dropSerial)
  local part = Instance.new("Part")
  part.Name = "DroppedSupplies"; part.Size = Vector3.new(2, 1, 2); part.Anchored = true; part.CanCollide = false
  part.CFrame = character:GetPivot(); part.Color = Color3.fromRGB(163, 198, 83); part.Parent = Workspace
  SupplyService.Drops[dropId] = { Items = carried, Part = part }
  local interaction = Interaction.new({ Parent = part, ActionText = "Recover supplies", ObjectText = "Dropped loot", InstantActivation = true, OnActivated = function(p) SupplyService.RecoverDrop(p, dropId) end })
  local connection: RBXScriptConnection? = nil
  connection = part.Destroying:Connect(function() interaction:Destroy(); if connection then connection:Disconnect() end end)
 end
 publish(player)
end
function SupplyService.ResetSession()
 generation += 1
 SupplyService.Pending = {}; SupplyService.Cooldowns = {}; SupplyService.UseCooldowns = {}; food = {}
 SupplyService.HasKeycard = false; SupplyService.Reserves = { Fuel = 0, Radio = 0 }
 for _, drop in SupplyService.Drops do drop.Part:Destroy() end
 SupplyService.Drops = {}
 for id, player in playersById do if player then SupplyService.Inventories[id] = { Pipe = 1 }; SupplyService.Cooldowns[id] = {}; publish(player) end end
end
local function bind(player: Player)
 SupplyService.AddPlayer(player)
 -- Read-only package readiness/audit: ephemeral ownership is never written to profiles.
 DataService:PlayerLoaded(player):andThen(function() return InventoryService:GetOwned(player, "Supply") end):catch(warn)
 local function characterAdded(character: Model)
  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if humanoid then table.insert(connections, humanoid.Died:Connect(function() SupplyService.OnDeath(player) end)) end
 end
 table.insert(connections, player.CharacterAdded:Connect(characterAdded))
 if player.Character then characterAdded(player.Character) end
end
local function install(part: BasePart, name: string, action: (Player) -> ())
 local placeholder = part:FindFirstChild(name)
 if placeholder == nil or not placeholder:IsA("ProximityPrompt") then warn("Missing supply prompt: " .. name); return end
 local duration = placeholder.HoldDuration
 local marks: { [ProximityPrompt]: boolean } = {}
 for _, child in part:GetChildren() do
  if child:IsA("ProximityPrompt") then marks[child] = child:GetAttribute("ParalovAssignedKey") == true; child:SetAttribute("ParalovAssignedKey", child == placeholder) end
 end
 local interaction = Interaction.new({ Parent = part, ActionText = placeholder.ActionText, ObjectText = placeholder.ObjectText, InstantActivation = true, MaxActivationDistance = 10, OnActivated = action })
 for prompt, mark in marks do if prompt.Parent then prompt:SetAttribute("ParalovAssignedKey", mark) end end
 local replacement = part:FindFirstChild(name)
 if replacement and replacement:IsA("ProximityPrompt") then replacement.HoldDuration = duration end
 table.insert(interactions, interaction)
end
function SupplyService.Start()
 if started then return end; started = true
 caches.SalvageLocker = Workspace.Commons.SalvageLocker
 caches.SupplyCrate = Workspace.Courtyard.SupplyCrate
 caches.ChemicalLocker = Workspace.ScienceLab.ChemicalLocker
 caches.WeaponRack = Workspace.Gym.WeaponRack
 caches.RecordsCabinet = Workspace.AdminOffice.RecordsCabinet
 bench = Workspace.Commons.CraftBench; counter = Workspace.Commons.CafeteriaCounter
 for name, part in caches do if part then install(part, "SearchPrompt", function(p) SupplyService.BeginSearch(p, name) end) end end
 local b = bench; local c = counter
 if b then
  install(b, "MedkitPrompt", function(p) SupplyService.Craft(p, "Medkit") end)
  -- The harness assigned distinct keys to these two placeholders.
  install(b, "MolotovPrompt", function(p) SupplyService.Craft(p, "Molotov") end)
 end
 if c then install(c, "TakeRationsPrompt", function(p) SupplyService.TakeRations(p) end) end
 Remotes.HudController.UseItem:connect(function(player, payload) SupplyService.UseItem(player, payload.Item, payload.Aim) end)
 table.insert(connections, Players.PlayerAdded:Connect(bind))
 for _, player in Players:GetPlayers() do bind(player) end
 table.insert(connections, Players.PlayerRemoving:Connect(function(player)
  SupplyService.OnDeath(player)
  local id = key(player); SupplyService.Inventories[id] = nil; SupplyService.Cooldowns[id] = nil; playersById[id] = nil; food[id] = nil; SupplyService.UseCooldowns[id] = nil
 end))
 table.insert(connections, RunService.Heartbeat:Connect(function()
  for id, search in SupplyService.Pending do
   local player = playersById[id]; local part = caches[search.cache]
   if player == nil or part == nil or generation ~= search.generation or player.Character ~= search.character or not near(player, part) or SupplyService.Phase ~= "Day" then SupplyService.Pending[id] = nil
   elseif os.clock() - search.started >= SupplyService.SearchSeconds then complete(player, search) end
  end
 end))
end
return SupplyService
