--// Roblox Services //--
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

--// Dependencies //--
local MobServerComponent = require(ServerScriptService.Server.Components.MobServerComponent)
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)
local remotes = require(ReplicatedStorage.Shared.Network.MobNetwork)

--// Packages //--
local Promise = require(ReplicatedStorage.Packages.Promise)

--// Constants //--
local MOB_COLLISION_GROUP = CustomEnums.CollisionGroup.Mob
local PLAYER_COLLISION_GROUP = CustomEnums.CollisionGroup.Player

type MobComponent = MobServerComponent.MobServerComponent

--------------------------------------------------------------------------------
--// Service //--
--------------------------------------------------------------------------------

local MobService = {}

-- One handler for every mob on the server. MobServerComponent.Start runs per
-- instance, so connecting there would give one handler per spawned mob.
local function onValidateDamage(
	player: Player,
	mobInstance: Instance,
	damage: number,
	source: Instance
): Promise.TypedPromise<boolean>
	local mobComponent = MobServerComponent:FromInstance(mobInstance) :: MobComponent?
	if not mobComponent then
		return Promise.reject("Instance is not a started mob.")
	end

	return mobComponent:ValidateDamage(player, damage, source)
end

local function registerIfMissing(group: string): ()
	if not PhysicsService:IsCollisionGroupRegistered(group) then
		PhysicsService:RegisterCollisionGroup(group)
	end
end

local function registerCollisionGroups(): ()
	registerIfMissing(MOB_COLLISION_GROUP)
	-- Nothing this package depends on registers Player, and the Bootstrapper Starts
	-- MobService before player-package's PlayerService; that service sets only Player pairs.
	registerIfMissing(PLAYER_COLLISION_GROUP)

	PhysicsService:CollisionGroupSetCollidable(MOB_COLLISION_GROUP, CustomEnums.CollisionGroup.Default, true)
	PhysicsService:CollisionGroupSetCollidable(MOB_COLLISION_GROUP, PLAYER_COLLISION_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(MOB_COLLISION_GROUP, MOB_COLLISION_GROUP, false)
end

function MobService.Start(): ()
	registerCollisionGroups()
	remotes.mob.validateDamage:onRequest(onValidateDamage)
end

export type MobService = typeof(MobService)
return MobService
