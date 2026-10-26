--!strict
-- The synced-atom pattern: server-owned Charm state keyed by userId. Every
-- update is IMMUTABLE (`table.clone` + write + swap) so `Charm.subscribe`
-- observers fire on each change — the server's per-player sync subscribes to
-- `getCoins(player.UserId)` and pushes the new value over CoinsNetwork.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Packages.Charm)

export type CoinsMap = { [number]: number }

local seed: CoinsMap = {}
local coinsAtom = Charm.atom(seed)

local function getCoins(userId: number): number
	return coinsAtom()[userId] or 0
end

local function setCoins(userId: number, amount: number): ()
	local updated = table.clone(coinsAtom())
	updated[userId] = amount
	coinsAtom(updated)
end

local function removePlayer(userId: number): ()
	local updated = table.clone(coinsAtom())
	updated[userId] = nil
	coinsAtom(updated)
end

return {
	getCoins = getCoins,
	setCoins = setCoins,
	removePlayer = removePlayer,
}
