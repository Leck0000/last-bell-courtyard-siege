--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Dependencies //--
local MobBaseExtension = require(ReplicatedStorage.Shared.Components.MobBaseExtension)
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)
local MobConfig = require(ReplicatedStorage.Shared.Configurations.MobConfig)
local MobAttributes = require(ReplicatedStorage.Shared.Modules.MobAttributes)
local remotes = require(ReplicatedStorage.Shared.Network.MobNetwork)

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local MOB_STATUS = CustomEnums.MobStatus

--// Fusion References //--
local peek = Fusion.peek

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

local MobClientComponent = {
	Tag = "MobComponent",
	Ancestors = { workspace },
	Extensions = {
		BaseComponent,
		MobBaseExtension,
		unpack(MobConfig.getClientExtensions()),
	},
}

type MobClientComponentData = {
	HealthDelta: Fusion.Value<number>,
	ClientHealth: Fusion.Computed<number>,
}
type MobClientComponentDataInt = {}

export type MobClientComponent =
	typeof(setmetatable({} :: MobClientComponentData, MobClientComponent))
	& typeof(Component.getExtensionsType(BaseComponent))
	& typeof(Component.getExtensionsType(MobBaseExtension))
	& Component.ComponentObject
type MobClientComponentInt = MobClientComponent & MobClientComponentDataInt

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
	Apply damage by incrementing "self.HealthDelta" and validating the
	request to actually make the health change.

	@param damage: number -- Amount of damage the caller wants to deal.
	@param source: Instance -- What is dealing the damage; the server hands it to
		MobConfig.validatePlayerDamage.
	@return Promise<boolean> -- Rejects with the server's refusal reason.
]]
function MobClientComponent.AttemptDamage(
	self: MobClientComponentInt,
	damage: number,
	source: Instance
): Promise.TypedPromise<boolean>
	if self:GetInternalStatus() == MOB_STATUS.Destroyed or peek(self.ClientHealth) <= 0 then
		return Promise.reject("Mob is already destroyed.")
	end

	self.HealthDelta:set(peek(self.HealthDelta) - damage)

	-- Hand-rolled rather than `:finally`: the reply is a Remo promise, and this is
	-- what keeps the rejection reason and the declared return type intact.
	return Promise.new(function(resolve, reject): ()
		local function undoPrediction(): ()
			self.HealthDelta:set(peek(self.HealthDelta) + damage)
		end

		remotes.mob.validateDamage:request(self.Instance, damage, source):andThen(function(applied: boolean): ()
			undoPrediction()
			resolve(applied)
		end, function(reason: unknown): ()
			undoPrediction()
			reject(reason)
		end)
	end)
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function MobClientComponent.Construct(self: MobClientComponentInt): ()
	self.HealthDelta = self:Value(0)

	-- Setup ClientHealth to listen for changes in "self.InternalHealth" + "self.HealthDelta" for visual feedback purposes.
	local maxHealth = self:GetMobData().Health
	self.ClientHealth = self:Computed(function(use: Fusion.Use): number
		local InternalHealth: number = self:GetInternalHealth(use)
		local Delta: number = use(self.HealthDelta)
		local NewHealth = math.clamp((InternalHealth + Delta), 0, maxHealth)
		return NewHealth
	end)
end

function MobClientComponent.Start(self: MobClientComponentInt): ()
	-- Listen for server changes in the mob health. An unset attribute means the
	-- server has not published yet, so the locally derived defaults stand.
	self:ObserveAttribute(MobAttributes.ReplicatedHealth, function(newHealth: number?)
		if newHealth == nil then
			return
		end

		self:SetInternalHealth(newHealth)
	end)

	-- Listen for server changes in the mob status.
	self:ObserveAttribute(MobAttributes.ReplicatedStatus, function(newStatus: CustomEnums.MobStatus?)
		if newStatus == nil then
			return
		end

		self:SetInternalStatus(newStatus)
	end)
end

Component.new(MobClientComponent)
return MobClientComponent :: MobClientComponent
