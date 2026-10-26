--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataPath = require(ReplicatedStorage.Shared.Utils.DataPath)

local Charm = require(ReplicatedStorage.Packages.Charm)
local Sift = require(ReplicatedStorage.Packages.Sift)

export type SharedLeaf = boolean | number | string
export type PlayerSharedData = { [string]: SharedLeaf | PlayerSharedData | { SharedLeaf } }
export type PlayerAtomMap = { [number]: PlayerSharedData }

local atom = Charm.atom

local seed: PlayerAtomMap = {}
local playersAtom = atom(seed)

local function getAll(): PlayerAtomMap
	return playersAtom()
end

local function getPlayerData(userId: number): PlayerSharedData
	local existing = playersAtom()[userId]
	if existing then
		return existing
	end
	return {}
end

local function setPlayerData(userId: number, data: PlayerSharedData): ()
	playersAtom(Sift.Dictionary.set(playersAtom(), userId, data))
end

local function setAtPath(
	tree: PlayerSharedData,
	path: { string },
	value: SharedLeaf | PlayerSharedData | { SharedLeaf }
): PlayerSharedData
	local result = table.clone(tree)

	if #path == 1 then
		result[path[1]] = value
		return result
	end

	local head = path[1]
	local existingChild = result[head]
	local childTree: PlayerSharedData
	if typeof(existingChild) == "table" then
		childTree = existingChild :: PlayerSharedData
	else
		childTree = {}
	end

	local tailPath: { string } = {}
	for index = 2, #path do
		table.insert(tailPath, path[index])
	end

	result[head] = setAtPath(childTree, tailPath, value)

	return result
end

local function setPlayerAtPath(
	userId: number,
	path: { string },
	value: SharedLeaf | PlayerSharedData | { SharedLeaf }
): ()
	local currentData = getPlayerData(userId)
	local updated = setAtPath(currentData, path, value)
	setPlayerData(userId, updated)
end

local function removePlayerAtPath(userId: number, path: { string }): ()
	setPlayerData(userId, DataPath.removeAt(getPlayerData(userId), path))
end

local function removePlayer(userId: number): ()
	playersAtom(Sift.Dictionary.removeKey(playersAtom(), userId))
end

return {
	getAll = getAll,
	getPlayerData = getPlayerData,
	setPlayerData = setPlayerData,
	setPlayerAtPath = setPlayerAtPath,
	removePlayerAtPath = removePlayerAtPath,
	removePlayer = removePlayer,
}
