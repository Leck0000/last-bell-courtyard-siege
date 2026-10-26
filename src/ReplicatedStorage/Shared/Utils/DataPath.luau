--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDataTypes = require(ReplicatedStorage.Shared.Types.PlayerDataTypes)

type PlayerData = PlayerDataTypes.PlayerData
type PlayerDataValue = PlayerDataTypes.PlayerDataValue

local DataPath = {}

local function tailOf(path: { string }): { string }
	return table.move(path, 2, #path, 1, {})
end

function DataPath.split(fullKey: string): { string }
	if fullKey == "" then
		return {}
	end

	return string.split(fullKey, "/")
end

function DataPath.getAt<V>(tree: PlayerData, path: { string }): V?
	local current: unknown = tree
	for _, segment in path do
		if typeof(current) ~= "table" then
			return nil
		end

		current = (current :: PlayerData)[segment]
	end

	return current :: V?
end

function DataPath.setAt(tree: PlayerData, path: { string }, value: PlayerDataValue): PlayerData
	local result = table.clone(tree)

	if #path == 1 then
		result[path[1]] = value
		return result
	end

	local head = path[1]
	local existingChild = result[head]
	local childTree: PlayerData
	if typeof(existingChild) == "table" then
		childTree = existingChild :: PlayerData
	else
		childTree = {}
	end

	result[head] = DataPath.setAt(childTree, tailOf(path), value)

	return result
end

function DataPath.removeAt(tree: PlayerData, path: { string }): PlayerData
	local result = table.clone(tree)

	if #path == 1 then
		result[path[1]] = nil
		return result
	end

	local head = path[1]
	local child = result[head]
	assert(typeof(child) == "table", `DataPath.removeAt could not traverse {head}`)

	result[head] = DataPath.removeAt(child :: PlayerData, tailOf(path))

	return result
end

return DataPath
