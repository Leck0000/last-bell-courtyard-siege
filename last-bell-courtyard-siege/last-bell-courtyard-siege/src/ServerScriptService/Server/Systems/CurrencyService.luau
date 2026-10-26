--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--// Services & Controllers //--
local DataService = require(ServerScriptService.Server.Systems.DataService)

--// Dependencies //--
local CurrencyKey = require(ReplicatedStorage.Shared.Utils.CurrencyKey)
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)
local PlayerDataTypes = require(ReplicatedStorage.Shared.Types.PlayerDataTypes)

--// Packages //--
local Promise = require(ReplicatedStorage.Packages.Promise)

--// Constants //--
local CURRENCY_METADATA = CustomEnums.CurrencyType.__METADATA

--------------------------------------------------------------------------------
--// Registration //--
--------------------------------------------------------------------------------

-- Module scope, not `.Start()`: the bootstrapper requires every module before it
-- starts any, and `DataService.Start` seals the template.
do
	local defaults: PlayerDataTypes.PlayerData = {}
	for currencyType in CURRENCY_METADATA do
		defaults[currencyType] = 0
	end
	DataService.registerTemplate(CurrencyKey.Root, defaults)
end

--------------------------------------------------------------------------------
--// Service //--
--------------------------------------------------------------------------------

local CurrencyService = {}

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
    Checks whether or not the player has enough currency of passed type.
    @param player: Player Player whose balance will be checked.
    @param amount: number Amount of currency to be checked.
    @param currencyType: CustomEnums.CurrencyType The currency type.
    @return Promise<boolean, number> Returns true and the remaining balance if the player has enough currency, otherwise false and 0.
]]
function CurrencyService.HasEnoughCurrency(
	self: CurrencyService,
	player: Player,
	amount: number,
	currencyType: CustomEnums.CurrencyType?
): Promise.TypedPromise<boolean, number>
	assert(player:IsA("Player"), "Player must be a valid Player instance.")
	assert(amount, "Currency amount must be provided.")
	assert(amount >= 0, "Currency amount can not be a negative number, got " .. tostring(amount))

	return self:GetBalance(player, currencyType):andThen(function(currencyBalance: number)
		if amount > currencyBalance then
			return false, 0
		end
		return true, currencyBalance - amount
	end)
end

--[[
    Gets the player's current balance of passed currency type.
    @param player: Player Player whose data will be checked.
    @param currencyType: CustomEnums.CurrencyType The currency type.
    @return Promise<number>
]]
function CurrencyService.GetBalance(
	_self: CurrencyService,
	player: Player,
	currencyType: CustomEnums.CurrencyType?
): Promise.TypedPromise<number>
	assert(player:IsA("Player"), "Player must be a valid Player instance.")
	return DataService:Get(player, CurrencyKey.forType(currencyType))
end

--[[
    Takes away the player currency of passed type.
    @param player: Player Player whose balance will be mutated.
    @param amount: number Amount of currency to be taken.
    @param currencyType: CustomEnums.CurrencyType The currency type.
    @return Promise<number> Resolves the balance left after the charge.
]]
function CurrencyService.ChargeCurrency(
	self: CurrencyService,
	player: Player,
	amount: number,
	currencyType: CustomEnums.CurrencyType?
): Promise.TypedPromise<number>
	assert(player:IsA("Player"), "Player must be a valid Player instance.")
	assert(amount, "Currency amount must be provided.")
	assert(amount >= 0, "Currency amount can not be a negative number, got " .. tostring(amount))

	return self:HasEnoughCurrency(player, amount, currencyType)
		:andThen(function(hasEnough: boolean, remainingBalance: number)
			if not hasEnough then
				local displayName = CurrencyKey.displayName(currencyType)
				return Promise.reject("Player does not have enough " .. displayName)
			end

			return DataService:Set(player, CurrencyKey.forType(currencyType), remainingBalance)
		end)
end

--[[
    Gives the player currency of passed type.
    @param player: Player Player whose balance will be mutated.
    @param amount: number Amount of currency to be given.
    @param currencyType: CustomEnums.CurrencyType The currency type.
    @return Promise<number> Resolves the balance after the grant.
]]
function CurrencyService.GiveCurrency(
	_self: CurrencyService,
	player: Player,
	amount: number,
	currencyType: CustomEnums.CurrencyType?
): Promise.TypedPromise<number>
	assert(player:IsA("Player"), "Player must be a valid Player instance.")
	assert(amount, "Currency amount must be provided.")
	assert(amount >= 0, "Currency amount can not be a negative number, got " .. tostring(amount))

	return DataService:Update(player, CurrencyKey.forType(currencyType), function(currencyBalance: number): number
		return currencyBalance + amount
	end)
end

export type CurrencyService = typeof(CurrencyService)
return CurrencyService
