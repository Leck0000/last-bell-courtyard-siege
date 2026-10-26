--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Dependencies //--
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)

--// Constants //--
local CURRENCY_TYPE = CustomEnums.CurrencyType

-- `__METADATA` is keyed by the consumer's own CurrencyType union, but a
-- caller-supplied type arrives as untyped data (an item's PurchaseInfo, a
-- dev-product config), so the lookup that rejects an undeclared one is rebuilt
-- over a plain string key. Presence here IS declaration: DisplayName is a
-- required field of every CurrencyData.
local DISPLAY_NAMES: { [string]: string } = {}
for currencyType, currencyData in CURRENCY_TYPE.__METADATA do
	DISPLAY_NAMES[currencyType] = currencyData.DisplayName
end

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local CurrencyKey = {}

--- The profile key every currency type is nested under.
CurrencyKey.Root = "Currency"

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
    Resolves a caller-supplied currency type, defaulting to the type keyed "Default".
    @param currencyType: CustomEnums.CurrencyType? The currency type.
    @return string
]]
function CurrencyKey.resolveType(currencyType: CustomEnums.CurrencyType?): string
	local resolvedType: string = currencyType or CURRENCY_TYPE.Default
	assert(DISPLAY_NAMES[resolvedType], "Invalid currency type provided.")
	return resolvedType
end

--[[
    Gets a formatted string representing the currency type key in the player's profile data.
    @param currencyType: CustomEnums.CurrencyType? The currency type.
    @return string
]]
function CurrencyKey.forType(currencyType: CustomEnums.CurrencyType?): string
	return CurrencyKey.Root .. "/" .. CurrencyKey.resolveType(currencyType)
end

--[[
    Gets the human-readable name the consumer declared for a currency type.
    @param currencyType: CustomEnums.CurrencyType? The currency type.
    @return string
]]
function CurrencyKey.displayName(currencyType: CustomEnums.CurrencyType?): string
	return DISPLAY_NAMES[CurrencyKey.resolveType(currencyType)]
end

export type CurrencyKey = typeof(CurrencyKey)
return CurrencyKey
