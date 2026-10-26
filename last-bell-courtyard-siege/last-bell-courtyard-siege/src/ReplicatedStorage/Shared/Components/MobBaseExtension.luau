--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Dependencies //--
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local MOB_METADATA = CustomEnums.MobType.__METADATA
local MOB_STATUS = CustomEnums.MobStatus

--// Fusion References //--
local peek = Fusion.peek

--// Types //--
type SearchResults = {
	{
		Component: ComponentObject,
		Distance: number,
	}
}

type MobBaseExtensionData = {
	-- Built by MobClientComponent.Construct, so nil on the server.
	ClientHealth: Fusion.Computed<number>?,
	InternalHealth: Fusion.Value<number>,
	InternalStatus: Fusion.Value<CustomEnums.MobStatus>,
	MobData: CustomEnums.MobData,
}

-- Spelled out rather than derived from `MobBaseExtension.Methods`: the methods
-- take `self: ComponentObject`, so deriving the object type from them is a cycle
-- Luau resolves by dropping every method off the object.
type MobBaseExtensionMethods = {
	GetInternalHealth: (self: ComponentObject, use: Fusion.Use?) -> number,
	GetInternalStatus: (self: ComponentObject, use: Fusion.Use?) -> CustomEnums.MobStatus,
	GetMobData: (self: ComponentObject) -> CustomEnums.MobData,
	GetMobsWithinRange: (self: ComponentObject, towerPosition: Vector3, range: number) -> SearchResults,
	GetMobType: (self: ComponentObject) -> CustomEnums.MobType,
	IsHostile: (self: ComponentObject) -> boolean,
	IsRespawnEnabled: (self: ComponentObject) -> boolean,
	SetInternalHealth: (self: ComponentObject, value: number) -> (),
	SetInternalStatus: (self: ComponentObject, value: CustomEnums.MobStatus) -> (),
}

type ComponentObject =
	Component.ComponentObject
	& typeof(Component.getExtensionsType(BaseComponent))
	& MobBaseExtensionData
	& MobBaseExtensionMethods

--------------------------------------------------------------------------------
--// Extension Methods //--
--------------------------------------------------------------------------------

local function GetMobsWithinRange(self: ComponentObject, towerPosition: Vector3, range: number): SearchResults
	local searchResults: SearchResults = {}
	for _, componentObject in self:GetAll() do
		local mobComponent = componentObject :: ComponentObject
		local clientHealth = mobComponent.ClientHealth
		if
			mobComponent:GetInternalStatus() == MOB_STATUS.Destroyed
			or (clientHealth ~= nil and peek(clientHealth) <= 0)
		then
			continue
		end

		if mobComponent:IsHostile() then
			continue
		end

		local mobPosition = (mobComponent.Instance :: PVInstance):GetPivot().Position
		local distanceVector = towerPosition - mobPosition
		local distance = (distanceVector * Vector3.new(1, 0, 1)).Magnitude
		if distance <= range then
			table.insert(searchResults, { Component = mobComponent, Distance = distance })
		end
	end

	return searchResults
end

--[[
	Sets "self.InternalStatus".
	@param value: MobStatus
]]
local function SetInternalStatus(self: ComponentObject, value: CustomEnums.MobStatus): ()
	self.InternalStatus:set(value)
end

--[[
	Sets "self.InternalHealth".
	@param value: number
]]
local function SetInternalHealth(self: ComponentObject, value: number): ()
	self.InternalHealth:set(value)
end

--[[ :GetInternalStatus()
	Returns the current "self.InternalStatus" value.

	@param use: Use? -- Pass a Fusion Use to make the caller depend on the value.
	@return CustomEnums.MobStatus
]]
local function GetInternalStatus(self: ComponentObject, use: Fusion.Use?): CustomEnums.MobStatus
	return (use or peek)(self.InternalStatus) :: CustomEnums.MobStatus
end

--[[ :GetInternalHealth()
	Returns the current "self.InternalHealth" value.

	@param use: Use? -- Pass a Fusion Use to make the caller depend on the value.
	@return number
]]
local function GetInternalHealth(self: ComponentObject, use: Fusion.Use?): number
	return (use or peek)(self.InternalHealth) :: number
end

--[[ :IsRespawnEnabled()
	Returns "RespawnEnabled" attribute value or false.

    @return boolean
]]
local function IsRespawnEnabled(self: ComponentObject): boolean
	return (self.Instance:GetAttribute("RespawnEnabled") or false) :: boolean
end

--[[ :IsHostile()
	Returns "IsHostile" attribute value or false.

    @return boolean
]]
local function IsHostile(self: ComponentObject): boolean
	return (self.Instance:GetAttribute("IsHostile") or false) :: boolean
end

--[[
	Returns "MobType" [Attribute] from the associated Instance.

	@return MobType
]]
local function GetMobType(self: ComponentObject): CustomEnums.MobType
	local mobType = self.Instance:GetAttribute("MobType")
	assert(mobType ~= nil, `{self.Instance:GetFullName()} is tagged as a mob but carries no MobType attribute`)
	return mobType :: CustomEnums.MobType
end

--[[ :GetMobData()
	Returns "self.MobData" value.

	@return MobData
]]
local function GetMobData(self: ComponentObject): CustomEnums.MobData
	return self.MobData
end

--------------------------------------------------------------------------------
--// Extension Declaration //--
--------------------------------------------------------------------------------

local MobBaseExtension = {}

local Methods = {
	GetMobsWithinRange = GetMobsWithinRange,
	SetInternalStatus = SetInternalStatus,
	SetInternalHealth = SetInternalHealth,
	GetInternalStatus = GetInternalStatus,
	GetInternalHealth = GetInternalHealth,
	IsRespawnEnabled = IsRespawnEnabled,
	IsHostile = IsHostile,
	GetMobType = GetMobType,
	GetMobData = GetMobData,
}

MobBaseExtension.Methods = Methods :: MobBaseExtensionData & typeof(Methods)

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function MobBaseExtension.Constructing(self: ComponentObject): ()
	local mobType: CustomEnums.MobType = GetMobType(self)
	local mobData = MOB_METADATA[mobType]
	assert(mobData, `No mob metadata found for mob type "{mobType}"`)

	self.InternalHealth = self:Value(mobData.Health)
	self.InternalStatus = self:Value(MOB_STATUS.Intact)
	self.MobData = mobData
end

return MobBaseExtension
