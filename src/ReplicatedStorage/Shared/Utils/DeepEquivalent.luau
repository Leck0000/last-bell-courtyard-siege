--[[
	Deep equivalent comparison of a table assuming keys are indexable in the same way.

	@param target table -- Table to check
	@param source table -- Other table to check
	@return boolean
]]
local function deepEquivalent(target, source)
	if target == source then
		return true
	end

	if type(target) ~= type(source) then
		return false
	end

	if type(target) == "table" then
		for key, value in target do
			if not deepEquivalent(value, source[key]) then
				return false
			end
		end

		for key, value in source do
			if not deepEquivalent(value, target[key]) then
				return false
			end
		end

		return true
	else
		-- target == source should do it.
		return false
	end
end

return deepEquivalent
