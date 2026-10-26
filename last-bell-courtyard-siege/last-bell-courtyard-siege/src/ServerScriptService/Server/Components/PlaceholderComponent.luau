--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--// Packages //--
local Component = require(ReplicatedStorage.Packages.Component)

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

local PlaceholderComponent = {
	Tag = "PlaceholderComponent",
	Ancestors = { Workspace },
	Extensions = {},
}

type PlaceholderComponentData = {}
type PlaceholderComponentDataInt = {}

export type PlaceholderComponent =
	typeof(setmetatable({} :: PlaceholderComponentData, PlaceholderComponent))
	& typeof(Component.getExtensionsType())
	& Component.ComponentObject
type PlaceholderComponentInt = PlaceholderComponent & PlaceholderComponentDataInt

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function PlaceholderComponent.Start(self: PlaceholderComponentInt): ()
	self.Instance:Destroy()
end

Component.new(PlaceholderComponent)
return PlaceholderComponent :: PlaceholderComponent
