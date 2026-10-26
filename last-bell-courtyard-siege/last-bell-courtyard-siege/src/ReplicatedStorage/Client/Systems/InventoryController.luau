--!strict
--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Services & Controllers //--
local CurrencyController = require(ReplicatedStorage.Client.Systems.CurrencyController)
local DataController = require(ReplicatedStorage.Client.Systems.DataController)

--// Dependencies //--
local CurrencyKey = require(ReplicatedStorage.Shared.Utils.CurrencyKey)
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)
local InventoryKey = require(ReplicatedStorage.Shared.Utils.InventoryKey)
local ItemMetadata = require(ReplicatedStorage.Shared.Modules.ItemMetadata)
local remotes = require(ReplicatedStorage.Shared.Network.InventoryNetwork)

--// Packages //--
local Charm = require(ReplicatedStorage.Packages.Charm)
local Promise = require(ReplicatedStorage.Packages.Promise)

local subscribe = Charm.subscribe

--// Types //--
type EquippedItemIds = ItemMetadata.EquippedItemIds
type OwnedItems = ItemMetadata.OwnedItems

--------------------------------------------------------------------------------
--// Controller //--
--------------------------------------------------------------------------------

local InventoryController = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

--- Resolves once the key has replicated. It replaces the Fusion `use` the read
--- methods used to accept: `use` made a read re-run inside a Fusion Computed, and the
--- Charm getters below are what a caller reacts to now.
local function readReplicated<T>(getValue: Charm.Getter<T?>): Promise.TypedPromise<T>
	local value = getValue()
	if value ~= nil then
		return Promise.resolve(value)
	end

	return Promise.new(function(resolve, _reject, onCancel): ()
		local unsubscribe: () -> ()
		unsubscribe = subscribe(getValue, function(nextValue: T?): ()
			-- Charm fires only when the value CHANGES, and this subscribe is bound only
			-- while the key reads nil, so the first firing always carries a value. An
			-- assert rather than a guard: a nil here means the profile un-replicated.
			local replicated = assert(nextValue, "inventory value replicated as nil")

			unsubscribe()
			resolve(replicated)
		end)

		-- Without this the Charm effect outlives a cancelled promise.
		onCancel(unsubscribe)
	end)
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
	A reactive view of the player's ownership map for a category. Reads nil until the
	profile has replicated. Pass it to `Charm.listen` to drive UI.
	@param itemCategory: string The item category.
	@return Charm.Getter<{ [string]: { string } }?>
]]
function InventoryController.owned(_self: InventoryController, itemCategory: string): Charm.Getter<OwnedItems?>
	return DataController.get(InventoryKey.owned(itemCategory))
end

--[[
	A reactive view of the player's equipped slots for a category. Reads nil until the
	profile has replicated. Pass it to `Charm.listen` to drive UI.
	@param itemCategory: string The item category.
	@return Charm.Getter<{ string }?>
]]
function InventoryController.equipped(_self: InventoryController, itemCategory: string): Charm.Getter<EquippedItemIds?>
	return DataController.get(InventoryKey.equipped(itemCategory))
end

--[[
	Whether the local player owns at least one copy of the item.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<boolean>
]]
function InventoryController.HasItem(
	self: InventoryController,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<boolean>
	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	if not ItemMetadata.isValidItem(itemCategory, itemId) then
		return Promise.reject("Invalid item id")
	end

	return self:GetOwned(itemCategory):andThen(function(ownedItems: OwnedItems): boolean
		local ownedCopies = ownedItems[itemId]
		return ownedCopies ~= nil and #ownedCopies > 0
	end)
end

--[[
	The local player's ownership map for a category.
	@param itemCategory: string The item category.
	@return Promise<{ [string]: { string } }>
]]
function InventoryController.GetOwned(self: InventoryController, itemCategory: string): Promise.TypedPromise<OwnedItems>
	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	return readReplicated(self:owned(itemCategory))
end

--[[
	The local player's equipped slots for a category, in slot order.
	@param itemCategory: string The item category.
	@return Promise<{ string }>
]]
function InventoryController.GetEquipped(
	self: InventoryController,
	itemCategory: string
): Promise.TypedPromise<EquippedItemIds>
	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	return readReplicated(self:equipped(itemCategory))
end

--[[
	Whether the item occupies at least one of the category's equipped slots.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<boolean>
]]
function InventoryController.IsItemEquipped(
	self: InventoryController,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<boolean>
	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	if not ItemMetadata.isValidItem(itemCategory, itemId) then
		return Promise.reject("Invalid item id")
	end

	return self:GetEquipped(itemCategory):andThen(function(equippedItemIds: EquippedItemIds): boolean
		return table.find(equippedItemIds, itemId) ~= nil
	end)
end

--[[
	Equips the item, showing the new loadout immediately and reverting it if the server
	refuses. Rejects with `Failed to equip item {itemId}: {reason}`.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<()>
]]
function InventoryController.EquipItem(
	self: InventoryController,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<()>
	local itemCategoryData = ItemMetadata.getCategoryData(itemCategory)
	if itemCategoryData == nil then
		return Promise.reject("Invalid item category")
	end

	if not ItemMetadata.isValidItem(itemCategory, itemId) then
		return Promise.reject("Invalid item id")
	end

	return self:GetOwned(itemCategory):andThen(function(ownedItems: OwnedItems)
		local ownedCopies = ownedItems[itemId]
		local ownedQuantity = if ownedCopies then #ownedCopies else 0
		if ownedQuantity == 0 then
			return Promise.reject("Player doesnt own item", itemId)
		end

		return self:GetEquipped(itemCategory):andThen(function(equippedItemIds: EquippedItemIds)
			local howManyEquipped = ItemMetadata.countEquipped(equippedItemIds, itemId)
			if howManyEquipped > 0 then
				if itemCategoryData.IsEquippedUnique then
					return Promise.reject("Item is already equipped", itemId)
				end

				if howManyEquipped >= itemCategoryData.MaxEquipped then
					return Promise.reject("Player is already equipped with the maximum amount of this item", itemId)
				end

				if howManyEquipped >= ownedQuantity then
					return Promise.reject("Player has no more of this item to equip", itemId)
				end
			end

			local nextEquipped = table.clone(equippedItemIds)
			if #nextEquipped >= itemCategoryData.MaxEquipped then
				for slotIndex = 1, #nextEquipped do
					if nextEquipped[slotIndex] ~= itemId then
						table.remove(nextEquipped, slotIndex)
						break
					end
				end
			end
			table.insert(nextEquipped, itemId)

			-- One call does the optimistic write, the request and the rollback: the
			-- prediction is layered over the replicated profile until the request
			-- settles, whichever way it settles.
			return DataController.predict(InventoryKey.equipped(itemCategory), nextEquipped, function()
				return remotes.inventory.equipItem:request(itemCategory, itemId)
			end):catch(function(reason: unknown)
				return Promise.reject(`Failed to equip item {itemId}: {reason}`)
			end)
		end)
	end)
end

--[[
	Unequips the item, showing the new loadout immediately and reverting it if the
	server refuses. Rejects with `Failed to unequip item {itemId}: {reason}`.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<()>
]]
function InventoryController.UnequipItem(
	self: InventoryController,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<()>
	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	return self:GetEquipped(itemCategory):andThen(function(equippedItemIds: EquippedItemIds)
		local itemIndex = table.find(equippedItemIds, itemId)
		if itemIndex == nil then
			return Promise.reject("Item is not equipped", itemId)
		end

		local nextEquipped = table.clone(equippedItemIds)
		table.remove(nextEquipped, itemIndex)

		return DataController.predict(InventoryKey.equipped(itemCategory), nextEquipped, function()
			return remotes.inventory.unequipItem:request(itemCategory, itemId)
		end):catch(function(reason: unknown)
			return Promise.reject(`Failed to unequip item {itemId}: {reason}`)
		end)
	end)
end

--[[
	Buys the item, showing it as owned immediately and reverting that if the server
	refuses. The charge itself is the server's: only it may move a balance. Rejects with
	`Failed to purchase item {itemId}: {reason}`.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<()>
]]
function InventoryController.PurchaseItem(
	self: InventoryController,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<()>
	local itemCategoryData = ItemMetadata.getCategoryData(itemCategory)
	if itemCategoryData == nil then
		return Promise.reject("Invalid item category")
	end

	local itemData = ItemMetadata.getItemData(itemCategory, itemId)
	if itemData == nil then
		return Promise.reject("Invalid item id")
	end

	local purchaseInfo = itemData.PurchaseInfo
	if purchaseInfo == nil then
		return Promise.reject("Item is has no purchase info")
	end

	if purchaseInfo.Amount == nil or purchaseInfo.CurrencyType == nil then
		return Promise.reject("Item is not purchasable")
	end

	-- Re-bound through an annotation: Luau drops a nil-refinement at the boundary of
	-- the closure below, and the currency gate takes a non-optional pair.
	local amount: number = purchaseInfo.Amount
	local currencyType: CustomEnums.CurrencyType = purchaseInfo.CurrencyType

	return self:GetOwned(itemCategory):andThen(function(ownedItems: OwnedItems)
		local ownedCopies = ownedItems[itemId]
		if itemCategoryData.IsOwnedUnique and ownedCopies ~= nil and #ownedCopies > 0 then
			return Promise.reject("Player already owns item", itemId)
		end

		-- Gate only, no local debit: the server charges and replicates the balance, so
		-- charging here too would show the price taken twice.
		return CurrencyController:HasEnoughCurrency(amount, currencyType):andThen(function(hasEnough: boolean)
			if not hasEnough then
				return Promise.reject("Player does not have enough " .. CurrencyKey.displayName(currencyType))
			end

			-- The optimistic copy carries a placeholder UUID. It never has to agree with
			-- the server's: the prediction is discarded once the request settles, and
			-- the authoritative map replaces it.
			local nextCopies = if ownedCopies then table.clone(ownedCopies) else {}
			table.insert(nextCopies, "")

			local nextOwned = table.clone(ownedItems)
			nextOwned[itemId] = nextCopies

			return DataController.predict(InventoryKey.owned(itemCategory), nextOwned, function()
				return remotes.inventory.purchaseItem:request(itemCategory, itemId)
			end):catch(function(reason: unknown)
				return Promise.reject(`Failed to purchase item {itemId}: {reason}`)
			end)
		end)
	end)
end

export type InventoryController = typeof(InventoryController)
return InventoryController
