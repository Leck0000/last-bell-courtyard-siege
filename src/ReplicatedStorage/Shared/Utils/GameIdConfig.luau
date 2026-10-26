--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Dependencies //--
local Constants = require(ReplicatedStorage.Shared.Data.Constants)

--// References //--
local GameIDs = Constants.GameIDs

local function IsGameIdInArray(TargetArray: { number }): boolean
	return table.find(TargetArray, game.GameId) ~= nil
end

local GameIDtoIndex = {}
for index, gameID in GameIDs do
	GameIDtoIndex[gameID] = index
end

return table.freeze({
	GameIDs = GameIDs,
	GameIDtoIndex = table.freeze(GameIDtoIndex),

	IsLiveGame = IsGameIdInArray({
		GameIDs.LiveGame,
	}),

	-- Functions
	GetValueForThisGame = function<T, V>(GameIdToValueTable: { [number]: T }, defaultValue: V?)
		return GameIdToValueTable[game.GameId] or defaultValue
	end,
})
