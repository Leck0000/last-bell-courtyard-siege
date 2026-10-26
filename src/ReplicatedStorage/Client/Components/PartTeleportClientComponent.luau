--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

--// Dependencies //--
local TransitionScreen = require(ReplicatedStorage.Client.UserInterface["TransitionScreen.fusion"])
local HitboxExtension = require(ReplicatedStorage.Shared.Components.HitboxExtension)

--// Packages //--
local RemoteComponent = require(ReplicatedStorage.Packages.RemoteComponent)
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)

--// References //--
local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

--- Luau types a mixed array literal from its first element, so an unannotated
--- `{ BaseComponent, RemoteComponent, HitboxExtension }` checks the other two against
--- BaseComponent. Naming the element type checks each entry on its own terms.
type ExtensionEntry = typeof(BaseComponent) | typeof(RemoteComponent) | typeof(HitboxExtension)
local extensions: { ExtensionEntry } = { BaseComponent, RemoteComponent, HitboxExtension }

local PartTeleportClientComponent = {
	Tag = "PartTeleportComponent",
	Ancestors = { Workspace },
	Extensions = extensions,
}
PartTeleportClientComponent.RemoteNamespace = PartTeleportClientComponent.Tag .. "RemoteComponent"
PartTeleportClientComponent.UsePromisesForMethods = true

type PartTeleportClientComponentData = {}
type PartTeleportClientComponentDataInt = {}

export type PartTeleportClientComponent =
	typeof(setmetatable({} :: PartTeleportClientComponentData, PartTeleportClientComponent))
	& typeof(Component.getExtensionsType(BaseComponent, RemoteComponent, HitboxExtension))
	& Component.ComponentObject
type PartTeleportClientComponentInt = PartTeleportClientComponent & PartTeleportClientComponentDataInt

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function PartTeleportClientComponent.OnTouched(self: PartTeleportClientComponentInt, interactor: Player): ()
	if interactor ~= LocalPlayer then
		return
	end
	TransitionScreen({
		TransitionCallback = function()
			self.Server:TeleportPlayer(interactor):catch(warn):expect()
		end,
	})
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

Component.new(PartTeleportClientComponent)
return PartTeleportClientComponent :: PartTeleportClientComponent
