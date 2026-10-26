--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Packages //--
local Remo = require(ReplicatedStorage.Packages.Remo)
local t = require(ReplicatedStorage.Packages.t)

type Remotes = Remo.Remotes<{
	mob: {
		validateDamage: Remo.ServerAsync<(Instance, number, Instance), (boolean)>,
	},
}>

-- The mob travels as the first argument because one remote serves every mob; the
-- server resolves it back with `MobServerComponent:FromInstance`.
-- Request-response, not fire-and-forget — MobClientComponent.AttemptDamage undoes
-- its optimistic health delta when the reply lands, and a caller that catches the
-- rejection (tower-package) rolls its own cooldown back with it.
local remotes: Remotes = Remo.createRemotes({
	mob = Remo.namespace({
		validateDamage = Remo.remote(t.Instance, t.number, t.Instance).returns(t.boolean),
	}),
})

return remotes
