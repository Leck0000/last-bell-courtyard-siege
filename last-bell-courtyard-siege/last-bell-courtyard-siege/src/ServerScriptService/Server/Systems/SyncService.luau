--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage.Packages.Charm)
local CharmSync = require(ReplicatedStorage.Packages.CharmSync)
local SyncKey = require(ReplicatedStorage.Shared.Network.SyncKey)
local remotes = require(ReplicatedStorage.Shared.Network.SyncNetwork)

type PlayerSignal = {
	factory: (userId: number) -> () -> unknown,
	name: string,
	namespace: string,
}

export type Namespace = {
	globalSignal: <T>(self: Namespace, name: string, atom: Charm.Atom<T>) -> (),
	playerSignal: <T>(self: Namespace, name: string, factory: (userId: number) -> Charm.Getter<T>) -> (),
}

local globalSignals: { [string]: () -> unknown } = {}
-- A player is eligible for initial and late-registered signals only after its
-- client has installed the patch listener and registered receiving atoms.
local readyPlayers: { [Player]: boolean } = {}
local playerSignals: { [string]: PlayerSignal } = {}
local playerGetters: { [string]: () -> unknown } = {}

-- CharmSync warns when one key is tracked by two getters, so a connected
-- player must keep resolving each signal to the getter it first received.
local function resolvePlayerGetter(player: Player, signal: PlayerSignal): (string, () -> unknown)
	local key = SyncKey.player(signal.namespace, signal.name, player.UserId)
	local existing = playerGetters[key]
	if existing then
		return key, existing
	end
	local getter = signal.factory(player.UserId)
	playerGetters[key] = getter
	return key, getter
end

local function addSignals(player: Player): ()
	readyPlayers[player] = true
	local signals = table.clone(globalSignals)
	for _, signal in playerSignals do
		local key, getter = resolvePlayerGetter(player, signal)
		signals[key] = getter
	end
	CharmSync.server.addSignalsToClient(player, signals)
end

local function removePlayer(player: Player): ()
	readyPlayers[player] = nil
	for _, signal in playerSignals do
		playerGetters[SyncKey.player(signal.namespace, signal.name, player.UserId)] = nil
	end
	CharmSync.server.removeClient(player)
end

local function namespace(name: string): Namespace
	return {
		globalSignal = function<T>(_self: Namespace, signalName: string, atom: Charm.Atom<T>): ()
			local key = SyncKey.global(name, signalName)
			globalSignals[key] = atom
			for player in readyPlayers do
				CharmSync.server.addSignalsToClient(player, { [key] = atom })
			end
		end,
		playerSignal = function<T>(_self: Namespace, signalName: string, factory: (userId: number) -> Charm.Getter<T>): ()
			local signalKey = SyncKey.global(name, signalName)
			assert(
				playerSignals[signalKey] == nil,
				`playerSignal already registered for namespace "{name}" signal "{signalName}"`
			)
			local signal: PlayerSignal = { factory = factory, name = signalName, namespace = name }
			playerSignals[signalKey] = signal
			for player in readyPlayers do
				local key, getter = resolvePlayerGetter(player, signal)
				CharmSync.server.addSignalsToClient(player, { [key] = getter })
			end
		end,
	}
end

local function sendPatches(player: Player, payloads: { CharmSync.SyncPayload }): ()
	remotes.sync.patches:fire(player, payloads)
end

local SyncService = {
	namespace = namespace,
}

function SyncService.Start(): ()
	CharmSync.config.interval = 0
	CharmSync.config.preserveHistory = false
	CharmSync.config.fixArrays = true
	CharmSync.server.connect(sendPatches)
	remotes.sync.ready:connect(addSignals)
	Players.PlayerRemoving:Connect(removePlayer)
end

return SyncService
