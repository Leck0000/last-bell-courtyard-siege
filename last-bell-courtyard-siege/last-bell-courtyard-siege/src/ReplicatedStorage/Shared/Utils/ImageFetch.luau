--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Constants //--
local DEFAULT_IMAGE = "rbxassetid://"
-- Assets hang off `Shared`, never the ReplicatedStorage root: the template mounts
-- `src/Shared/Assets` and the build pipeline writes its cache there. Nothing anywhere
-- creates a top-level `ReplicatedStorage.Assets`.
local IMAGES_ROOT = "Shared/Assets/Images"

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
	Returns an imageId string if it exists, if it cant be found it returns a default imageId
	@param imageName The name of the image to search for
    @return string, boolean The imageId and whether or not it was found
]]
return function(imageName: string, dontWarn: boolean?): (string, boolean)
	-- Warn on a missing folder rather than assert: the caller already branches on the
	-- returned boolean, and a game that ships no images must still be able to call this.
	local image = followPath(ReplicatedStorage, `{IMAGES_ROOT}/{imageName}`)
	if image and image:IsA("Decal") then
		return image.Texture, true
	end

	if not dontWarn then
		-- Two different mistakes: a Folder or model left at the path is not the same as
		-- nothing being there, and one "failed to find" for both sent people hunting for
		-- a missing file that was present all along.
		if image then
			warn(`Image is a {image.ClassName}, not a Decal: {imageName}\n{debug.traceback()}`)
		else
			warn(`Failed to find Image: {imageName}\n{debug.traceback()}`)
		end
	end
	return DEFAULT_IMAGE, false
end
