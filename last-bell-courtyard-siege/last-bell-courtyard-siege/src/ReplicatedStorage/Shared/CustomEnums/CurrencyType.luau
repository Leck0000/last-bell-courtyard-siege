--!strict
export type CurrencyType = "Coins"
export type CurrencyData = { DisplayName: string, Image: string }
local CurrencyType = { Default = "Coins" :: CurrencyType, Coins = "Coins" :: CurrencyType }
CurrencyType.__METADATA = { Coins = { DisplayName = "Coins", Image = "" } }
return table.freeze(CurrencyType)
