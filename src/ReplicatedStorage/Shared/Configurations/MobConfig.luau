--!strict
local RS = game:GetService("ReplicatedStorage")
local Enums = require(RS.Shared.CustomEnums.CustomEnums)
local Promise = require(RS.Packages.Promise)
local templates: { [Enums.MobType]: Model } = {}
local Config = {}
function Config.getServerExtensions() return {} end
function Config.getClientExtensions() return {} end
function Config.getMobModel(kind: Enums.MobType): Model
 if templates[kind] then return templates[kind] end
 local model = Instance.new("Model"); model.Name = kind
 local scale = if kind == "Brute" then 1.6 else 1
 local root = Instance.new("Part"); root.Name = "HumanoidRootPart"; root.Size = Vector3.new(2, 2, 1) * scale; root.Transparency = 1; root.CanCollide = false; root.Parent = model
 model.PrimaryPart = root
 local color = if kind == "Staff" then Color3.fromRGB(163,198,83) elseif kind == "Athlete" then Color3.fromRGB(216,58,54) else Color3.fromRGB(98,104,107)
 local function body(name: string, size: Vector3, offset: Vector3, tint: Color3)
  local part = Instance.new("Part"); part.Name = name; part.Size = size * scale; part.CFrame = CFrame.new(offset * scale); part.Color = tint; part.Material = Enum.Material.SmoothPlastic; part.CanCollide = name == "Torso"; part.Parent = model
  local weld = Instance.new("WeldConstraint"); weld.Part0 = root; weld.Part1 = part; weld.Parent = part
 end
 body("Torso", Vector3.new(2,2,1), Vector3.zero, color)
 body("Head", Vector3.new(1.4,1.2,1.2), Vector3.new(0,1.6,0), Color3.fromRGB(184,201,149))
 body("LeftLeg", Vector3.new(.8,2,.8), Vector3.new(-.6,-2,0), color)
 body("RightLeg", Vector3.new(.8,2,.8), Vector3.new(.6,-2,0), color)
 body("LeftArm", Vector3.new(.7,2,.8), Vector3.new(-1.4,0,-.3), color)
 body("RightArm", Vector3.new(.7,2,.8), Vector3.new(1.4,0,-.3), color)
 local humanoid = Instance.new("Humanoid"); humanoid.RequiresNeck = false; humanoid.HipHeight = 2 * scale; humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None; humanoid.Parent = model
 templates[kind] = model
 return model
end
function Config.getStatusByHealth(current: number, maximum: number): Enums.MobStatus
 return if current <= 0 then Enums.MobStatus.Destroyed elseif current < maximum * .75 then Enums.MobStatus.Damaged else Enums.MobStatus.Intact
end
function Config.giveRewards(_mob: any, _shares: { [Player]: number }) return Promise.resolve() end
-- Combat is derived by SiegeService, never by the package's predictive client channel.
function Config.validatePlayerDamage(_player: Player, _mob: any, _damage: number, _source: Instance): Promise.TypedPromise<number>
 return Promise.reject("Use authoritative CombatAction")
end
return table.freeze(Config)
