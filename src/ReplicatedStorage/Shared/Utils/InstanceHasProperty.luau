--[[
	Used to check if an Instance has a property...
]]
return function(instance: any, property: string): boolean
	local success, result = pcall(function()
		return instance[property]
	end)

	return success and result ~= instance:FindFirstChild(property) or false
end