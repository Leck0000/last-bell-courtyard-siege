--!strict
local InstanceFactory = {}

function InstanceFactory.new(className: string): Instance
	return Instance.new(className :: any)
end

return InstanceFactory
