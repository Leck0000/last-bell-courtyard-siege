--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local MobService = require(ServerScriptService.Server.Systems.MobService)
local MobServerComponent = require(ServerScriptService.Server.Components.MobServerComponent)
local MobBaseExtension = require(ReplicatedStorage.Shared.Components.MobBaseExtension)
local Enums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)
local Remotes = require(ReplicatedStorage.Shared.Network.Remotes)
local SoundUtil = require(ReplicatedStorage.Shared.Utils.SoundUtil)
local SupplyService = require(ServerScriptService.Server.Modules.SupplyService)
local BarricadeService = require(ServerScriptService.Server.Modules.BarricadeService)

type Meter = { Hunger: number, Thirst: number, Infection: number, Downed: boolean, Dead: boolean, Deadline: number, MeleeAt: number }
type Enemy = { Id: number, Kind: Enums.MobType, Mob: MobServerComponent.MobServerComponent, Model: Model, Humanoid: Humanoid, Root: BasePart, State: string, Target: Vector3, Cache: string, AttackAt: number, Windup: number, PathAt: number, Busy: boolean, Waypoints: { PathWaypoint }, Index: number, Expires: number }
type Zone = { Part: BasePart, Ends: number, Kind: string }
export type Hooks = { OnDeath: ((Player) -> ())?, OnDowned: ((Player) -> ())? }
local SiegeService = {
 Phase = "Day", Night = 0, DefenseSeconds = 240, NightElapsed = 0,
 SpawnInterval = 10, NextSpawn = 0, ReviveWindow = 30, BruteWindup = 2,
 HungerDecay = .035, ThirstDecay = .055, InfectionRate = 2,
 Meters = {} :: { [Player]: Meter }, Enemies = {} :: { [number]: Enemy }, Zones = {} :: { Zone },
 Hooks = {} :: Hooks, Spawned = 0, Attacks = 0, PendingSpawns = 0,
}
local approach: PVInstance
local door: BasePart
local toxic: PVInstance
local acid: BasePart
local chemical: BasePart
local container: Instance
local serial = 0
local generation = 0
local started = false
local connections: { RBXScriptConnection } = {}
local disconnectCombat: (() -> ())? = nil
local function root(player: Player): BasePart?
 local c = player.Character
 if c == nil then return nil end
 local r = c:FindFirstChild("HumanoidRootPart")
 return if r and r:IsA("BasePart") then r else nil
end
local function humanoid(player: Player): Humanoid?
 return if player.Character then player.Character:FindFirstChildOfClass("Humanoid") else nil
end
local function flat(v: Vector3): Vector3 return Vector3.new(v.X, 0, v.Z) end
local function ground(position: Vector3): Vector3
 local params = RaycastParams.new(); params.RespectCanCollide = true; params.FilterType = Enum.RaycastFilterType.Exclude
 local skip: { Instance } = { container }
 for _, p in Players:GetPlayers() do if p.Character then table.insert(skip, p.Character) end end
 params.FilterDescendantsInstances = skip
 local hit = workspace:Raycast(position + Vector3.new(0,8,0), Vector3.new(0,-80,0), params)
 return if hit then hit.Position else position
end
local function cue(name: string, position: Vector3)
 local slot = ReplicatedStorage.Shared.Assets.Sounds:FindFirstChild(name)
 if slot and slot:IsA("Sound") then SoundUtil.playAt(slot.SoundId, position, { volume = slot.Volume }) end
 Remotes.SiegeService.WorldCue:fireAll({ Cue = name, Position = position })
end
function SiegeService.Configure(hooks: Hooks) SiegeService.Hooks = hooks end
function SiegeService.CanUse(player: Player): boolean
 local m = SiegeService.Meters[player]
 local h = humanoid(player)
 return m ~= nil and not m.Downed and not m.Dead and h ~= nil and h.Health > 0
end
function SiegeService.AddPlayer(player: Player)
 if SiegeService.Meters[player] then return end
 SiegeService.Meters[player] = { Hunger = 100, Thirst = 100, Infection = 0, Downed = false, Dead = false, Deadline = 0, MeleeAt = 0 }
end
function SiegeService.GetSurvival(player: Player)
 local m = SiegeService.Meters[player]
 return if m then table.clone(m) else nil
end
function SiegeService.DamagePlayer(player: Player, amount: number)
 local m = SiegeService.Meters[player]; local h = humanoid(player)
 if m == nil or h == nil or m.Dead or m.Downed or amount <= 0 or amount ~= amount then return end
 if h.Health - amount <= 0 then
  m.Downed = true; m.Deadline = os.clock() + SiegeService.ReviveWindow
  h.Health = 1; h.WalkSpeed = 0; h.JumpPower = 0
  BarricadeService.SetIncapacitated(player, true); SupplyService.CancelSearch(player)
  if SiegeService.Hooks.OnDowned then SiegeService.Hooks.OnDowned(player) end
 else h:TakeDamage(amount) end
end
local function die(player: Player)
 local m = SiegeService.Meters[player]
 if m == nil or m.Dead then return end
 m.Dead = true; m.Downed = false
 BarricadeService.SetIncapacitated(player, true)
 local h = humanoid(player); if h then h.Health = 0 end
 if SiegeService.Hooks.OnDeath then SiegeService.Hooks.OnDeath(player) end
end
function SiegeService.TryRevive(player: Player): boolean
 if not SiegeService.CanUse(player) then return false end
 local r = root(player); if r == nil then return false end
 local chosen: Player? = nil; local distance = 7
 for p, m in SiegeService.Meters do
  local target = root(p)
  if p ~= player and m.Downed and not m.Dead and os.clock() < m.Deadline and target then
   local d = (target.Position - r.Position).Magnitude
   if d < distance then distance = d; chosen = p end
  end
 end
 if chosen == nil then return false end
 local m = SiegeService.Meters[chosen]; local h = humanoid(chosen)
 if h == nil then return false end
 m.Downed = false; m.Deadline = 0; h.Health = 35; h.WalkSpeed = 16; h.JumpPower = 50
 BarricadeService.SetIncapacitated(chosen, false)
 return true
end
function SiegeService.GetEnemyStates()
 local result = {}
 for id, e in SiegeService.Enemies do table.insert(result, { Id = id, Kind = e.Kind, State = tostring(e.Model:GetAttribute("AIState") or e.State), Position = e.Root.Position, Target = e.Target, Cache = e.Cache, Health = e.Mob:GetInternalHealth(), Speed = e.Humanoid.WalkSpeed }) end
 return result
end
function SiegeService.EnemyBudget(count: number): number return 6 + 4 * (math.clamp(math.floor(count), 1, 4) - 1) end
local function activeCount(): number local n = SiegeService.PendingSpawns; for _ in SiegeService.Enemies do n += 1 end; return n end
local function removeEnemy(e: Enemy)
 if SiegeService.Enemies[e.Id] == nil then return end
 SiegeService.Enemies[e.Id] = nil
 if e.Mob:GetInternalHealth() > 0 then e.Mob:SafeKill() end
end
local function investigate(e: Enemy, position: Vector3, cache: string)
 if e.Kind ~= "Student" and e.Kind ~= "Athlete" then return end
 e.State = "Investigate"; e.Target = position; e.Cache = cache; e.PathAt = 0; e.Waypoints = {}; e.Expires = os.clock() + 100
 e.Model:SetAttribute("AIState", e.State); e.Model:SetAttribute("NoiseTarget", position)
 if cache == "ChemicalLocker" and e.Kind == "Student" then
  chemical:SetAttribute("NoiseInvestigations", (tonumber(chemical:GetAttribute("NoiseInvestigations")) or 0) + 1)
 end
end
function SiegeService.SpawnEnemy(kind: Enums.MobType, position: Vector3?, cache: string?): boolean
 if kind == "Brute" and (SiegeService.Phase ~= "Night" or (SiegeService.Night ~= 5 and SiegeService.Night ~= 10)) then return false end
 if activeCount() >= SiegeService.EnemyBudget(#Players:GetPlayers()) then return false end
 local epoch = generation
 SiegeService.PendingSpawns += 1
 -- Spawn only at the authored courtyard muster. No arbitrary client spawn positions.
 local spawn = ground(approach:GetPivot().Position) + Vector3.new(0, 3.2, 0)
 MobServerComponent:SpawnMobAtCFrame(kind, CFrame.new(spawn), true, true):andThen(function(mob: MobServerComponent.MobServerComponent)
  SiegeService.PendingSpawns = math.max(0, SiegeService.PendingSpawns - 1)
  if epoch ~= generation then mob:SafeKill(); return end
  local model = mob.Instance :: Model
  model.Parent = container
  local h = model:FindFirstChildOfClass("Humanoid"); local r = model.PrimaryPart
  if h == nil or r == nil then mob:SafeKill(); return end
  r:SetNetworkOwner(nil)
  h.WalkSpeed = if kind == "Athlete" then 22 elseif kind == "Brute" then 8 else 7
  serial += 1
  local e: Enemy = { Id = serial, Kind = kind, Mob = mob, Model = model, Humanoid = h, Root = r, State = if SiegeService.Phase == "Night" then "Assault" else "Patrol", Target = door.Position, Cache = "", AttackAt = 0, Windup = 0, PathAt = 0, Busy = false, Waypoints = {}, Index = 1, Expires = os.clock() + 100 }
  SiegeService.Enemies[serial] = e; SiegeService.Spawned += 1
  model:SetAttribute("AIState", e.State); model:SetAttribute("EnemyKind", kind)
  -- Consult the package extension rather than maintaining a second health/lifecycle.
  assert(MobBaseExtension.Methods.GetInternalHealth(mob) > 0)
  if position and cache then investigate(e, position, cache) end
 end):catch(function(err) SiegeService.PendingSpawns = math.max(0, SiegeService.PendingSpawns - 1); warn("Siege spawn failed", err) end)
 return true
end
function SiegeService.OnNoise(_player: Player, position: Vector3, cache: string, stage: string)
 if SiegeService.Phase ~= "Day" or stage ~= "Complete" then return end
 local chosen: Enemy? = nil
 for _, e in SiegeService.Enemies do if e.Kind == "Student" and e.State == "Patrol" then chosen = e; break end end
 if chosen then investigate(chosen, position, cache) else SiegeService.SpawnEnemy("Student", position, cache) end
end
function SiegeService.CreateZone(position: Vector3, kind: string)
 if #SiegeService.Zones >= 16 then return end
 local part = acid:Clone(); part.Name = if kind == "Acid" then "StaffAcid" else "MolotovFire"
 part.Anchored = true; part.CanCollide = false; part.CanTouch = false; part.Transparency = .25
 part.Color = if kind == "Acid" then Color3.fromRGB(163,198,83) else Color3.fromRGB(216,58,54)
 part.Size = Vector3.new(10,.2,10); part.CFrame = CFrame.new(ground(position) + Vector3.new(0,.12,0)); part.Parent = container
 local lifetime = if kind == "Acid" then (tonumber(acid:GetAttribute("Lifetime")) or 12) else 8
 table.insert(SiegeService.Zones, { Part = part, Ends = os.clock() + lifetime, Kind = kind })
end
function SiegeService.ApplyItem(player: Player, item: string, aim: Vector3, effect: SupplyService.ItemEffect)
 if not SiegeService.CanUse(player) then return end
 local m = SiegeService.Meters[player]; local h = humanoid(player); local r = root(player)
 if h == nil or r == nil then return end
 if item == "Molotov" then
  if aim.X ~= aim.X or aim.Y ~= aim.Y or aim.Z ~= aim.Z or (aim - r.Position).Magnitude > 80 then return end
  local params = RaycastParams.new(); params.RespectCanCollide = true; params.FilterType = Enum.RaycastFilterType.Exclude; params.FilterDescendantsInstances = { player.Character :: Model }
  local hit = workspace:Raycast(r.Position, aim - r.Position, params)
  SiegeService.CreateZone(if hit then hit.Position else aim, "Fire"); return
 end
 m.Hunger = math.clamp(m.Hunger + effect.Hunger,0,100); m.Thirst = math.clamp(m.Thirst + effect.Thirst,0,100); m.Infection = math.clamp(m.Infection + effect.Infection,0,100); h.Health = math.min(h.MaxHealth, h.Health + effect.Health)
end
function SiegeService.CombatAction(player: Player, action: string, _aim: Vector3): boolean
 if action == "Revive" then return SiegeService.TryRevive(player) end
 if action ~= "Melee" or not SiegeService.CanUse(player) then return false end
 local m = SiegeService.Meters[player]; local r = root(player)
 if r == nil or os.clock() < m.MeleeAt then return false end
 m.MeleeAt = os.clock() + .75; cue("MeleeSwing", r.Position)
 local chosen: Enemy? = nil; local nearest = 8
 for _, e in SiegeService.Enemies do
  local offset = e.Root.Position - r.Position; local distance = offset.Magnitude
  if distance < nearest and distance > .01 and r.CFrame.LookVector:Dot(offset.Unit) > .35 then
   local params = RaycastParams.new(); params.RespectCanCollide = true; params.FilterType = Enum.RaycastFilterType.Exclude; params.FilterDescendantsInstances = { player.Character :: Model }
   local hit = workspace:Raycast(r.Position, offset, params)
   if hit == nil or hit.Instance:IsDescendantOf(e.Model) then chosen = e; nearest = distance end
  end
 end
 if chosen then chosen.Mob:ApplyDamage(player, SupplyService.GetMeleeDamage(player)); return true end
 return false
end
function SiegeService.SetPhase(phase: string, night: number?)
 generation += 1; SiegeService.Phase = phase
 if night then SiegeService.Night = night end
 SiegeService.NightElapsed = 0; SiegeService.NextSpawn = 0
 if phase ~= "Night" then
  for _, e in SiegeService.Enemies do e.State = "Disperse"; e.Target = approach:GetPivot().Position; e.Expires = os.clock() + 8; e.PathAt = 0; e.Model:SetAttribute("AIState", "Disperse") end
  for p, m in SiegeService.Meters do
   if m.Dead then
    m.Dead = false; m.Downed = false; m.Hunger = 70; m.Thirst = 70; m.Infection = 0
    BarricadeService.SetIncapacitated(p, false)
    if typeof(p) == "Instance" then p:LoadCharacter() end
   end
  end
 end
end
function SiegeService.BeginNight(night: number) SiegeService.SetPhase("Night", night) end
function SiegeService.Dawn() SiegeService.SetPhase("Day") end
function SiegeService.ResetSession()
 generation += 1
 for _, e in SiegeService.Enemies do removeEnemy(e) end
 for _, z in SiegeService.Zones do z.Part:Destroy() end
 SiegeService.Zones = {}; SiegeService.Phase = "Day"; SiegeService.Night = 0; SiegeService.Spawned = 0; SiegeService.Attacks = 0
 for p in SiegeService.Meters do SiegeService.Meters[p] = nil; SiegeService.AddPlayer(p); BarricadeService.SetIncapacitated(p, false) end
end
local function move(e: Enemy, target: Vector3)
 if (flat(e.Root.Position - target)).Magnitude < 3 then e.Humanoid:MoveTo(e.Root.Position); return end
 if os.clock() >= e.PathAt and not e.Busy then
  e.Busy = true; e.PathAt = os.clock() + 2
  local origin = e.Root.Position
  task.spawn(function()
   local ok, err = pcall(function(): boolean
    local path = PathfindingService:CreatePath({ AgentRadius = if e.Kind == "Brute" then 2.5 else 1.5, AgentHeight = 6, AgentCanJump = true, WaypointSpacing = 4 })
    path:ComputeAsync(origin, target)
    if SiegeService.Enemies[e.Id] == nil then return true end
    e.Waypoints = if path.Status == Enum.PathStatus.Success then path:GetWaypoints() else {}; e.Index = 2
    return true
   end)
   e.Busy = false
   if not ok then warn("Siege path failed", err) end
  end)
 end
 local waypoint = e.Waypoints[e.Index]
 if waypoint and (flat(e.Root.Position - waypoint.Position)).Magnitude < 3 then e.Index += 1; waypoint = e.Waypoints[e.Index] end
 if waypoint and waypoint.Action == Enum.PathWaypointAction.Jump then e.Humanoid.Jump = true end
 e.Humanoid:MoveTo(if waypoint then waypoint.Position else target)
end
local function updateEnemy(e: Enemy)
 if e.Mob:GetInternalHealth() <= 0 then
  if e.Kind == "Staff" then cue("StaffExplosion", e.Root.Position); SiegeService.CreateZone(e.Root.Position, "Acid") end
  SiegeService.Enemies[e.Id] = nil; return
 end
 if e.State == "Disperse" then move(e, e.Target); if os.clock() >= e.Expires then removeEnemy(e) end; return end
 if SiegeService.Phase == "Day" and os.clock() >= e.Expires then removeEnemy(e); return end
 local target = e.Target
 local victim: Player? = nil; local distance = if e.State == "Assault" then math.huge else 18
 for p in SiegeService.Meters do
  local r = root(p)
  if r and SiegeService.CanUse(p) then local d = (r.Position - e.Root.Position).Magnitude; if d < distance then distance = d; target = r.Position; victim = p end end
 end
 -- The commons entrance is approached from the courtyard. Secured furniture is
 -- selected before any occupant; the same physical damage path serves patrols and waves.
 local defense: BasePart? = nil
 local commonsTarget = (flat(target - door.Position)).Magnitude < 55 or e.State == "Assault" or e.Cache == "SalvageLocker"
 if commonsTarget then
  local nearest = math.huge
  for _, part in BarricadeService.GetBarricades() do local d = (flat(part.Position - e.Root.Position)).Magnitude; if d < nearest then nearest = d; defense = part end end
 end
 if defense then target = defense.Position; victim = nil end
 local range = (flat(e.Root.Position - target)).Magnitude
 if range > (if defense then 6 else 5) then move(e, target); return end
 e.Humanoid:MoveTo(e.Root.Position)
 if os.clock() < e.AttackAt then return end
 if e.Kind == "Brute" and defense then
  if e.Windup == 0 then e.Windup = os.clock() + SiegeService.BruteWindup; e.Model:SetAttribute("AIState", "ChargeWindup"); cue("BruteCharge", e.Root.Position); return end
  if os.clock() < e.Windup then return end
  BarricadeService.BruteCharge(defense.Name); e.Windup = 0; e.Model:SetAttribute("AIState", "Assault"); e.AttackAt = os.clock() + 5; SiegeService.Attacks += 1
 elseif e.Kind == "Staff" then
  cue("StaffExplosion", e.Root.Position); SiegeService.CreateZone(e.Root.Position, "Acid"); removeEnemy(e)
 elseif defense then
  BarricadeService.Damage(defense.Name, 14); e.AttackAt = os.clock() + 2; SiegeService.Attacks += 1
 elseif victim then
  SiegeService.DamagePlayer(victim, if e.Kind == "Athlete" then 16 else 10); e.AttackAt = os.clock() + 2; SiegeService.Attacks += 1
 elseif e.State == "Investigate" then e.State = "Patrol"; e.Model:SetAttribute("AIState", "Patrol") end
end
local function largest(entry: PVInstance): BasePart?
 if entry:IsA("BasePart") then return entry end
 local best: BasePart? = nil; local area = 0
 for _, part in entry:GetDescendants() do if part:IsA("BasePart") then local s = part.Size; local a = math.max(s.X*s.Y,s.X*s.Z,s.Y*s.Z); if a > area then best = part; area = a end end end
 return best
end
local function contact(r: BasePart, part: BasePart): boolean
 local p = part.CFrame:PointToObjectSpace(r.Position)
 return math.abs(p.X) <= part.Size.X/2 + 1 and math.abs(p.Z) <= part.Size.Z/2 + 1 and math.abs(p.Y) <= part.Size.Y/2 + 4
end
function SiegeService.Step(dt: number)
 if SiegeService.Phase == "Night" then
  SiegeService.NightElapsed += dt
  if SiegeService.NightElapsed >= SiegeService.DefenseSeconds then SiegeService.Dawn()
  elseif SiegeService.NightElapsed >= SiegeService.NextSpawn then
   local escalation = math.floor(SiegeService.NightElapsed / 60)
   SiegeService.NextSpawn = SiegeService.NightElapsed + math.max(3, SiegeService.SpawnInterval - escalation - SiegeService.Night*.3)
   SiegeService.SpawnEnemy("Student")
   if SiegeService.Night >= 2 then SiegeService.SpawnEnemy("Athlete") end
   if SiegeService.Night >= 3 then SiegeService.SpawnEnemy("Staff") end
   if (SiegeService.Night == 5 or SiegeService.Night == 10) and SiegeService.NightElapsed < 1 then SiegeService.SpawnEnemy("Brute") end
  end
 end
 for _, e in SiegeService.Enemies do updateEnemy(e) end
 for i = #SiegeService.Zones, 1, -1 do
  local z = SiegeService.Zones[i]
  if os.clock() >= z.Ends then z.Part:Destroy(); table.remove(SiegeService.Zones,i)
  else
   for _, e in SiegeService.Enemies do if contact(e.Root,z.Part) then e.Mob:ApplyDamage(nil, 20 * dt) end end
   if z.Kind == "Acid" then for p in SiegeService.Meters do local r = root(p); if r and contact(r,z.Part) then SiegeService.DamagePlayer(p,8*dt); SiegeService.Meters[p].Infection = math.min(100,SiegeService.Meters[p].Infection + 3*dt) end end end
  end
 end
 local spill = largest(toxic)
 for p, m in SiegeService.Meters do
  if not m.Dead then
   m.Hunger = math.max(0,m.Hunger - SiegeService.HungerDecay*dt); m.Thirst = math.max(0,m.Thirst - SiegeService.ThirstDecay*dt)
   local r = root(p)
   if r and spill and contact(r,spill) then m.Infection = math.min(100,m.Infection + SiegeService.InfectionRate*dt) end
   if m.Hunger <= 0 or m.Thirst <= 0 or m.Infection >= 100 then SiegeService.DamagePlayer(p, 5*dt) end
   if m.Downed and os.clock() >= m.Deadline then die(p) end
  end
  if typeof(p) == "Instance" and p.Parent == Players then Remotes.SiegeService.SurvivalState:fire(p, { Hunger = m.Hunger, Thirst = m.Thirst, Infection = m.Infection, Downed = m.Downed, ReviveSeconds = if m.Downed then math.max(0,m.Deadline-os.clock()) else 0 }) end
 end
end
local function bind(p: Player)
 SiegeService.AddPlayer(p)
 local function characterAdded(c: Model)
  local h = c:FindFirstChildOfClass("Humanoid")
  if h then table.insert(connections, h.Died:Connect(function() die(p) end)) end
 end
 table.insert(connections,p.CharacterAdded:Connect(characterAdded))
 if p.Character then characterAdded(p.Character) else p:LoadCharacter() end
end
function SiegeService.Start()
 if started then return end; started = true
 -- MobService is already started by the package bootstrapper.
 assert(type(MobService.Start) == "function")
 approach = workspace.Courtyard.SiegeApproach; door = workspace.Commons.DoorSocket; toxic = workspace.ScienceLab.ToxicSpill; acid = workspace.Courtyard.AcidPool; chemical = workspace.ScienceLab.ChemicalLocker; container = workspace.Courtyard.Enemies
 acid.Transparency = 1; acid.CanCollide = false; acid.CanTouch = false
 local hooks = table.clone(SupplyService.Hooks); hooks.Noise = SiegeService.OnNoise; hooks.CanUse = SiegeService.CanUse; hooks.ApplyItem = SiegeService.ApplyItem; SupplyService.Configure(hooks)
 BarricadeService.Configure({ CanUse = SiegeService.CanUse })
 Players.CharacterAutoLoads = false
 table.insert(connections,Players.PlayerAdded:Connect(bind)); for _, p in Players:GetPlayers() do bind(p) end
 table.insert(connections,Players.PlayerRemoving:Connect(function(p) SiegeService.Meters[p] = nil; BarricadeService.RemovePlayer(p) end))
 disconnectCombat = Remotes.HudController.CombatAction:connect(function(p,payload) SiegeService.CombatAction(p,payload.Action,payload.Aim) end)
 local elapsed = 0
 table.insert(connections,RunService.Heartbeat:Connect(function(dt) elapsed += dt; if elapsed >= .25 then local step = elapsed; elapsed = 0; SiegeService.Step(step) end end))
end
return SiegeService
