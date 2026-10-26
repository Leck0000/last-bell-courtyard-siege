--!strict
--// Roblox Services //--

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local InventoryKey = {}

--- The profile key every item category is nested under.
InventoryKey.Root = "Inventory"

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
	The data key holding a category's ownership map, `{ [itemId] = { uuid, ... } }`.
	@param itemCategory: string The item category.
	@return string
]]
function InventoryKey.owned(itemCategory: string): string
	return `{InventoryKey.Root}/{itemCategory}/Owned`
end

--[[
	The data key holding a category's equipped list, `{ itemId, ... }`.
	@param itemCategory: string The item category.
	@return string
]]
function InventoryKey.equipped(itemCategory: string): string
	return `{InventoryKey.Root}/{itemCategory}/Equipped`
end

--[[
	The player attribute mirroring one equipped slot. This is the package's published
	output: a consumer's AvatarEffectsBaseComponent reads the attribute by this name.
	@param itemCategory: string The item category.
	@param slotIndex: number The 1-based equipped slot.
	@return string
]]
function InventoryKey.attribute(itemCategory: string, slotIndex: number): string
	return `Equipped{itemCategory}{slotIndex}`
end

export type InventoryKey = typeof(InventoryKey)
return InventoryKey
