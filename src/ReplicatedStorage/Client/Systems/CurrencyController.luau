--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Services & Controllers //--
local DataController = require(ReplicatedStorage.Client.Systems.DataController)

--// Dependencies //--
local CurrencyKey = require(ReplicatedStorage.Shared.Utils.CurrencyKey)
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)

--// Packages //--
local Charm = require(ReplicatedStorage.Packages.Charm)
local Promise = require(ReplicatedStorage.Packages.Promise)

local subscribe = Charm.subscribe

type Balances = { [string]: number }

-- The annotation is what pins the value type; Luau has no call-site type
-- arguments. Nil until the player's profile has replicated.
local getBalances: Charm.Getter<Balances?> = DataController.get(CurrencyKey.Root)

--------------------------------------------------------------------------------
--// Controller //--
--------------------------------------------------------------------------------

-- `balances` is a field, not a method, so UI can `Charm.listen` it directly. It
-- replaces the Fusion `use` the read methods used to accept.
local CurrencyController = {
	balances = getBalances,
}

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
    Checks whether or not the player has enough currency of passed type.
    @param amount: number Amount of currency to be checked.
    @param currencyType: CustomEnums.CurrencyType The currency type.
    @return Promise<boolean, number> Returns true and the remaining balance if the player has enough currency, otherwise false and 0.
]]
function CurrencyController.HasEnoughCurrency(
	self: CurrencyController,
	amount: number,
	currencyType: CustomEnums.CurrencyType?
): Promise.TypedPromise<boolean, number>
	assert(amount, "Currency amount must be provided.")
	assert(amount >= 0, "Currency amount can not be a negative number, got " .. tostring(amount))

	return self:GetBalance(currencyType):andThen(function(currencyBalance: number)
		if amount > currencyBalance then
			return false, 0
		end
		return true, currencyBalance - amount
	end)
end

--[[
    Gets the player's current balance of passed currency type.
    @param currencyType: CustomEnums.CurrencyType The currency type.
    @return Promise<number>
]]
function CurrencyController.GetBalance(
	_self: CurrencyController,
	currencyType: CustomEnums.CurrencyType?
): Promise.TypedPromise<number>
	local getBalance: Charm.Getter<number?> = DataController.get(CurrencyKey.forType(currencyType))

	local currencyBalance = getBalance()
	if currencyBalance ~= nil then
		return Promise.resolve(currencyBalance)
	end

	return Promise.new(function(resolve, _reject, onCancel): ()
		local unsubscribe: () -> ()
		unsubscribe = subscribe(getBalance, function(nextBalance: number?): ()
			-- Charm fires only when the value CHANGES, and this subscribe is bound
			-- only while the balance reads nil, so the first firing always carries
			-- one. An assert rather than a guard: a nil here means Charm's
			-- semantics moved, and the caller is owed a number either way.
			local balance = assert(nextBalance, "Currency balance replicated as nil")

			unsubscribe()
			resolve(balance)
		end)

		-- Without this the Charm effect outlives a cancelled promise
		onCancel(unsubscribe)
	end)
end

export type CurrencyController = typeof(CurrencyController)
return CurrencyController
