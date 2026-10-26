--// Roblox Services //--
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

--// Services & Controllers //--
local PlayerService = require(ServerScriptService.Server.Systems.PlayerService)

--// Dependencies //--
local Interaction = require(ReplicatedStorage.Shared.Modules.Interaction)

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Promise = require(ReplicatedStorage.Packages.Promise)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local SEAT_WELD_NAME = "SeatWeld"
local SEAT_OFFSET = CFrame.new(0, 1.5, 0)

--// Fusion References //--
local peek = Fusion.peek

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

local SeatComponent = {
	Tag = "SeatComponent",
	Ancestors = { Workspace },
	Extensions = { BaseComponent },
}

type SeatComponentData = {
	Occupant: Fusion.Computed<Player?>,
}
type SeatComponentDataInt = {
	_interaction: Interaction.Interaction,
}

export type SeatComponent =
	typeof(setmetatable({} :: SeatComponentData, SeatComponent))
	& typeof(Component.getExtensionsType(BaseComponent))
	& Component.ComponentObject
type SeatComponentInt = SeatComponent & SeatComponentDataInt

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function getSeat(self: SeatComponentInt): Seat
	local seat = self.Instance
	assert(seat:IsA("Seat"), `SeatComponent: {seat:GetFullName()} is not a Seat.`)
	return seat
end

--[[
	Hand-rolled rather than `Promise.fromEvent`: that helper declares a structural
	Signal an RBXScriptSignal cannot satisfy, because its `Connect` hands back an
	RBXScriptConnection in an invariant position.
]]
local function promiseOnLeftSeat(player: Player): Promise.TypedPromise<()>
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		return Promise.reject(`SeatComponent: {player.Name} has no humanoid to watch for leaving the seat.`)
	end

	return Promise.new(function(resolve, _reject, onCancel): ()
		local stateChanged: RBXScriptConnection
		local destroying: RBXScriptConnection

		local function disconnect(): ()
			stateChanged:Disconnect()
			destroying:Disconnect()
		end

		stateChanged = humanoid.StateChanged:Connect(function(_, newState: Enum.HumanoidStateType): ()
			if newState == Enum.HumanoidStateType.Seated then
				return
			end

			disconnect()
			resolve()
		end)

		destroying = humanoid.Destroying:Connect(function(): ()
			disconnect()
			resolve()
		end)

		onCancel(disconnect)
	end)
end

--[[
	`Seat:Sit` welds with a `Weld` named SeatWeld — a JointInstance, not a
	WeldConstraint. Matching on the class as well as the name found nothing, so
	the seat kept its weld and the occupant was never released.
]]
local function removeSeatWeld(seat: Seat): ()
	local seatWeld = seat:FindFirstChild(SEAT_WELD_NAME)
	if seatWeld then
		seatWeld:Destroy()
	end
end

local function sit(player: Player, seat: Seat): Promise.TypedPromise<()>
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if
		not character
		or not character.PrimaryPart
		or not humanoid
		or humanoid:GetState() == Enum.HumanoidStateType.Dead
	then
		return Promise.reject("Character is dead or not loaded")
	end

	removeSeatWeld(seat)

	return PlayerService:MoveCharacterToCFrame(player, seat.CFrame * SEAT_OFFSET):andThen(function(): ()
		seat:Sit(humanoid)
	end)
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function SeatComponent.OnActivated(self: SeatComponentInt, interactor: Player): ()
	local character = interactor.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		return
	end

	if humanoid:GetState() == Enum.HumanoidStateType.Seated then
		return
	end

	sit(interactor, getSeat(self)):catch(warn):expect()
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function SeatComponent.Construct(self: SeatComponentInt): ()
	local seat = getSeat(self)
	seat.Disabled = true

	local OccupantHumanoid = self:Value(seat.Occupant)
	self:AddTask(seat:GetPropertyChangedSignal("Occupant"):Connect(function(): ()
		OccupantHumanoid:set(seat.Occupant)
	end))

	self.Occupant = self:Computed(function(use: Fusion.Use): Player?
		local occupantHumanoid = use(OccupantHumanoid)
		if not occupantHumanoid then
			return nil
		end

		return Players:GetPlayerFromCharacter(occupantHumanoid.Parent)
	end)
end

function SeatComponent.Start(self: SeatComponentInt): ()
	local seat = getSeat(self)

	self._interaction = Interaction.new({
		OnActivated = function(interactor: Player): ()
			self:OnActivated(interactor)
		end,
		InstantActivation = false,
		Parent = seat,
	})

	self:Observer(self.Occupant):onBind(function(): ()
		local occupant = peek(self.Occupant)
		if occupant then
			self._interaction:SetEnabled(false)

			-- Caught: an occupant who has already respawned has no humanoid left to
			-- watch, and an unhandled rejection is noise nobody can act on.
			promiseOnLeftSeat(occupant)
				:andThen(function(): ()
					removeSeatWeld(seat)
				end)
				:catch(warn)
		else
			self._interaction:SetEnabled(true)
		end
	end)
end

Component.new(SeatComponent)
return SeatComponent :: SeatComponent
