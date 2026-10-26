--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDataTypes = require(ReplicatedStorage.Shared.Types.PlayerDataTypes)

type PlayerData = PlayerDataTypes.PlayerData
type ProfileTemplate = PlayerDataTypes.ProfileTemplate

local FlattenTemplate = {}

local function mergeRealm(flatData: PlayerData, realm: string, realmTemplate: PlayerData | number)
	if typeof(realmTemplate) == "table" then
		for key, defaultValue in realmTemplate do
			if flatData[key] ~= nil then
				warn(`flattenPlayerData() | Duplicate key {key} in ProfileTemplate`)
				continue
			end

			flatData[key] = defaultValue
		end
	else
		flatData[realm] = realmTemplate
	end
end

function FlattenTemplate.flatten(template: ProfileTemplate): PlayerData
	local flatData: PlayerData = {}
	mergeRealm(flatData, "Shared", template.Shared)
	mergeRealm(flatData, "Server", template.Server)
	mergeRealm(flatData, "Version", template.Version)
	return flatData
end

function FlattenTemplate.getFullKeys(
	keys: { [string]: boolean },
	template: PlayerData,
	parentFullKey: string?
): { [string]: boolean }
	for key, templateValue in template do
		local fullKey = if parentFullKey then parentFullKey .. "/" .. key else key

		if typeof(templateValue) == "table" and next(templateValue) ~= nil then
			FlattenTemplate.getFullKeys(keys, templateValue :: PlayerData, fullKey)
		else
			keys[fullKey] = true
		end
	end
	return keys
end

return FlattenTemplate
