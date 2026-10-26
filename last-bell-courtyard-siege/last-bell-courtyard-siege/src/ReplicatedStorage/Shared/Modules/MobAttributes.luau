--[[
	The attribute names MobServerComponent publishes and MobClientComponent
	mirrors. Held in one place because the two realms have to agree on them, and
	because a consumer reading a mob's health off the model reads them too.

	Modules/, not Data/: Shared/Data/ is the consumer's configuration folder, and
	these names are a private contract between two files of this package.
]]

local MobAttributes = {
	ReplicatedHealth = "ReplicatedHealth",
	ReplicatedStatus = "ReplicatedStatus",
}

return MobAttributes
