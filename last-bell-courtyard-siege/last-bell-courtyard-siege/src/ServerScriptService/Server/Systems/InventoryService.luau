--!strict
--// Roblox Services //--
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--// Services & Controllers //--
local CurrencyService = require(ServerScriptService.Server.Systems.CurrencyService)
local DataService = require(ServerScriptService.Server.Systems.DataService)

--// Dependencies //--
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)
local DataPath = require(ReplicatedStorage.Shared.Utils.DataPath)
local InventoryKey = require(ReplicatedStorage.Shared.Utils.InventoryKey)
local ItemMetadata = require(ReplicatedStorage.Shared.Modules.ItemMetadata)
local PlayerAtoms = require(ReplicatedStorage.Shared.Modules.PlayerAtoms)
local PlayerDataTypes = require(ReplicatedStorage.Shared.Types.PlayerDataTypes)
local remotes = require(ReplicatedStorage.Shared.Network.InventoryNetwork)

--// Packages //--
local Charm = require(ReplicatedStorage.Packages.Charm)
local Promise = require(ReplicatedStorage.Packages.Promise)
local UUIDGenerator = require(ReplicatedStorage.Packages.UUIDGenerator)

--// Types //--
type EquippedItemIds = ItemMetadata.EquippedItemIds
type OwnedItems = ItemMetadata.OwnedItems
type PlayerData = PlayerDataTypes.PlayerData

--// References //--
-- Frozen so the fallback keeps a stable identity across recomputes; a fresh `{}` literal
-- would change identity on every unrelated write and wake subscribers for no reason.
local EMPTY_EQUIPPED: EquippedItemIds = table.freeze({})

--------------------------------------------------------------------------------
--// Registration //--
--------------------------------------------------------------------------------

-- Module scope, not `.Start()`: the bootstrapper requires every module before it
-- starts any, and `DataService.Start` seals the template.
do
	local defaults: PlayerDataTypes.PlayerData = {}
	for itemCategory in ItemMetadata.Categories do
		defaults[itemCategory] = { Equipped = {}, Owned = {} }
	end
	DataService.registerTemplate(InventoryKey.Root, defaults)
end

--------------------------------------------------------------------------------
--// Service //--
--------------------------------------------------------------------------------

local InventoryService = {}

--- One entry per tracked player, holding the teardown for that player's attribute
--- mirrors. Doubles as the idempotence guard for `onPlayerAdded`.
local mirrorCleanups: { [Player]: { () -> () } } = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function readEquipped(player: Player, path: { string }): EquippedItemIds
	local playerData = PlayerAtoms.getPlayerData(player.UserId) :: PlayerData
	local value: unknown = DataPath.getAt(playerData, path)
	-- nil until the player's profile has replicated into the atom.
	return if type(value) == "table" then value :: EquippedItemIds else EMPTY_EQUIPPED
end

-- Runs inside a Charm effect: it must not yield.
local function writeEquippedAttributes(
	player: Player,
	itemCategory: string,
	maxEquipped: number,
	equippedItemIds: EquippedItemIds
): ()
	for slotIndex = 1, maxEquipped do
		player:SetAttribute(InventoryKey.attribute(itemCategory, slotIndex), equippedItemIds[slotIndex])
	end
end

-- Idempotent: bind-and-check calls this twice for a player who joins during Start,
-- and a second bind would leave a duplicate attribute writer per category behind.
local function onPlayerAdded(player: Player): ()
	if mirrorCleanups[player] then
		return
	end

	local cleanups: { () -> () } = {}
	mirrorCleanups[player] = cleanups

	for itemCategory, itemCategoryData in ItemMetadata.Categories do
		local path = DataPath.split(InventoryKey.equipped(itemCategory))
		local maxEquipped = itemCategoryData.MaxEquipped

		local getEquipped = Charm.computed(function(): EquippedItemIds
			return readEquipped(player, path)
		end)

		-- `listen`, not `subscribe`: a player whose profile has already replicated by
		-- the time this runs is owed their attributes now, not on the next equip.
		table.insert(
			cleanups,
			Charm.listen(getEquipped, function(equippedItemIds: EquippedItemIds): ()
				writeEquippedAttributes(player, itemCategory, maxEquipped, equippedItemIds)
			end)
		)
	end
end

-- Not a former hook: the guard table is this module's, and without this a long-lived
-- server leaks an entry and a live Charm effect per departed player.
local function onPlayerRemoving(player: Player): ()
	local cleanups = mirrorCleanups[player]
	if cleanups == nil then
		return
	end

	mirrorCleanups[player] = nil
	for _, cleanup in cleanups do
		cleanup()
	end
end

-- Unwrapped deliberately: the reply carries nothing, only whether the operation
-- landed. `expect` turns the rejection into the one the client's request reads.
local function onEquipItem(player: Player, itemCategory: string, itemId: string): ()
	InventoryService:EquipItem(player, itemCategory, itemId):expect()
end

local function onUnequipItem(player: Player, itemCategory: string, itemId: string): ()
	InventoryService:UnequipItem(player, itemCategory, itemId):expect()
end

local function onPurchaseItem(player: Player, itemCategory: string, itemId: string): ()
	InventoryService:PurchaseItem(player, itemCategory, itemId):expect()
end

--------------------------------------------------------------------------------
--// Lifecycle //--
--------------------------------------------------------------------------------

function InventoryService.Start(): ()
	-- Bind-and-check: connect then process existing players.
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	remotes.inventory.equipItem:onRequest(onEquipItem)
	remotes.inventory.unequipItem:onRequest(onUnequipItem)
	remotes.inventory.purchaseItem:onRequest(onPurchaseItem)
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
	Whether the player owns at least one copy of the item.
	@param player: Player The owner.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<boolean>
]]
function InventoryService.HasItem(
	self: InventoryService,
	player: Player,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<boolean>
	assert(player:IsA("Player"), "Player must be a Player instance")

	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	if not ItemMetadata.isValidItem(itemCategory, itemId) then
		return Promise.reject("Invalid item id")
	end

	return self:GetOwned(player, itemCategory):andThen(function(ownedItems: OwnedItems): boolean
		local ownedCopies = ownedItems[itemId]
		return ownedCopies ~= nil and #ownedCopies > 0
	end)
end

--[[
	The player's ownership map for a category, `{ [itemId] = { uuid, ... } }`.
	@param player: Player The owner.
	@param itemCategory: string The item category.
	@return Promise<{ [string]: { string } }>
]]
function InventoryService.GetOwned(
	_self: InventoryService,
	player: Player,
	itemCategory: string
): Promise.TypedPromise<OwnedItems>
	assert(player:IsA("Player"), "Player must be a Player instance")

	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	return DataService:Get(player, InventoryKey.owned(itemCategory))
end

--[[
	The player's equipped slots for a category, in slot order.
	@param player: Player The owner.
	@param itemCategory: string The item category.
	@return Promise<{ string }>
]]
function InventoryService.GetEquipped(
	_self: InventoryService,
	player: Player,
	itemCategory: string
): Promise.TypedPromise<EquippedItemIds>
	assert(player:IsA("Player"), "Player must be a Player instance")

	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	return DataService:Get(player, InventoryKey.equipped(itemCategory))
end

--[[
	Whether the item occupies at least one of the category's equipped slots.
	@param player: Player The owner.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<boolean>
]]
function InventoryService.IsItemEquipped(
	self: InventoryService,
	player: Player,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<boolean>
	assert(player:IsA("Player"), "Player must be a Player instance")

	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	if not ItemMetadata.isValidItem(itemCategory, itemId) then
		return Promise.reject("Invalid item id")
	end

	return self:GetEquipped(player, itemCategory):andThen(function(equippedItemIds: EquippedItemIds): boolean
		return table.find(equippedItemIds, itemId) ~= nil
	end)
end

--[[
	Moves an owned item into an equipped slot, evicting the oldest slot when the
	category is full.
	@param player: Player The owner.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<()>
]]
function InventoryService.EquipItem(
	self: InventoryService,
	player: Player,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<()>
	assert(player:IsA("Player"), "Player must be a Player instance")

	local itemCategoryData = ItemMetadata.getCategoryData(itemCategory)
	if itemCategoryData == nil then
		return Promise.reject("Invalid item category")
	end

	if not ItemMetadata.isValidItem(itemCategory, itemId) then
		return Promise.reject("Invalid item id")
	end

	return self:GetOwned(player, itemCategory):andThen(function(ownedItems: OwnedItems)
		local ownedCopies = ownedItems[itemId]
		local ownedQuantity = if ownedCopies then #ownedCopies else 0
		if ownedQuantity == 0 then
			return Promise.reject("Player doesnt own item", itemId)
		end

		return self:GetEquipped(player, itemCategory):andThen(function(equippedItemIds: EquippedItemIds)
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

			-- Cloned, not mutated: DataService hands back the live replicated leaf, and
			-- both Charm and charm-sync compare by reference. Mutating in place and
			-- writing the same table back leaves every reader unnotified.
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

			return DataService:Set(player, InventoryKey.equipped(itemCategory), nextEquipped):andThenReturn()
		end)
	end)
end

--[[
	Frees the slot holding the item. The item id is deliberately NOT validated: an item
	the consumer has since dropped from its metadata must still be removable, or a
	player who equipped it before the change is stuck with it forever.
	@param player: Player The owner.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<()>
]]
function InventoryService.UnequipItem(
	self: InventoryService,
	player: Player,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<()>
	assert(player:IsA("Player"), "Player must be a Player instance")

	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	return self:GetEquipped(player, itemCategory):andThen(function(equippedItemIds: EquippedItemIds)
		local itemIndex = table.find(equippedItemIds, itemId)
		if itemIndex == nil then
			return Promise.reject("Item is not equipped", itemId)
		end

		local nextEquipped = table.clone(equippedItemIds)
		table.remove(nextEquipped, itemIndex)

		return DataService:Set(player, InventoryKey.equipped(itemCategory), nextEquipped):andThenReturn()
	end)
end

--[[
	Adds one copy of the item to the player's ownership map under a generated UUID.
	@param player: Player The recipient.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<()>
]]
function InventoryService.GiveItem(
	self: InventoryService,
	player: Player,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<()>
	assert(player:IsA("Player"), "Player must be a Player instance")

	return self:GiveItemWithUUID(player, itemCategory, itemId, UUIDGenerator.Generate())
end

--[[
	Adds one copy of the item under a caller-supplied UUID, so a transfer can carry the
	copy's identity from one player to another.
	@param player: Player The recipient.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@param uuid: string The UUID identifying this copy.
	@return Promise<()>
]]
function InventoryService.GiveItemWithUUID(
	self: InventoryService,
	player: Player,
	itemCategory: string,
	itemId: string,
	uuid: string
): Promise.TypedPromise<()>
	assert(player:IsA("Player"), "Player must be a Player instance")

	local itemCategoryData = ItemMetadata.getCategoryData(itemCategory)
	if itemCategoryData == nil then
		return Promise.reject("Invalid item category")
	end

	if not ItemMetadata.isValidItem(itemCategory, itemId) then
		return Promise.reject("Invalid item id")
	end

	return self:GetOwned(player, itemCategory):andThen(function(ownedItems: OwnedItems)
		local ownedCopies = ownedItems[itemId]
		if itemCategoryData.IsOwnedUnique and ownedCopies ~= nil and #ownedCopies > 0 then
			return Promise.reject("Player already owns item", itemId)
		end

		local nextCopies = if ownedCopies then table.clone(ownedCopies) else {}
		table.insert(nextCopies, uuid)

		local nextOwned = table.clone(ownedItems)
		nextOwned[itemId] = nextCopies

		return DataService:Set(player, InventoryKey.owned(itemCategory), nextOwned):andThenReturn()
	end)
end

--[[
	Charges the item's PurchaseInfo through CurrencyService, then gives the item. A
	failed grant refunds the charge: a caller is entitled not to pay for an item they
	did not receive.
	@param player: Player The buyer.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<()>
]]
function InventoryService.PurchaseItem(
	self: InventoryService,
	player: Player,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<()>
	assert(player:IsA("Player"), "Player must be a Player instance")

	local itemCategoryData = ItemMetadata.getCategoryData(itemCategory)
	if itemCategoryData == nil then
		return Promise.reject("Invalid item category")
	end

	local itemData = ItemMetadata.getItemData(itemCategory, itemId)
	if itemData == nil then
		return Promise.reject("Invalid item id")
	end

	local purchaseInfo = itemData.PurchaseInfo
	local override = itemData._ServerOnlyPurchaseInfoOverride
	if override then
		purchaseInfo = override(player)
	end

	-- The client guards this and the server did not, so an item with no PurchaseInfo
	-- raised "attempt to index nil" straight out of the RemoteFunction. The two realms
	-- share the message so a caller sees one contract.
	if purchaseInfo == nil then
		return Promise.reject("Item is has no purchase info")
	end

	if purchaseInfo.Amount == nil or purchaseInfo.CurrencyType == nil then
		return Promise.reject("Item is not purchasable")
	end

	-- Re-bound through an annotation: Luau drops a nil-refinement at the boundary of
	-- the closures below, and both currency calls take a non-optional pair.
	local amount: number = purchaseInfo.Amount
	local currencyType: CustomEnums.CurrencyType = purchaseInfo.CurrencyType

	local ownershipChecked: Promise.TypedPromise<()> = if itemCategoryData.IsOwnedUnique
		then self:HasItem(player, itemCategory, itemId):andThen(function(hasItem: boolean)
			if hasItem then
				return Promise.reject("Player already owns item", itemId)
			end
			return nil
		end)
		else Promise.resolve()

	return ownershipChecked
		:andThen(function()
			return CurrencyService:ChargeCurrency(player, amount, currencyType)
		end)
		:andThen(function()
			return self:GiveItem(player, itemCategory, itemId):catch(function(giveError: unknown)
				-- ChargeCurrency has already written the debit to the profile.
				local function reportGiveError(): Promise.Promise
					return Promise.reject(giveError)
				end

				-- Handed to BOTH arms, so the caller hears the same answer whether or
				-- not the refund itself landed. What they asked is why the PURCHASE
				-- failed; the refund's own error would replace that reason with one
				-- about an operation they never requested.
				return CurrencyService:GiveCurrency(player, amount, currencyType)
					:andThen(reportGiveError, reportGiveError)
			end)
		end)
		:andThenReturn()
end

--[[
	Removes the newest owned copy and resolves its UUID, unequipping one slot when the
	loadout would otherwise claim more copies than the player still owns.
	@param player: Player The owner.
	@param itemCategory: string The item category.
	@param itemId: string The item id.
	@return Promise<string> The removed copy's UUID.
]]
function InventoryService.DeleteItem(
	self: InventoryService,
	player: Player,
	itemCategory: string,
	itemId: string
): Promise.TypedPromise<string>
	assert(player:IsA("Player"), "Player must be a Player instance")

	if not ItemMetadata.isValidCategory(itemCategory) then
		return Promise.reject("Invalid item category")
	end

	if not ItemMetadata.isValidItem(itemCategory, itemId) then
		return Promise.reject("Invalid item id")
	end

	return self:GetOwned(player, itemCategory):andThen(function(ownedItems: OwnedItems)
		local ownedCopies = ownedItems[itemId]
		if ownedCopies == nil or #ownedCopies == 0 then
			return Promise.reject("Player does not own item", itemId)
		end

		local nextCopies = table.clone(ownedCopies)
		local uuid = assert(table.remove(nextCopies, #nextCopies), "owned copy list emptied between read and write")

		local nextOwned = table.clone(ownedItems)
		nextOwned[itemId] = nextCopies

		-- Chained, not fired and forgotten: the caller is told the copy is gone, and
		-- trade-package hands the resolved UUID straight to the recipient, so the
		-- sender's loadout has to be consistent by then.
		--
		-- The loadout is freed FIRST and the shortened map written second, because both
		-- writes can fail and only this order leaves a survivable state behind. A
		-- loadout that claims fewer copies than the player owns is merely a lost slot;
		-- a copy destroyed out of a loadout that still lists it is a player wearing an
		-- item they do not own, and trade-package's chain would have sent it to nobody.
		return self:GetEquipped(player, itemCategory)
			:andThen(function(equippedItemIds: EquippedItemIds)
				-- Strictly greater: a loadout that still fits the remaining copies is
				-- already consistent, and unequipping there would silently cost the
				-- player a slot.
				if ItemMetadata.countEquipped(equippedItemIds, itemId) > #nextCopies then
					return self:UnequipItem(player, itemCategory, itemId)
				end
				return nil
			end)
			:andThen(function()
				return DataService:Set(player, InventoryKey.owned(itemCategory), nextOwned)
			end)
			:andThen(function(): string
				return uuid
			end)
	end)
end

export type InventoryService = typeof(InventoryService)
return InventoryService
