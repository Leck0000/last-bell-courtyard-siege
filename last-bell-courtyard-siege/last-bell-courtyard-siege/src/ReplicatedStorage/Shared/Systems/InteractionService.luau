--// Roblox Services //--
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--// Packages //--
local Symbol = require(ReplicatedStorage.Packages.Symbol)

--// Constants //--
local IS_SERVER = RunService:IsServer()

--// Types //--
export type ModalRequestHandle = typeof(Symbol())

--// References //--
local modalRequests: { [ModalRequestHandle]: boolean } = {}
local promptsEnabledBeforeFirstRequest = true

--------------------------------------------------------------------------------
--// Service //--
--------------------------------------------------------------------------------

local InteractionService = {}
type InteractionService = typeof(InteractionService)

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function InteractionService.AddModalRequest(self: InteractionService): ModalRequestHandle
	if IS_SERVER then
		error("InteractionService:AddModalRequest should not be called on the server.")
	end

	if next(modalRequests) == nil then
		promptsEnabledBeforeFirstRequest = ProximityPromptService.Enabled
	end

	local newHandle = Symbol("InteractionModalRequest")
	modalRequests[newHandle] = true
	ProximityPromptService.Enabled = false
	return newHandle
end

function InteractionService.RemoveModalRequest(self: InteractionService, handle: ModalRequestHandle): ()
	if IS_SERVER then
		error("InteractionService:RemoveModalRequest should not be called on the server.")
	end

	-- Releasing an unknown handle is a no-op: MinigameClient:193 never clears
	-- `self._interactionToken`, so it re-submits a handle it already released.
	if not modalRequests[handle] then
		return
	end

	modalRequests[handle] = nil
	ProximityPromptService.Enabled = if next(modalRequests) == nil then promptsEnabledBeforeFirstRequest else false
end

return InteractionService
