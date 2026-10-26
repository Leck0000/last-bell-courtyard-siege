--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Packages.Charm)
local CharmSync = require(ReplicatedStorage.Packages.CharmSync)
local SyncKey = require(ReplicatedStorage.Shared.Network.SyncKey)
local remotes = require(ReplicatedStorage.Shared.Network.SyncNetwork)

export type Namespace = {
	receiveGlobal: <T>(self: Namespace, name: string, atom: Charm.Atom<T>) -> Charm.Getter<T>,
	receivePlayer: <T>(self: Namespace, name: string, atom: Charm.Atom<T>) -> Charm.Getter<T>,
}

local function receive<T>(key: string, atom: Charm.Atom<T>): Charm.Getter<T>
	CharmSync.client.addSignals({ [key] = atom })
	return function(): T
		return atom()
	end
end

local function namespace(name: string): Namespace
	return {
		receiveGlobal = function<T>(_self: Namespace, signalName: string, atom: Charm.Atom<T>): Charm.Getter<T>
			return receive(SyncKey.global(name, signalName), atom)
		end,
		receivePlayer = function<T>(_self: Namespace, signalName: string, atom: Charm.Atom<T>): Charm.Getter<T>
			return receive(SyncKey.player(name, signalName, Players.LocalPlayer.UserId), atom)
		end,
	}
end

local SyncController = {
	namespace = namespace,
}

function SyncController.Start(): ()
	remotes.sync.patches:connect(CharmSync.client.patch)
	-- Let every controller finish its synchronous Start work before the server
	-- snapshots atoms registered through receiveGlobal.
	task.defer(function(): ()
		remotes.sync.ready:fire()
	end)
end

return SyncController
