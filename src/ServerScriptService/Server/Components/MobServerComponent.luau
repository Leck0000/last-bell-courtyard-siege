--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

--// Dependencies //--
local MobBaseExtension = require(ReplicatedStorage.Shared.Components.MobBaseExtension)
local NumberFormatter = require(ReplicatedStorage.Shared.Utils.NumberFormatter)
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)
local MobConfig = require(ReplicatedStorage.Shared.Configurations.MobConfig)
local MobAttributes = require(ReplicatedStorage.Shared.Modules.MobAttributes)
local Constants = require(ReplicatedStorage.Shared.Data.Constants)

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local PartCache = require(ReplicatedStorage.Packages.PartCache)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

--// Constants //--
local MOB_STATUS = CustomEnums.MobStatus

--// References //--
local MobCache: { [Model]: PartCache.PartCache<Model> } = {}

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

local MobServerComponent = {
	Tag = "MobComponent",
	Ancestors = { workspace },
	Extensions = {
		BaseComponent,
		MobBaseExtension,
		unpack(MobConfig.getServerExtensions()),
	},
}

type Contributions = { [Player]: number }

type MobServerComponentData = {
	Contributions: Contributions,
}
type MobServerComponentDataInt = {}

export type MobServerComponent =
	typeof(setmetatable({} :: MobServerComponentData, MobServerComponent))
	& typeof(Component.getExtensionsType(BaseComponent, MobBaseExtension))
	& Component.ComponentObject
type MobServerComponentInt = MobServerComponent & MobServerComponentDataInt

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function setAnchoredRecursive(instance: Instance, anchored: boolean): ()
	if instance:IsA("BasePart") then
		instance.Anchored = anchored
	end
	for _, child in instance:GetChildren() do
		setAnchoredRecursive(child, anchored)
	end
end

local function setCollisionGroupRecursive(instance: Instance, groupName: string): ()
	if instance:IsA("BasePart") then
		PhysicsService:SetPartCollisionGroup(instance, groupName)
	end
	for _, child in instance:GetChildren() do
		setCollisionGroupRecursive(child, groupName)
	end
end

local function getMobCache(mobType: CustomEnums.MobType): PartCache.PartCache<Model>
	local template = MobConfig.getMobModel(mobType)
	assert(template, `No model found for mob type {mobType}`)

	if not MobCache[template] then
		setCollisionGroupRecursive(template, CustomEnums.CollisionGroup.Mob)
		setAnchoredRecursive(template, true)

		MobCache[template] = PartCache.new({
			Template = template,
			ExpansionSize = 10,
			Size = 10,
			OnReturn = function(mobInstance)
				setAnchoredRecursive(mobInstance, true)
				for _, tag in mobInstance:GetTags() do
					mobInstance:RemoveTag(tag)
				end
				mobInstance:SetAttribute("ReturnOnDeath", nil)
				mobInstance:SetAttribute("IsHostile", nil)
				mobInstance:SetAttribute("MobType", nil)
				-- The replicated pair is part of the pooled state: left set, the next
				-- mob to reuse this model starts life Destroyed at zero health, and the
				-- client component believes it on bind.
				mobInstance:SetAttribute(MobAttributes.ReplicatedStatus, nil)
				mobInstance:SetAttribute(MobAttributes.ReplicatedHealth, nil)
			end,
		})
	end

	return MobCache[template]
end

--[[
	Distributes the associated rewards to the contributing players, based on their contributions.
]]
local function distributeRewards(self: MobServerComponentInt): ()
	local maxHealth = self:GetMobData().Health
	local contributions: Contributions = self.Contributions
	MobConfig.giveRewards(
		self,
		Sift.Dictionary.map(contributions, function(contribution: number): number
			return NumberFormatter.ClampFloat(contribution / maxHealth)
		end)
	):catch(warn)
end

--[[
	Resets the mob properties back to default, effectively respawning it.
]]
local function respawn(self: MobServerComponentInt): ()
	local maxHealth = self:GetMobData().Health
	self:SetInternalHealth(maxHealth) -- This will be observed (look at :Start()) and then we'll have the internal status updated to "Intact".
	local contributions: Contributions = self.Contributions
	table.clear(contributions)
end

--[[
	Handles the internal status update to make any necessary changes based on the new status, such
	as setting the mob to be respawned after a certain delay.
]]
local function handleStatusUpdate(self: MobServerComponentInt): ()
	local CurrentStatus = self:GetInternalStatus()
	-- Published before the branch below, not after: the pool-return arm yields and
	-- then strips the instance, so a later publish would never reach a client.
	self:SetAttribute(MobAttributes.ReplicatedStatus, CurrentStatus)

	if CurrentStatus ~= MOB_STATUS.Destroyed then
		return
	end

	distributeRewards(self)

	if self:IsRespawnEnabled() then
		local mobData = self:GetMobData()
		local respawnDelay = assert(
			mobData.RespawnDelay,
			`Mob type {self:GetMobType()} has RespawnEnabled set but declares no RespawnDelay`
		)
		self:AddTask(task.delay(respawnDelay, function()
			respawn(self)
		end))
	elseif self:GetAttribute("ReturnOnDeath") ~= false then
		task.wait(Constants.ReplicationToleranceMiliseconds / 1000)
		-- No forceReturn: PartCache's InUse lookup is what catches a double return,
		-- and every instance here is one this cache issued.
		getMobCache(self:GetMobType()):Return(self.Instance :: Model)
	else
		self.Instance.Parent = ReplicatedStorage
		task.delay(Constants.ReplicationToleranceMiliseconds / 1000, function()
			self.Instance:Destroy()
		end)
	end
end

--[[
	Updates the internal status of the mob based on its health.
]]
local function handleHealthUpdate(self: MobServerComponentInt): ()
	local maxHealth = self:GetMobData().Health
	local CurrentHealth = self:GetInternalHealth()
	local NewMobStatus = MobConfig.getStatusByHealth(CurrentHealth, maxHealth)
	self:SetAttribute(MobAttributes.ReplicatedHealth, CurrentHealth)
	self:SetInternalStatus(NewMobStatus)
end

--------------------------------------------------------------------------------
--// Static Methods //--
--------------------------------------------------------------------------------

function MobServerComponent.SpawnMobAtCFrame(
	self: MobServerComponentInt,
	mobType: CustomEnums.MobType,
	cframe: CFrame,
	isHostile: boolean?,
	returnOnDeath: boolean?
): Promise.TypedPromise<MobServerComponent>
	local mobInstance = getMobCache(mobType):Get()
	mobInstance:SetAttribute("ReturnOnDeath", returnOnDeath)
	mobInstance:SetAttribute("IsHostile", isHostile)
	mobInstance:SetAttribute("MobType", mobType)
	mobInstance:AddTag(MobServerComponent.Tag)
	mobInstance:PivotTo(cframe)
	setAnchoredRecursive(mobInstance, false)

	return Promise.new(function(resolve, reject): ()
		self:WaitForInstance(mobInstance):andThen(function(componentObject: Component.ComponentObject): ()
			resolve(componentObject :: MobServerComponent)
		end, reject)
	end)
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function MobServerComponent.SafeKill(self: MobServerComponentInt): ()
	self:SetInternalHealth(0)
end

--[[
	Checks Client request to validate and deal damage to the mob.

	@param player: Player -- Player who's trying to damage a mob.
	@param damage: number -- Amount of damage the caller is asking to deal.
	@param source: Instance -- What dealt the damage; handed to MobConfig.validatePlayerDamage.
	@return Promise<boolean> -- Rejects with the refusal reason; the caller is entitled to it.
]]
function MobServerComponent.ValidateDamage(
	self: MobServerComponentInt,
	player: Player,
	damage: number,
	source: Instance
): Promise.TypedPromise<boolean>
	if self:IsHostile() then
		return Promise.reject("Mob is hostile.")
	end

	-- Avoid damage if the building is already destroyed.
	local CurrentStatus = self:GetInternalStatus()
	if CurrentStatus == MOB_STATUS.Destroyed then
		return Promise.reject("Mob is already destroyed.")
	end

	return Promise.new(function(resolve, reject): ()
		if MobConfig.validatePlayerDamage then
			MobConfig.validatePlayerDamage(player, self, damage, source):andThen(resolve, reject)
		else
			-- No configured validator means the request is taken at face value.
			resolve(damage)
		end
	end):andThen(function(validDamage: number): boolean
		-- Apply the damage.
		return self:ApplyDamage(player, validDamage)
	end)
end

--[[
	Apply damage to the building and keep track of the contributions made by the [Player].

	@param player: Player? -- The player who dealt some damage to the mob. Damage with no
		attribution -- environmental, or another mob -- passes nil.
	@param damage: number -- Amount of damage being applied.
	@return boolean -- Whether any health was actually taken off.
]]
function MobServerComponent.ApplyDamage(self: MobServerComponentInt, player: Player?, damage: number): boolean
	-- Set the actual health values.
	local CurrentHealth = self:GetInternalHealth()
	local NewHealth = math.max(CurrentHealth - damage, 0)
	local DamageDealt = (CurrentHealth - NewHealth) -- Important so players aren't contributing more than than possible.

	-- Unattributed damage still lands on the mob; it just earns nobody a reward share.
	if player then
		-- Add the [Player] contribution to the table.
		local contributions: Contributions = self.Contributions
		if not contributions[player] then
			contributions[player] = 0
		end
		contributions[player] += DamageDealt
	end

	self:SetInternalHealth(NewHealth)
	return DamageDealt > 0
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function MobServerComponent.Construct(self: MobServerComponentInt): ()
	self.Contributions = {}
end

function MobServerComponent.Start(self: MobServerComponentInt): ()
	-- Listen for changes in the mob health.
	self:Observer(self.InternalHealth):onBind(function()
		handleHealthUpdate(self)
	end)

	-- Listen for changes in the mob status.
	self:Observer(self.InternalStatus):onBind(function()
		handleStatusUpdate(self)
	end)
end

Component.new(MobServerComponent)
return MobServerComponent :: MobServerComponent
