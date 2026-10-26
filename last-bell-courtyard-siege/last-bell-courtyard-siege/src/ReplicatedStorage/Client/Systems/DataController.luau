--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DataPath = require(ReplicatedStorage.Shared.Utils.DataPath)
local PlayerDataTypes = require(ReplicatedStorage.Shared.Types.PlayerDataTypes)
local SyncController = require(ReplicatedStorage.Client.Systems.SyncController)

local Charm = require(ReplicatedStorage.Packages.Charm)
local Promise = require(ReplicatedStorage.Packages.Promise)

type PlayerData = PlayerDataTypes.PlayerData
type PlayerDataValue = PlayerDataTypes.PlayerDataValue
type Prediction = {
	path: { string },
	value: PlayerDataValue,
	sequence: number,
}
type ValidationSnapshot = {
	state: PlayerData,
	template: PlayerData,
}

local STRICT_MODE = RunService:IsStudio()
local namespace = SyncController.namespace("data")
local playerDataAtom = Charm.atom({} :: PlayerData)
local playerData = namespace:receivePlayer("playerData", playerDataAtom)
local predictionsAtom = Charm.atom({} :: { [string]: Prediction })
local nextPredictionSequence = 0
local predictedData = Charm.computed(function(): PlayerData
	local data = playerData()
	local orderedPredictions: { Prediction } = {}
	for _, prediction in predictionsAtom() do
		table.insert(orderedPredictions, prediction)
	end
	table.sort(orderedPredictions, function(a: Prediction, b: Prediction): boolean
		return a.sequence < b.sequence
	end)
	for _, prediction in orderedPredictions do
		data = DataPath.setAt(data, prediction.path, prediction.value)
	end
	return data
end)

local DataController = {}

if STRICT_MODE then
	local DataSchemaValidator = require(ReplicatedStorage.Shared.Utils.DataSchemaValidator)
	local templateAtom = Charm.atom({} :: PlayerData)
	local template = namespace:receiveGlobal("template", templateAtom)

	Charm.subscribe(function(): ValidationSnapshot
		return { state = playerData(), template = template() }
	end, function(snapshot: ValidationSnapshot): ()
		-- Both atoms start empty and are filled by separate patches, so there is
		-- nothing to compare until each side has arrived.
		if next(snapshot.state) == nil or next(snapshot.template) == nil then
			return
		end

		for _, issue in DataSchemaValidator.validate(snapshot.template, snapshot.state) do
			warn(`DataController schema mismatch at {issue}`)
		end
	end)
end

function DataController.get<T>(fullKey: string): Charm.Getter<T?>
	assert(type(fullKey) == "string", "fullKey must be a string")
	local path = DataPath.split(fullKey)
	return function(): T?
		return DataPath.getAt(predictedData(), path)
	end
end

function DataController.predict<T...>(
	fullKey: string,
	value: PlayerDataValue,
	request: () -> Promise.TypedPromise<T...>
): Promise.TypedPromise<T...>
	assert(type(fullKey) == "string", "fullKey must be a string")

	nextPredictionSequence += 1
	local prediction: Prediction = { path = DataPath.split(fullKey), value = value, sequence = nextPredictionSequence }
	local predictions = table.clone(predictionsAtom())
	predictions[fullKey] = prediction
	predictionsAtom(predictions)

	return Promise.try(request):finally(function(): ()
		local currentPredictions = predictionsAtom()
		-- A later prediction on the same key owns it until its own request settles.
		if currentPredictions[fullKey] ~= prediction then
			return
		end

		local remainingPredictions = table.clone(currentPredictions)
		remainingPredictions[fullKey] = nil
		predictionsAtom(remainingPredictions)
	end)
end

function DataController.loaded(): boolean
	return next(playerData()) ~= nil
end

return DataController
