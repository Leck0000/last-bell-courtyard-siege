--!strict

type UnknownTable = { [unknown]: unknown }

local WIRE_DATATYPES: { [string]: boolean } = {
	Axes = true,
	BrickColor = true,
	buffer = true,
	CFrame = true,
	Color3 = true,
	ColorSequence = true,
	ColorSequenceKeypoint = true,
	DateTime = true,
	EnumItem = true,
	Faces = true,
	Font = true,
	NumberRange = true,
	NumberSequence = true,
	NumberSequenceKeypoint = true,
	PathWaypoint = true,
	PhysicalProperties = true,
	Ray = true,
	Rect = true,
	Region3 = true,
	Region3int16 = true,
	TweenInfo = true,
	UDim = true,
	UDim2 = true,
	Vector2 = true,
	Vector2int16 = true,
	Vector3 = true,
	Vector3int16 = true,
}

local function isWireValue(value: unknown, visiting: { [unknown]: boolean }): boolean
	local valueType = type(value)
	if valueType == "boolean" or valueType == "number" or valueType == "string" then
		return true
	end
	if WIRE_DATATYPES[typeof(value)] then
		return true
	end
	if valueType ~= "table" or visiting[value] then
		return false
	end

	local tableValue = value :: UnknownTable
	visiting[value] = true
	for key, nestedValue in tableValue do
		local keyType = type(key)
		if (keyType ~= "number" and keyType ~= "string") or not isWireValue(nestedValue, visiting) then
			return false
		end
	end
	visiting[value] = nil
	return true
end

local function isSyncPayload(payload: unknown, visiting: { [unknown]: boolean }): boolean
	if type(payload) ~= "table" then
		return false
	end
	local payloadTable = payload :: UnknownTable
	if payloadTable.type ~= "init" and payloadTable.type ~= "patch" then
		return false
	end
	if type(payloadTable.data) ~= "table" then
		return false
	end
	local data = payloadTable.data :: UnknownTable
	for key, value in data do
		if type(key) ~= "string" or not isWireValue(value, visiting) then
			return false
		end
	end
	return true
end

local function isSyncPayloadList(payloads: unknown): boolean
	if type(payloads) ~= "table" then
		return false
	end

	local payloadList = payloads :: UnknownTable
	local visiting: { [unknown]: boolean } = {}
	local expectedLength = #payloadList
	local seenCount = 0
	for key, payload in payloadList do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > expectedLength then
			return false
		end
		if not isSyncPayload(payload, visiting) then
			return false
		end
		seenCount += 1
	end
	return seenCount == expectedLength
end

return isSyncPayloadList
