--// Services //--
local RunService = game:GetService("RunService")

local CustomEnums = {}

local CollisionGroup = require(script.Parent.CollisionGroup)
export type CollisionGroup = CollisionGroup.CollisionGroup
CustomEnums.CollisionGroup = CollisionGroup

local CurrencyType = require(script.Parent.CurrencyType)
export type CurrencyType = CurrencyType.CurrencyType
export type CurrencyData = CurrencyType.CurrencyData
CustomEnums.CurrencyType = CurrencyType
local ItemCategory = require(script.Parent.ItemCategory)
export type ItemCategory = ItemCategory.ItemCategory
export type ItemCategoryData = ItemCategory.ItemCategoryData
export type ItemData = ItemCategory.ItemData
export type PurchaseInfo = ItemCategory.PurchaseInfo
CustomEnums.ItemCategory = ItemCategory

local LightingProfileName = require(script.Parent.LightingProfileName)
export type LightingProfileName = LightingProfileName.LightingProfileName
CustomEnums.LightingProfileName = LightingProfileName

local MusicType = require(script.Parent.MusicType)
export type MusicType = MusicType.MusicType
export type MusicData = MusicType.MusicData
CustomEnums.MusicType = MusicType

local MobStatus = require(script.Parent.MobStatus)
export type MobStatus = MobStatus.MobStatus
CustomEnums.MobStatus = MobStatus
local MobType = require(script.Parent.MobType)
export type MobType = MobType.MobType
export type MobData = MobType.MobData
CustomEnums.MobType = MobType

if RunService:IsRunning() then
	table.freeze(CustomEnums)
end
return CustomEnums
