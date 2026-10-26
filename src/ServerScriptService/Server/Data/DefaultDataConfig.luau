--!strict
local Types = require(game:GetService("ReplicatedStorage").Shared.Types.PlayerDataTypes)
local config: Types.PlayerDataConfig = {
 ProfileStoreName = "SchoolSessionMetadata1",
 ProfileTemplate = { Server = {}, Version = 1 },
 Migrator = {}, Leaderboard = {}, Debug = false,
}
return table.freeze(config)
