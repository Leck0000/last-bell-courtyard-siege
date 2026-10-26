--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Constants //--
-- Assets hang off `Shared`, never the ReplicatedStorage root: the template mounts
-- `src/Shared/Assets` and the build pipeline writes its cache there. Nothing anywhere
-- creates a top-level `ReplicatedStorage.Assets`.
local ASSETS_ROOT = "Shared/Assets"

local function followPath(location: Instance, path: string): Instance?
	local keys = string.split(path, "/")
	for index = 1, #keys do
		local step = keys[index]
		local newLocation = location:FindFirstChild(step)
		if not newLocation then
			return nil
		end
		location = newLocation
	end
	return location
end

--[[
	Returns an asset from the ReplicatedStorage.Shared.Assets folder
	@param assetName The name of the asset to search for
    @return Instance, boolean The Instance and whether or not it was found
]]
return function(assetName: string, dontWarn: boolean?): (Instance?, boolean)
	-- Warn on a missing folder rather than assert: the caller already branches on the
	-- returned boolean, and a game that ships no assets must still be able to call this.
	local asset = followPath(ReplicatedStorage, `{ASSETS_ROOT}/{assetName}`)

	if not asset and not dontWarn then
		warn(`Failed to find Asset: {assetName}\n{debug.traceback()}`)
	end

	return asset, asset ~= nil
end
