--// Roblox Services //--
local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

--// Services & Controllers //--
local SyncService = require(ServerScriptService.Server.Systems.SyncService)

--// Dependencies //--
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)

--// Packages //--
local Charm = require(ReplicatedStorage.Packages.Charm)
local Promise = require(ReplicatedStorage.Packages.Promise)
local remotes = require(ReplicatedStorage.Shared.Network.PlayerNetwork)

--// Constants //--
local FAVORITES_PROXY_URL = "https://games.roproxy.com/v2/users/%d/favorite/games?limit=100"
local GAME_ID = game.GameId
local CHARACTERS_FOLDER_NAME = "Characters"

--- How long GetCharacter waits on a respawn before it rejects.
local CHARACTER_TIMEOUT = 60

--- How long a character binding waits for the Humanoid that `CharacterAdded`
--- does not guarantee is there yet. Bounded, where Knit's bare `WaitForChild`
--- was not: this also runs from the bind-and-check in `Start`, and an unbounded
--- wait there would park the bootstrapper on one malformed rig.
local HUMANOID_TIMEOUT = 5

--- How long a placement waits for a seated humanoid to stand up. Knit spun on
--- `while wasSeated do task.wait() end` with no exit, so a humanoid that never
--- raised `Seated` left the caller's promise pending for the life of the server.
local UNSEAT_TIMEOUT = 5

type FavoriteGame = {
	id: number,
	name: string,
	description: string,
	creator: { id: number, type: string, name: string },
	rootPlace: { id: number, type: string },
	created: string,
	updated: string,
	placeVisits: number,
}

--------------------------------------------------------------------------------
--// Service //--
--------------------------------------------------------------------------------

local PlayerService = {}
export type PlayerService = typeof(PlayerService)

--// References //--
local charactersFolder: Folder? = nil

--- Guards the bind-and-check in `Start`: a player who joins between the connect
--- and the `GetPlayers()` loop is handled twice, and a second pass would issue a
--- second favorites request and a second `CharacterAdded` connection.
local trackedPlayers: { [Player]: true } = {}

--- The character each player was last bound for, so the same model cannot pick
--- up two `Died` connections when `CharacterAdded` fires in the gap between the
--- connect and the `player.Character` check below it.
local characterByPlayer: { [Player]: Model } = {}

--- Consumer-owned mirror of every live answer, keyed by user ID. `nil` means the
--- favorites endpoint has not answered yet — Knit's `CreateProperty(true)`
--- reported those players as having favorited the game, including every Studio
--- session and every roproxy failure.
local gameFavoritedByUserId = Charm.atom({} :: { [number]: boolean? })
local sync = SyncService.namespace("player")

-- A plain closure rather than `Charm.computed`, as group-reward-package's player
-- signal is. Charm tracks dependencies by what the getter reads when it is
-- called, so the read below still registers.
sync:playerSignal("gameFavorited", function(userId: number): Charm.Getter<boolean?>
	return function(): boolean?
		return gameFavoritedByUserId()[userId]
	end
end)

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

--- Hand-rolled rather than `Promise.fromEvent`: that helper declares a
--- structural Signal an RBXScriptSignal cannot satisfy, because its `Connect`
--- hands back an RBXScriptConnection in an invariant position. Knit bought the
--- conversion with `Signal.Wrap`, which leaked one live connection per call —
--- the wrapper only releases it in `Destroy`, and nothing here ever called that.
local function promiseNextCharacter(player: Player): Promise.TypedPromise<Model>
	return Promise.new(function(resolve, _reject, onCancel): ()
		local connection: RBXScriptConnection
		connection = player.CharacterAdded:Connect(function(character: Model): ()
			connection:Disconnect()
			resolve(character)
		end)

		onCancel(function(): ()
			connection:Disconnect()
		end)
	end)
end

--- Resolves when the humanoid leaves its seat. A re-seat is ignored rather than
--- consuming the wait: Knit used `Seated:Once`, so an `active = true` delivery
--- burned the one-shot and the placement never happened.
local function promiseUnseated(humanoid: Humanoid): Promise.TypedPromise<()>
	return Promise.new(function(resolve, _reject, onCancel): ()
		local connection: RBXScriptConnection
		connection = humanoid.Seated:Connect(function(active: boolean): ()
			if active then
				return
			end

			connection:Disconnect()
			resolve()
		end)

		onCancel(function(): ()
			connection:Disconnect()
		end)
	end)
end

local function findHumanoid(character: Model): Humanoid?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil
	end

	assert(humanoid:IsA("Humanoid"), "FindFirstChildOfClass returned something other than a Humanoid")
	return humanoid
end

--- The guard is a precondition, not decoration: RequestStreamAroundAsync raises
--- "No workspace or streaming enabled not active" on a place with streaming off.
local function requestStreamAround(player: Player, position: Vector3): ()
	if not Workspace.StreamingEnabled then
		return
	end

	player:RequestStreamAroundAsync(position)
end

local function placeCharacter(character: Model, target: CFrame): ()
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	assert(rootPart ~= nil and rootPart:IsA("BasePart"), "Character has no HumanoidRootPart to place")

	rootPart.AssemblyAngularVelocity = Vector3.zero
	rootPart.AssemblyLinearVelocity = Vector3.zero
	character:PivotTo(target)
end

--- Resolves with the character once it stands at `target`.
local function moveCharacter(character: Model, target: CFrame): Promise.TypedPromise<Model>
	local humanoid = findHumanoid(character)
	assert(humanoid ~= nil, "GetCharacter resolved a character with no Humanoid")

	if not humanoid.Sit then
		placeCharacter(character, target)
		return Promise.resolve(character)
	end

	-- Connected before `Sit` is cleared, so the answer cannot arrive first.
	local unseated =
		promiseUnseated(humanoid):timeout(UNSEAT_TIMEOUT, "Failed to unseat the character. timeout exceeded!")

	humanoid.Sit = false

	return unseated:andThen(function(): Model
		-- The seat weld is torn down on the step after `Seated` reports the
		-- stand-up; placing inside that step lets the weld drag the character
		-- back to the seat.
		task.wait()
		placeCharacter(character, target)
		return character
	end)
end

local function findOrCreateCharactersFolder(): Folder
	local existing = Workspace:FindFirstChild(CHARACTERS_FOLDER_NAME)
	if existing ~= nil then
		assert(existing:IsA("Folder"), `Workspace.{CHARACTERS_FOLDER_NAME} must be a Folder`)
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = CHARACTERS_FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

local function registerCollisionGroups(): ()
	if not PhysicsService:IsCollisionGroupRegistered(CustomEnums.CollisionGroup.Player) then
		PhysicsService:RegisterCollisionGroup(CustomEnums.CollisionGroup.Player)
	end

	PhysicsService:CollisionGroupSetCollidable(
		CustomEnums.CollisionGroup.Player,
		CustomEnums.CollisionGroup.Default,
		true
	)
	PhysicsService:CollisionGroupSetCollidable(
		CustomEnums.CollisionGroup.Player,
		CustomEnums.CollisionGroup.Player,
		false
	)
end

--- Writes replace the whole map: Charm compares by reference, so mutating in
--- place would leave subscribers unnotified. A player who has already left is
--- dropped — the favorites request outlives the session it was made for.
local function setGameFavorited(player: Player, isFavorited: boolean): ()
	if trackedPlayers[player] == nil then
		return
	end

	local nextGameFavoritedByUserId = table.clone(gameFavoritedByUserId())
	nextGameFavoritedByUserId[player.UserId] = isFavorited
	gameFavoritedByUserId(nextGameFavoritedByUserId)
end

local function refreshGameFavorited(player: Player): ()
	-- roproxy answers for real user IDs only. A Studio play-solo player has none,
	-- so the answer stays unknown rather than becoming a claim either way.
	if player.UserId <= 0 then
		return
	end

	PlayerService:GetFavorites(player)
		:andThen(function(favorites: { FavoriteGame }): ()
			for _, favorite in favorites do
				if favorite.id == GAME_ID then
					setGameFavorited(player, true)
					return
				end
			end

			setGameFavorited(player, false)
		end)
		:catch(function(err: unknown): ()
			warn(`[PlayerService]: failed to read the favorites of {player.Name}: {err}`)
		end)
end

local function onCharacterAdded(player: Player, character: Model): ()
	assert(charactersFolder ~= nil, "PlayerService.Start must run before a character is bound")

	if characterByPlayer[player] == character then
		return
	end

	characterByPlayer[player] = character
	character.Parent = charactersFolder

	-- `CharacterAdded` fires from inside the character's own assembly — Roblox
	-- parents the model and adds its Humanoid after — so a non-yielding read
	-- races it and answers nil on exactly the frame this hook runs. Knit yielded
	-- here on `character:WaitForChild("Humanoid")`; the port replaced that with
	-- `FindFirstChildOfClass` and kept none of the wait.
	character:WaitForChild("Humanoid", HUMANOID_TIMEOUT)

	local humanoid = findHumanoid(character)
	if humanoid == nil then
		-- Released before raising: the re-entry guard above is keyed on this
		-- entry, so leaving it set would make every later pass a silent no-op and
		-- nothing could ever repair this character.
		characterByPlayer[player] = nil
	end

	assert(humanoid ~= nil, `character {character.Name} has no Humanoid`)

	humanoid.Died:Connect(function(): ()
		character.Parent = Workspace
	end)

	for _, descendant in character:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end

		descendant.CollisionGroup = CustomEnums.CollisionGroup.Player
	end
end

--- Idempotent: bind-and-check calls this twice for a player who joins during
--- `Start`.
local function onPlayerAdded(player: Player): ()
	if trackedPlayers[player] then
		return
	end

	trackedPlayers[player] = true

	player.CharacterAdded:Connect(function(character: Model): ()
		onCharacterAdded(player, character)
	end)

	-- Bind-and-check one level down: signal-package raised `_OnCharacterAdded`
	-- for a character that already existed when it started.
	local character = player.Character
	if character ~= nil then
		onCharacterAdded(player, character)
	end

	refreshGameFavorited(player)
end

--- sync-package clears its own per-connection state on removal, but the favorites
--- map is this module's: without this a long-lived server leaks an entry per
--- departed player.
local function onPlayerRemoving(player: Player): ()
	trackedPlayers[player] = nil
	characterByPlayer[player] = nil

	if gameFavoritedByUserId()[player.UserId] == nil then
		return
	end

	local nextGameFavoritedByUserId = table.clone(gameFavoritedByUserId())
	nextGameFavoritedByUserId[player.UserId] = nil
	gameFavoritedByUserId(nextGameFavoritedByUserId)
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

-- Every method below is a package boundary, reachable from consumer code that
-- has no typechecker, so the `Player` annotation is a claim rather than a
-- guarantee. Truthiness comes first so a missing argument reports the contract
-- instead of dying on `attempt to index nil with 'IsA'`. A
-- `typeof(player) == "Instance"` clause would be tighter, but nothing outside a
-- live server can mint a Player, so that clause could never hold under test —
-- quest-package's `assertIsPlayer` names the same trade.

--- Resolves the player's character only once its Humanoid exists, as the
--- intent's own contract states. A dead character is not one: the promise waits
--- for the respawn instead, and rejects if none arrives.
function PlayerService.GetCharacter(_self: PlayerService, player: Player): Promise.TypedPromise<Model>
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	local character = player.Character
	if character ~= nil then
		local humanoid = findHumanoid(character)
		if humanoid ~= nil and humanoid.Health > 0 then
			return Promise.resolve(character)
		end
	end

	return promiseNextCharacter(player)
		:andThen(function(nextCharacter: Model): Model
			nextCharacter:WaitForChild("Humanoid")
			return nextCharacter
		end)
		:timeout(CHARACTER_TIMEOUT, "Failed to get player's character. timeout exceeded!")
end

function PlayerService.GetMembershipType(_self: PlayerService, player: Player): Enum.MembershipType
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	return player.MembershipType
end

--- Rejects when the favorites endpoint does not answer. Knit's version swallowed
--- the rejection and resolved with nil, which is not in the declared type and
--- errored inside every caller that iterated the result.
function PlayerService.GetFavorites(_self: PlayerService, player: Player): Promise.TypedPromise<{ FavoriteGame }>
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	return Promise.try(function(): { FavoriteGame }
		local body = HttpService:GetAsync(string.format(FAVORITES_PROXY_URL, player.UserId))
		local decoded: { data: { FavoriteGame }? } = HttpService:JSONDecode(body)
		local favorites = decoded.data
		assert(favorites ~= nil, "roproxy favorites response carried no data array")
		return favorites
	end)
end

function PlayerService.HasPremium(self: PlayerService, player: Player): boolean
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	return self:GetMembershipType(player) == Enum.MembershipType.Premium
end

--- Answers about the character the player has NOW. Knit routed this through
--- GetCharacter, which refuses to hand back a dead character, so it could only
--- ever answer false.
function PlayerService.IsDead(_self: PlayerService, player: Player): Promise.TypedPromise<boolean>
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	local character = player.Character
	local humanoid = if character ~= nil then findHumanoid(character) else nil
	return Promise.resolve(humanoid == nil or humanoid.Health <= 0)
end

function PlayerService.MoveCharacterToPart(
	self: PlayerService,
	player: Player,
	target: BasePart
): Promise.TypedPromise<Model>
	assert(player and player:IsA("Player"), "Player must be a Player instance")
	assert(target:IsA("BasePart"), "Target must be a BasePart")

	return self:MoveCharacterToCFrame(player, target:GetPivot())
end

function PlayerService.MoveCharacterToCFrame(
	self: PlayerService,
	player: Player,
	target: CFrame
): Promise.TypedPromise<Model>
	assert(player and player:IsA("Player"), "Player must be a Player instance")
	assert(typeof(target) == "CFrame", "Target must be a CFrame")

	-- Inside the chain, not before it: RequestStreamAroundAsync yields, and this
	-- method owes the caller a promise rather than a stalled thread.
	return Promise.try(function(): ()
		requestStreamAround(player, target.Position)
	end)
		:andThen(function(): Promise.TypedPromise<Model>
			return self:GetCharacter(player)
		end)
		:andThen(function(character: Model): Promise.TypedPromise<Model>
			return moveCharacter(character, target)
		end)
end

--- Kills the character the player has NOW, and has nothing to do when there is
--- none. Knit routed this through GetCharacter, which refuses to hand back a
--- dead character and waits on the respawn instead — so "kill an already dead or
--- not-yet-spawned player" armed a kill of that player's NEXT life, up to
--- CHARACTER_TIMEOUT later. IsDead was ported off the same routing for the same
--- reason.
---
--- `Health = 0` rather than `TakeDamage(MaxHealth)`: a ForceField absorbs damage
--- whole, so spawn protection let Knit's version report a kill it never made.
function PlayerService.Kill(_self: PlayerService, player: Player): Promise.TypedPromise<()>
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	local character = player.Character
	local humanoid = if character ~= nil then findHumanoid(character) else nil
	if humanoid ~= nil and humanoid.Health > 0 then
		humanoid.Health = 0
	end

	return Promise.resolve()
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function PlayerService.Start(): ()
	-- Both of these run before anything binds: `onCharacterAdded` reparents into
	-- `charactersFolder`, and with it still nil that assignment would deparent
	-- the character out of the world. Knit took the ordering from its own
	-- init-before-start phases; a merged Start has to state it.
	registerCollisionGroups()
	charactersFolder = findOrCreateCharactersFolder()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	remotes.player.moveCharacterToCFrame:onRequest(function(player: Player, target: CFrame): Promise.TypedPromise<Model>
		return PlayerService:MoveCharacterToCFrame(player, target)
	end)
	remotes.player.requestStreamAround:connect(requestStreamAround)
end

return PlayerService
