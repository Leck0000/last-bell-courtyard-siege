--[[
	Sole construction site for the ProximityPrompt an Interaction wraps.

	Split out because nothing can raise ProximityPrompt.Triggered from a script:
	Interaction's specs replace this module to reach the trigger path at all.
]]
local function createProximityPrompt(): ProximityPrompt
	return Instance.new("ProximityPrompt")
end

return createProximityPrompt
