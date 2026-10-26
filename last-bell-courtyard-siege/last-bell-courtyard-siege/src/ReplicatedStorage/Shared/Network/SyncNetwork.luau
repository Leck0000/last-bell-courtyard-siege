--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharmSync = require(ReplicatedStorage.Packages.CharmSync)
local Remo = require(ReplicatedStorage.Packages.Remo)
local isSyncPayloadList = require(script.Parent.SyncPayloadValidator)

export type SyncPayloadList = { CharmSync.SyncPayload }

type Remotes = Remo.Remotes<{
	sync: {
		patches: Remo.ServerToClient<SyncPayloadList>,
		ready: Remo.ClientToServer<>,
	},
}>

local remotes: Remotes = Remo.createRemotes({
	sync = Remo.namespace({
		patches = Remo.remote(isSyncPayloadList),
		ready = Remo.remote(),
	}),
})

return remotes
