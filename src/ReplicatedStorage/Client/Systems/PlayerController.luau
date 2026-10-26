--// Roblox Services //--
local RobloxExperienceNotificationService = game:GetService("ExperienceNotificationService")
local AvatarEditorService = game:GetService("AvatarEditorService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Services & Controllers //--
local SyncController = require(ReplicatedStorage.Client.Systems.SyncController)

--// Packages //--
local Charm = require(ReplicatedStorage.Packages.Charm)
local Promise = require(ReplicatedStorage.Packages.Promise)
local remotes = require(ReplicatedStorage.Shared.Network.PlayerNetwork)

--// Constants //--
local PLACE_ID = game.PlaceId

--- How long GetCharacter waits on a respawn before it rejects. Knit's client
--- half had no bound at all, so a player who never respawned left the promise
--- pending with nothing to catch.
local CHARACTER_TIMEOUT = 60

--// References //--
local LocalPlayer = Players.LocalPlayer

--- `nil` until the server answers, which is what tells "not favorited" apart
--- from "the favorites endpoint has not replied". Knit's property defaulted to
--- `true` and reported every unanswered player as having favorited the game.
local sync = SyncController.namespace("player")
local gameFavoritedAtom = Charm.atom(nil :: boolean?)
local getIsGameFavorited = sync:receivePlayer("gameFavorited", gameFavoritedAtom)

--------------------------------------------------------------------------------
--// Controller //--
--------------------------------------------------------------------------------

--- The getter is a field so other controllers can `listen` to it directly, the
--- way `IsGameFavorited:Observe` was consumed under Knit.
local PlayerController = {
	isGameFavorited = getIsGameFavorited,
}
export type PlayerController = typeof(PlayerController)

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

local function findHumanoid(character: Model): Humanoid?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil
	end

	assert(humanoid:IsA("Humanoid"), "FindFirstChildOfClass returned something other than a Humanoid")
	return humanoid
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

-- The truthiness check in front of every `IsA` is the one the server half
-- carries: a missing argument has to report the contract rather than die on
-- `attempt to index nil with 'IsA'`, and `typeof(player) == "Instance"` cannot
-- be exercised by a suite that has no way to mint a Player.

--- Resolves when the prompt closes and rejects when it cannot be shown.
---
--- It does NOT report whether the player opted in: the Roblox API does not say,
--- and Knit guessed by comparing the mouse position against half the viewport
--- when `OptInPromptClosed` fired — an answer that is wrong for touch, gamepad,
--- keyboard dismissal, and any cursor that moved after the click.
function PlayerController.PromptNotificationOptIn(_self: PlayerController): Promise.TypedPromise<()>
	return Promise.new(function(resolve, reject, onCancel): ()
		if not RobloxExperienceNotificationService:CanPromptOptInAsync() then
			reject("Cannot prompt notification opt-in.")
			return
		end

		local closedConnection: RBXScriptConnection
		closedConnection = RobloxExperienceNotificationService.OptInPromptClosed:Connect(function(): ()
			closedConnection:Disconnect()
			resolve()
		end)

		-- Without this a cancelled promise leaves the connection live for the
		-- rest of the session, since the prompt may never be closed.
		onCancel(function(): ()
			closedConnection:Disconnect()
		end)

		RobloxExperienceNotificationService:PromptOptIn()
	end)
end

function PlayerController.PromptSetFavorite(_self: PlayerController): ()
	AvatarEditorService:PromptSetFavorite(PLACE_ID, Enum.AvatarItemType.Asset, true)
end

function PlayerController.GetLocalPlayerCharacter(self: PlayerController): Promise.TypedPromise<Model>
	return self:GetCharacter(LocalPlayer)
end

--- The same contract the server half honours: a character with a living
--- Humanoid, or a rejection once the wait runs out.
function PlayerController.GetCharacter(_self: PlayerController, player: Player): Promise.TypedPromise<Model>
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

--- Answers about the player it was asked about. Knit read
--- `LocalPlayer.MembershipType` whatever player was passed, so asking about
--- anyone else silently returned the local player's membership.
function PlayerController.GetMembershipType(_self: PlayerController, player: Player): Enum.MembershipType
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	return player.MembershipType
end

function PlayerController.HasPremium(self: PlayerController, player: Player): boolean
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	return self:GetMembershipType(player) == Enum.MembershipType.Premium
end

--- Answers about the character the player has NOW, like the server half.
function PlayerController.IsDead(_self: PlayerController, player: Player): Promise.TypedPromise<boolean>
	assert(player and player:IsA("Player"), "Player must be a Player instance")

	local character = player.Character
	local humanoid = if character ~= nil then findHumanoid(character) else nil
	return Promise.resolve(humanoid == nil or humanoid.Health <= 0)
end

function PlayerController.AnchorLocalPlayerCharacter(self: PlayerController, state: boolean): Promise.TypedPromise<()>
	assert(typeof(state) == "boolean", "State must be a boolean")

	return self:GetLocalPlayerCharacter():andThen(function(character: Model): ()
		for _, descendant in character:GetDescendants() do
			if not descendant:IsA("BasePart") then
				continue
			end

			descendant.Anchored = state
		end
	end)
end

function PlayerController.MoveCharacterToPart(self: PlayerController, target: BasePart): Promise.TypedPromise<Model>
	assert(target:IsA("BasePart"), "Target must be a BasePart")

	return self:MoveCharacterToCFrame(target:GetPivot())
end

function PlayerController.MoveCharacterToCFrame(_self: PlayerController, target: CFrame): Promise.TypedPromise<Model>
	assert(typeof(target) == "CFrame", "Target must be a CFrame")

	return remotes.player.moveCharacterToCFrame:request(target)
end

--- Kills the character the local player has NOW, like the server half: routing
--- through GetCharacter waits out a dead or absent character and then kills the
--- life that replaced it, which is the opposite of a no-op.
---
--- `Health = 0` rather than `TakeDamage(MaxHealth)`, which a ForceField absorbs
--- whole — spawn protection let Knit's version report a kill it never made.
function PlayerController.Kill(_self: PlayerController): Promise.TypedPromise<()>
	local character = LocalPlayer.Character
	local humanoid = if character ~= nil then findHumanoid(character) else nil
	if humanoid ~= nil and humanoid.Health > 0 then
		humanoid.Health = 0
	end

	return Promise.resolve()
end

--- Fire-and-forget, where Knit made the client wait on a RemoteFunction to learn
--- nil. The server does the streaming request; nothing comes back.
function PlayerController.RequestStreamAroundAsync(_self: PlayerController, target: Vector3): ()
	assert(typeof(target) == "Vector3", "Target must be a Vector3")

	remotes.player.requestStreamAround:fire(target)
end

return PlayerController
