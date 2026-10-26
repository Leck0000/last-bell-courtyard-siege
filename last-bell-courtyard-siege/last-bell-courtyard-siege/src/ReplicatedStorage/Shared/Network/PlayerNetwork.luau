--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Packages //--
local Remo = require(ReplicatedStorage.Packages.Remo)
local t = require(ReplicatedStorage.Packages.t)

--- `moveCharacterToCFrame` is the one remote here that needs a return channel:
--- Knit's `Client:MoveCharacterToCFrame` handed the caller the placed character,
--- and `PlayerController.MoveCharacterToCFrame` is still annotated with it. The
--- server half settles either way, so the request cannot strand the caller.
---
--- `requestStreamAround` returned nothing under Knit and no caller ever read one,
--- so it drops the round trip it was paying for.
type Remotes = Remo.Remotes<{
	player: {
		moveCharacterToCFrame: Remo.ServerAsync<(CFrame), (Model)>,
		requestStreamAround: Remo.ClientToServer<Vector3>,
	},
}>

-- The validators are the server's only trust boundary: Remo checks incoming
-- arguments on the receiving realm, never on `:fire()`.
local remotes: Remotes = Remo.createRemotes({
	player = Remo.namespace({
		moveCharacterToCFrame = Remo.remote(t.CFrame).returns(t.instanceOf("Model")),
		requestStreamAround = Remo.remote(t.Vector3),
	}),
})

return remotes
