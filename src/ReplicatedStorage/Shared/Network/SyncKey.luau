--!strict
local SyncKey = {}

function SyncKey.global(namespace: string, name: string): string
	assert(not namespace:find("/"), `SyncKey namespace must not contain "/": {namespace}`)
	assert(not name:find("/"), `SyncKey name must not contain "/": {name}`)
	return `{namespace}/{name}`
end

function SyncKey.player(namespace: string, name: string, userId: number): string
	return `{SyncKey.global(namespace, name)}/{userId}`
end

return SyncKey
