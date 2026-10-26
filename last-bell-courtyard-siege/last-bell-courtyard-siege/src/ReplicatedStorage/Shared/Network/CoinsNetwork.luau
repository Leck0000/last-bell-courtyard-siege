--!strict
-- One network-contract module per feature: EVERY remote the feature uses is
-- declared here with `t` validators, and both realms `require` this same
-- module. Server fires/connects and client fires/connects through
-- `remotes.coins.<name>` — never through raw Instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remo = require(ReplicatedStorage.Packages.Remo)
local t = require(ReplicatedStorage.Packages.t)

type Remotes = Remo.Remotes<{
	coins: {
		-- Server → one client: per-player filtered push of that player's total.
		coinsChanged: Remo.ServerToClient<number>,
		-- Client → server intent; the server validates before mutating state.
		collectCoin: Remo.ClientToServer<string>,
		-- Client request → server response. Client `:request()` returns a
		-- Promise<number>; server answers via `:onRequest(handler)`.
		getCoins: Remo.ServerAsync<(), (number)>,
	},
}>

local remotes: Remotes = Remo.createRemotes({
	coins = Remo.namespace({
		coinsChanged = Remo.remote(t.number),
		collectCoin = Remo.remote(t.string),
		getCoins = Remo.remote().returns(t.number),
	}),
})

return remotes
