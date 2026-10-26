--!strict
local CurrencyType = require(script.Parent.CurrencyType)
export type PurchaseInfo = { Amount: number?, CurrencyType: CurrencyType.CurrencyType? }
export type ItemData = { DisplayName: string, PurchaseInfo: PurchaseInfo?, _ServerOnlyPurchaseInfoOverride: ((Player) -> PurchaseInfo?)? }
export type ItemCategory = "Supply"
export type ItemCategoryData = { DisplayName: string, GetItemData: (string) -> ItemData?, IsOwnedUnique: boolean, IsEquippedUnique: boolean, MaxEquipped: number }
local ItemCategory = { Supply = "Supply" :: ItemCategory }
-- No session loot is registered as a purchasable/persisted collectible.
ItemCategory.__METADATA = { Supply = { DisplayName = "Session supplies", GetItemData = function(_id: string): ItemData? return nil end, IsOwnedUnique = true, IsEquippedUnique = true, MaxEquipped = 0 } }
return table.freeze(ItemCategory)
