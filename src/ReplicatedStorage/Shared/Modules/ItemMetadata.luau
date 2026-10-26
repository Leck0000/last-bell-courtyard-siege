--!strict
--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Dependencies //--
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)

--// Types //--
export type ItemCategoryData = CustomEnums.ItemCategoryData
export type ItemData = CustomEnums.ItemData
export type PurchaseInfo = CustomEnums.PurchaseInfo

--- A category's ownership map: one entry per owned item id, holding one UUID per copy.
export type OwnedItems = { [string]: { string } }

--- A category's equipped slots, in slot order.
export type EquippedItemIds = { string }

-- `__METADATA` is keyed by the consumer's own ItemCategory union, but a category
-- arrives from the wire and from untyped game code as a plain string, so the lookup
-- that rejects an undeclared one is rebuilt over a plain string key.
-- selene: allow(manual_table_clone)
-- Not `table.clone`: the point of the rebuild is the KEY type. A clone keeps the
-- ItemCategory singleton indexer, and Luau treats a table indexer as invariant, so the
-- cloned table cannot be held as `{ [string]: ItemCategoryData }`.
local CATEGORY_DATA: { [string]: ItemCategoryData } = {}
for itemCategory, itemCategoryData in CustomEnums.ItemCategory.__METADATA do
	CATEGORY_DATA[itemCategory] = itemCategoryData
end
table.freeze(CATEGORY_DATA)

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local ItemMetadata = {}

--- Every category the consumer declared, keyed by category name.
ItemMetadata.Categories = CATEGORY_DATA :: { [string]: ItemCategoryData }

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
	Whether the consumer declared this item category.
	@param itemCategory: string The item category.
	@return boolean
]]
function ItemMetadata.isValidCategory(itemCategory: string): boolean
	return CATEGORY_DATA[itemCategory] ~= nil
end

--[[
	The consumer's configuration for a declared category.
	@param itemCategory: string The item category.
	@return ItemCategoryData? nil when the category was never declared.
]]
function ItemMetadata.getCategoryData(itemCategory: string): ItemCategoryData?
	return CATEGORY_DATA[itemCategory]
end

--[[
	The consumer's configuration for one item within a declared category.
	@param itemCategory: string A category that has already passed isValidCategory.
	@param itemId: string The item id.
	@return ItemData? nil when the category declares no such item.
]]
function ItemMetadata.getItemData(itemCategory: string, itemId: string): ItemData?
	-- An assert, not a guard: every caller validates the category first, so an
	-- undeclared one here is a bug in this package rather than bad input.
	local categoryData = assert(CATEGORY_DATA[itemCategory], `unregistered item category: {itemCategory}`)

	local itemData = categoryData.GetItemData(itemId)
	if itemData == nil then
		warn("Invalid item id", itemId)
		return nil
	end

	return itemData
end

--[[
	Whether a declared category declares this item id.
	@param itemCategory: string A category that has already passed isValidCategory.
	@param itemId: string The item id.
	@return boolean
]]
function ItemMetadata.isValidItem(itemCategory: string, itemId: string): boolean
	return ItemMetadata.getItemData(itemCategory, itemId) ~= nil
end

--[[
	How many slots in `equippedItemIds` hold this item id.
	@param equippedItemIds: EquippedItemIds The category's equipped list.
	@param itemId: string The item id.
	@return number
]]
function ItemMetadata.countEquipped(equippedItemIds: EquippedItemIds, itemId: string): number
	local count = 0
	for _, equippedItemId in equippedItemIds do
		if equippedItemId == itemId then
			count += 1
		end
	end
	return count
end

export type ItemMetadata = typeof(ItemMetadata)
return ItemMetadata
