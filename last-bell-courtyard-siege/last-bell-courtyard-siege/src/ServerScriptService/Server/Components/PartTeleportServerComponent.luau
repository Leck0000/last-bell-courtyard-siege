--// Roblox Services //--
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

--// Services & Controllers //--
local PlayerService = require(ServerScriptService.Server.Systems.PlayerService)

--// Packages //--
local RemoteComponent = require(ReplicatedStorage.Packages.RemoteComponent)
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Promise = require(ReplicatedStorage.Packages.Promise)

--// Constants //--
--- Names what each half has to BE: both are narrowed, so "absent" is not the only
--- way to fail this, and the message used to say it was.
local TARGET_MISSING_ERR =
	"PartTeleportComponent must have a TargetAttachment Attachment, or a numeric TargetPlaceId attribute"

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

--- Luau types a mixed array literal from its first element, so an unannotated
--- `{ BaseComponent, RemoteComponent }` checks RemoteComponent against BaseComponent.
--- Naming the element type checks each entry on its own terms.
type ExtensionEntry = typeof(BaseComponent) | typeof(RemoteComponent)
local extensions: { ExtensionEntry } = { BaseComponent, RemoteComponent }

local PartTeleportServerComponent = {
	Tag = "PartTeleportComponent",
	Ancestors = { Workspace },
	Extensions = extensions,
}
PartTeleportServerComponent.RemoteNamespace = PartTeleportServerComponent.Tag .. "RemoteComponent"

type PartTeleportServerComponentData = {
	TargetPlaceId: number?,
	TargetAttachment: Attachment?,
}
type PartTeleportServerComponentDataInt = {}

export type PartTeleportServerComponent =
	typeof(setmetatable({} :: PartTeleportServerComponentData, PartTeleportServerComponent))
	& typeof(Component.getExtensionsType(BaseComponent, RemoteComponent))
	& Component.ComponentObject
type PartTeleportServerComponentInt = PartTeleportServerComponent & PartTeleportServerComponentDataInt

--- RemoteComponent hangs the component itself off the Client table it wraps.
type PartTeleportServerComponentClient = {
	Server: PartTeleportServerComponentInt,
}

--------------------------------------------------------------------------------
--// Client Methods //--
--------------------------------------------------------------------------------

local Client = {}
PartTeleportServerComponent.Client = Client

function Client.TeleportPlayer(self: PartTeleportServerComponentClient, player: Player): Instance
	return self.Server:TeleportPlayer(player):expect()
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function PartTeleportServerComponent.TeleportPlayer(
	self: PartTeleportServerComponentInt,
	player: Player
): Promise.TypedPromise<Instance>
	local targetPlaceId = self.TargetPlaceId
	if targetPlaceId then
		-- Settles as soon as the teleport is away: there is nothing later to wait
		-- for. The old code parked on a bare `coroutine.yield()` that nothing ever
		-- resumed, so a teleport that started but did not complete left the caller
		-- holding its screen wipe open for good.
		return Promise.try(function(): Instance
			TeleportService:TeleportAsync(targetPlaceId, { player })
			return player
		end)
	end

	local target = self.TargetAttachment
	assert(target, TARGET_MISSING_ERR)

	-- Wrapped rather than handed straight back: `MoveCharacterToCFrame` is declared
	-- `TypedPromise<Model>`, and `TypedPromise` is invariant in its value, so the
	-- Model it resolves with cannot be returned as the declared Instance.
	return Promise.new(function(resolve: (Instance) -> (), reject: (...any) -> ()): ()
		PlayerService:MoveCharacterToCFrame(player, target.WorldCFrame):andThen(resolve, reject)
	end)
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function PartTeleportServerComponent.Construct(self: PartTeleportServerComponentInt): ()
	local targetPlaceId = self.Instance:GetAttribute("TargetPlaceId")
	self.TargetPlaceId = if typeof(targetPlaceId) == "number" then targetPlaceId else nil

	-- Narrowed here, not at the teleport: `FindFirstChild` matches on name alone, and
	-- a Part called TargetAttachment used to pass this assert and then fail on
	-- `WorldCFrame` inside the promise, as a rejection naming a Roblox property.
	--
	-- Written only when there is an attachment to write. The field is left alone
	-- otherwise, which reads back the same nil: `getExtensionsType` leaves seven of
	-- its nine method slots unbound, the `any` they become carries `TeleportPlayer`'s
	-- `Attachment` refinement into this field's write type, and an explicit `nil`
	-- assignment no longer satisfies it.
	local target = self.Instance:FindFirstChild("TargetAttachment", true)
	if target and target:IsA("Attachment") then
		self.TargetAttachment = target
	end

	assert(self.TargetAttachment or self.TargetPlaceId, TARGET_MISSING_ERR)
end

Component.new(PartTeleportServerComponent)
return PartTeleportServerComponent :: PartTeleportServerComponent
