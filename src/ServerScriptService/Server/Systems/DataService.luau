--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileService = require(ServerScriptService.Server.Systems.Vendor.ProfileService)
local SyncService = require(ServerScriptService.Server.Systems.SyncService)

local DataPath = require(ReplicatedStorage.Shared.Utils.DataPath)
local DefaultDataConfig = require(ServerScriptService.Server.Data.DefaultDataConfig)
local FlattenTemplate = require(ReplicatedStorage.Shared.Utils.FlattenTemplate)
local InstanceFactory = require(ReplicatedStorage.Shared.Utils.InstanceFactory)
local PlayerAtoms = require(ReplicatedStorage.Shared.Modules.PlayerAtoms)
local PlayerDataTypes = require(ReplicatedStorage.Shared.Types.PlayerDataTypes)

local Charm = require(ReplicatedStorage.Packages.Charm)
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Sift = require(ReplicatedStorage.Packages.Sift)

type PlayerData = PlayerDataTypes.PlayerData
type PlayerDataValue = PlayerDataTypes.PlayerDataValue
type Profile = PlayerDataTypes.Profile
type ProfileStore = PlayerDataTypes.ProfileStore
type ProfileTemplate = PlayerDataTypes.ProfileTemplate
type DataMigrator = PlayerDataTypes.DataMigrator
type LeaderboardData = PlayerDataTypes.LeaderboardData

local ZERO_WIDTH_SPACE = "\u{200B}"
-- Saved-profile keys: renaming either orphans every existing player's value. Never move
-- them to Shared/Data/Constants: that path is the game's, and a package copy double-mounts.
local LAST_LOGIN_KEY = "LastLogin"
local PLAY_TIME_KEY = "Playtime"
local STRICT_MODE = RunService:IsStudio()

local PlayersData: { [Player]: PlayerData } = {}
local Loaded: { [Player]: boolean } = {}
local sessionData: { [Player]: { StartTime: number } } = {}
local janitors: { [Player]: Janitor.Janitor } = {}
local loadListeners: { [Player]: { () -> () } } = {}

local fullyFlatTemplate: PlayerData = {}
local registeredTemplate: PlayerData = {}
local templateAtom = Charm.atom({} :: PlayerData)
local sharedFullKeys: { [string]: boolean } = {}
local validKeys: { [string]: boolean } = {}
local profileStore: ProfileStore
local templateSealed = false

local DataService = {}

function DataService.registerTemplate(key: string, defaults: PlayerDataValue): ()
	assert(not templateSealed, `registerTemplate called after Start: {key}`)
	assert(registeredTemplate[key] == nil, `duplicate template key: {key}`)
	registeredTemplate[key] = defaults
end

DataService.registerTemplate(LAST_LOGIN_KEY, 0)
DataService.registerTemplate(PLAY_TIME_KEY, 0)

local dataNamespace = SyncService.namespace("data")

dataNamespace:playerSignal("playerData", function(userId: number): () -> PlayerAtoms.PlayerSharedData
	return function(): PlayerAtoms.PlayerSharedData
		return PlayerAtoms.getPlayerData(userId)
	end
end)

if STRICT_MODE then
	dataNamespace:globalSignal("template", templateAtom)
end

local function isSharedRealmKey(fullKey: string): boolean
	-- Callers always validate `validKeys[fullKey]` before reaching here, so an
	-- empty-path key (fullKey == "") would have been rejected upstream. We can
	-- safely index path[1] without a length guard.
	local path = DataPath.split(fullKey)
	return registeredTemplate[path[1]] ~= nil
end

local function notifyLoaded(player: Player): ()
	Loaded[player] = true
	local listeners = loadListeners[player]
	if listeners then
		loadListeners[player] = nil
		for _, listener in listeners do
			task.spawn(listener)
		end
	end
end

local function waitForLoaded(player: Player): Promise.TypedPromise<()>
	if Loaded[player] then
		return Promise.resolve()
	end

	return Promise.new(function(resolve, reject)
		if not player:IsDescendantOf(Players) then
			reject(`{player.Name} left the game!`)
			return
		end

		local listeners = loadListeners[player]
		if not listeners then
			listeners = {}
			loadListeners[player] = listeners
		end
		table.insert(listeners, function()
			resolve()
		end)
	end)
end

local function lookupMigrator(nextVersion: number): DataMigrator?
	for _, migration in DefaultDataConfig.Migrator do
		if migration.ToVersion == nextVersion then
			return migration
		end
	end
	return nil
end

local function migratePlayerData(player: Player, playerProfile: Profile): boolean
	local currentVersion = playerProfile.Data.Version
	if typeof(currentVersion) ~= "number" then
		playerProfile.Data.Version = 0
	end

	while (playerProfile.Data.Version :: number) < DefaultDataConfig.ProfileTemplate.Version do
		local nextVersion = (playerProfile.Data.Version :: number) + 1
		local migrator = lookupMigrator(nextVersion)
		if migrator then
			local ok, result = pcall(migrator.Migrate, player, playerProfile.Data)
			if not ok then
				warn(`Error migrating {player.Name}'s data to version {nextVersion}: {result}`)
				playerProfile:Release()
				player:Kick(`Error migrating {player.Name}'s data to version {nextVersion}: {result}`)
				return false
			end

			local migratedData = result :: PlayerData
			migratedData.Version = nextVersion
			playerProfile.Data = migratedData
		else
			warn(`No migrator found for version {nextVersion}`)
			playerProfile:Release()
			player:Kick(`No migrator found for version {nextVersion}`)
			return false
		end
	end

	playerProfile.Data = Sift.Dictionary.mergeDeep(fullyFlatTemplate, playerProfile.Data)
	return true
end

local function fetchPlayerProfile(player: Player): Promise.TypedPromise<Profile>
	return Promise.new(function(resolve, reject)
		local loaded: Profile? = profileStore:LoadProfileAsync(`Player_{player.UserId}`, "ForceLoad") :: Profile?
		if loaded == nil then
			player.Kick(player, "Error while loading data, Please Rejoin!")
			reject(`Error loading profile for {player.Name}`)
			return
		end

		local playerProfile = loaded
		playerProfile:AddUserId(player.UserId)
		playerProfile:ListenToRelease(function()
			PlayersData[player] = nil
			task.delay(60, function()
				if player:IsDescendantOf(Players) then
					player:Kick("Profile was released! Kicking player...")
				end
			end)
		end)

		if not player:IsDescendantOf(Players) then
			playerProfile:Release()
			reject(`Player {player.Name} is not a descendant of Players!`)
			return
		end

		resolve(playerProfile)
	end)
end

local function seedAtomFromProfile(player: Player, playerProfile: Profile): ()
	local nested: PlayerAtoms.PlayerSharedData = {}
	for fullKey in sharedFullKeys do
		local path = DataPath.split(fullKey)
		local value = playerProfile.Data[fullKey]
		local updated = DataPath.setAt(nested :: PlayerData, path, value)
		nested = updated :: PlayerAtoms.PlayerSharedData
	end
	PlayerAtoms.setPlayerData(player.UserId, nested)
end

local function setupLeaderboardForPlayer(player: Player, janitor: Janitor.Janitor): ()
	local leaderstats = InstanceFactory.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player
	janitor:Add(leaderstats, "Destroy")

	for _, leaderboardData: LeaderboardData in DefaultDataConfig.Leaderboard do
		local stat = InstanceFactory.new("StringValue")
		stat.Name = leaderboardData.DisplayName
		stat.Parent = leaderstats

		if leaderboardData.IsPrimary then
			local primary = InstanceFactory.new("BoolValue")
			primary.Name = "IsPrimary"
			primary.Value = true
			primary.Parent = stat
		end

		local path = DataPath.split(leaderboardData.DataKey)
		local unsub = Charm.subscribe(function(): PlayerDataValue?
			return DataPath.getAt(PlayerAtoms.getPlayerData(player.UserId) :: PlayerData, path)
		end, function(value)
			if typeof(value) == "number" then
				local digitCount = math.floor(math.log10(math.max(value, 1))) + 1
				stat.Value = ZERO_WIDTH_SPACE:rep(digitCount) .. leaderboardData.Formatter(value)
			else
				stat.Value = "--"
			end
		end)
		janitor:Add(unsub, true)
	end
end

--- `Start` connects PlayerAdded then replays `Players:GetPlayers()`, so a player in
--- that window enters twice — and ProfileService yoinks one of the two loads to nil.
local function onPlayerAdded(player: Player): ()
	if janitors[player] then
		return
	end

	local janitor = Janitor.new()
	janitors[player] = janitor

	fetchPlayerProfile(player)
		:andThen(function(playerProfile: Profile)
			janitor:Add(playerProfile, "Release", "Profile")

			local migrated = migratePlayerData(player, playerProfile)
			if not migrated then
				return
			end

			PlayersData[player] = playerProfile.Data

			seedAtomFromProfile(player, playerProfile)

			sessionData[player] = { StartTime = DateTime.now().UnixTimestamp }
			notifyLoaded(player)

			-- DefaultDataConfig.Leaderboard is a required field (typed as
			-- { LeaderboardData }), so we always invoke setupLeaderboardForPlayer
			-- — when the array is empty, the for-loop inside is a no-op.
			setupLeaderboardForPlayer(player, janitor)

			task.delay(0, function()
				DataService:Set(player, LAST_LOGIN_KEY, DateTime.now().UnixTimestamp)
			end)
		end)
		:catch(function(err)
			warn(`DataService:_OnPlayerAdded() | Error fetching profile for {player.Name}: {err}`)
		end)
end

local function onPlayerRemoving(player: Player): ()
	local session = sessionData[player]
	if session then
		local sessionLength = math.ceil(DateTime.now().UnixTimestamp - session.StartTime)
		if sessionLength > 0 then
			DataService:Increment(player, PLAY_TIME_KEY, sessionLength)
		end
		sessionData[player] = nil
	end

	PlayerAtoms.removePlayer(player.UserId)

	local janitor = janitors[player]
	if janitor then
		janitor:Destroy()
	end
	janitors[player] = nil
	PlayersData[player] = nil
	Loaded[player] = nil
	loadListeners[player] = nil
end

local function sealTemplate(): ()
	templateSealed = true
	if STRICT_MODE then
		templateAtom(table.clone(registeredTemplate))
	end

	local profileTemplate: ProfileTemplate = {
		Shared = registeredTemplate,
		Server = DefaultDataConfig.ProfileTemplate.Server,
		Version = DefaultDataConfig.ProfileTemplate.Version,
	}
	local flatProfileTemplate = FlattenTemplate.flatten(profileTemplate)

	sharedFullKeys = FlattenTemplate.getFullKeys({}, registeredTemplate)
	validKeys = FlattenTemplate.getFullKeys({}, flatProfileTemplate)

	-- Persisted data addresses nested leaves with slash-separated full keys.
	fullyFlatTemplate = {}
	for fullKey in validKeys do
		local path = DataPath.split(fullKey)
		fullyFlatTemplate[fullKey] = DataPath.getAt(flatProfileTemplate, path) :: PlayerDataValue
	end
end

function DataService.Start(): ()
	sealTemplate()

	local profileStoreIndex: unknown = DefaultDataConfig.ProfileStoreName
	local store: unknown =
		ProfileService.GetProfileStore(profileStoreIndex :: { Name: string, Scope: unknown }, fullyFlatTemplate)
	profileStore = store :: ProfileStore

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

function DataService.PlayerLoaded(self: DataService, player: Player): Promise.TypedPromise<()>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end

	return waitForLoaded(player)
end

function DataService.Get<T>(self: DataService, player: Player, fullKey: string): Promise.TypedPromise<T>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end
	if type(fullKey) ~= "string" then
		return Promise.reject("fullKey must be a string")
	end

	return self:PlayerLoaded(player):andThen(function()
		if not validKeys[fullKey] then
			return Promise.reject(`DataService:Get() | {fullKey} is not a valid key!`)
		end

		if isSharedRealmKey(fullKey) then
			local path = DataPath.split(fullKey)
			local value = DataPath.getAt(PlayerAtoms.getPlayerData(player.UserId) :: PlayerData, path)
			return value :: T
		end

		local profile = PlayersData[player]
		assert(profile ~= nil, `DataService:Get() | No profile for {player.Name}`)
		return (profile[fullKey] :: unknown) :: T
	end)
end

function DataService.Set<T>(self: DataService, player: Player, fullKey: string, value: T): Promise.TypedPromise<T>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end
	if type(fullKey) ~= "string" then
		return Promise.reject("fullKey must be a string")
	end
	if value == nil then
		return Promise.reject("Value cannot be nil")
	end

	return self:PlayerLoaded(player):andThen(function()
		if not validKeys[fullKey] then
			return Promise.reject(`DataService:Get() | {fullKey} is not a valid key!`)
		end

		local profile = PlayersData[player]
		assert(profile ~= nil, `DataService:Set() | No profile for {player.Name}`)
		local widened: PlayerDataValue = (value :: unknown) :: PlayerDataValue
		profile[fullKey] = widened

		if isSharedRealmKey(fullKey) then
			local path = DataPath.split(fullKey)
			PlayerAtoms.setPlayerAtPath(player.UserId, path, widened)
		end

		return value
	end)
end

function DataService.Remove(self: DataService, player: Player, fullKey: string): Promise.TypedPromise<()>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end
	if type(fullKey) ~= "string" then
		return Promise.reject("fullKey must be a string")
	end

	return self:PlayerLoaded(player):andThen(function()
		if not validKeys[fullKey] then
			return Promise.reject(`DataService:Remove() | {fullKey} is not a valid key!`)
		end

		local profile = PlayersData[player]
		assert(profile ~= nil, `DataService:Remove() | No profile for {player.Name}`)
		profile[fullKey] = nil

		if isSharedRealmKey(fullKey) then
			PlayerAtoms.removePlayerAtPath(player.UserId, DataPath.split(fullKey))
		end

		return Promise.resolve()
	end)
end

function DataService.Update<T>(
	self: DataService,
	player: Player,
	fullKey: string,
	mutator: (T) -> T
): Promise.TypedPromise<T>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end
	if type(fullKey) ~= "string" then
		return Promise.reject("fullKey must be a string")
	end
	if type(mutator) ~= "function" then
		return Promise.reject("Mutator must be a function")
	end

	return self:Get(player, fullKey):andThen(function(value: T)
		local ok, result = pcall(mutator, value)
		if not ok then
			warn(`DataService:Update() | Error updating {fullKey}: {result}`)
			return Promise.reject(`DataService:Update() | Error updating {fullKey}: {result}`)
		end

		return self:Set(player, fullKey, result :: T)
	end)
end

function DataService.Increment(
	self: DataService,
	player: Player,
	fullKey: string,
	amount: number?
): Promise.TypedPromise<number>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end
	if type(fullKey) ~= "string" then
		return Promise.reject("fullKey must be a string")
	end

	local resolvedAmount: number
	if amount == nil then
		resolvedAmount = 1
	else
		if type(amount) ~= "number" then
			return Promise.reject("Amount must be a number")
		end
		resolvedAmount = amount
	end

	if resolvedAmount <= 0 then
		return Promise.reject("Amount must be greater than 0 - use DataService:Decrement")
	end

	return self:Update(player, fullKey, function(value: number): number
		return value + resolvedAmount
	end)
end

function DataService.Decrement(
	self: DataService,
	player: Player,
	fullKey: string,
	amount: number?
): Promise.TypedPromise<number>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end
	if type(fullKey) ~= "string" then
		return Promise.reject("fullKey must be a string")
	end

	local resolvedAmount: number
	if amount == nil then
		resolvedAmount = 1
	else
		if type(amount) ~= "number" then
			return Promise.reject("Amount must be a number")
		end
		resolvedAmount = amount
	end

	if resolvedAmount <= 0 then
		return Promise.reject("Amount must be greater than 0 - use DataService:Increment")
	end

	return self:Update(player, fullKey, function(value: number): number
		return value - resolvedAmount
	end)
end

function DataService.Reset(self: DataService, player: Player): Promise.TypedPromise<()>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end

	return Promise.new(function(resolve, _reject)
		local playerProfile = self:GetPlayerProfile(player)
		playerProfile.Data = Sift.Dictionary.copyDeep(fullyFlatTemplate)
		playerProfile:Save()
		player:Kick("Your data has been reset!")
		resolve()
	end)
end

function DataService.ForceSave(self: DataService, player: Player): Promise.TypedPromise<()>
	if not player:IsA("Player") then
		return Promise.reject("Player must be a Player instance")
	end

	return Promise.new(function(resolve, _reject)
		local playerProfile = self:GetPlayerProfile(player)
		playerProfile:Save()
		player:Kick("Your data has been saved!")
		resolve()
	end)
end

function DataService.GetPlayerProfile(_self: DataService, player: Player): Profile
	local janitor = janitors[player]
	if not janitor then
		error(`DataService:GetPlayerProfile() | No janitor found for player {player.Name}`)
	end

	local playerProfile: Profile? = janitor:Get("Profile") :: Profile?
	if not playerProfile then
		error(`DataService:GetPlayerProfile() | No profile found for player {player.Name}`)
	end

	return playerProfile
end

export type DataService = typeof(DataService)

return DataService
