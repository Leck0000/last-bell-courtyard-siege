--!strict
--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Packages //--
local Remo = require(ReplicatedStorage.Packages.Remo)
local t = require(ReplicatedStorage.Packages.t)

--- All three are request-response, not fire-and-forget. The pre-migration client proxy was built
--- out of RemoteFunctions, so each of these already handed the caller a promise, and
--- the caller's rollback is driven by the SERVER's rejection: InventoryController
--- hands the same promise to `DataController.predict`, which only drops its optimistic
--- write once the request SETTLES. Without a return channel the optimistic write could
--- never be undone. `.returns()` with no validator pins the empty reply -- the caller
--- is entitled to a promise that settles, and to no value.
---
--- The pre-migration service validated nothing here (its client methods forwarded varargs
--- raw), so the `t` validators are new: every argument crosses from an untrusted client.
type Remotes = Remo.Remotes<{
	inventory: {
		equipItem: Remo.ServerAsync<(string, string), ()>,
		purchaseItem: Remo.ServerAsync<(string, string), ()>,
		unequipItem: Remo.ServerAsync<(string, string), ()>,
	},
}>

local remotes: Remotes = Remo.createRemotes({
	inventory = Remo.namespace({
		equipItem = Remo.remote(t.string, t.string).returns(),
		purchaseItem = Remo.remote(t.string, t.string).returns(),
		unequipItem = Remo.remote(t.string, t.string).returns(),
	}),
})

return remotes
