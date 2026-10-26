--!strict

-- The template is the sealed data registry, so its shape doubles as the schema:
-- an empty table declares an open collection whose contents are not checked, a
-- single-entry array declares the exemplar every entry must match, and any
-- other table declares a fixed set of keys.

type UnknownTable = { [unknown]: unknown }

local function childPath(parentPath: string, key: unknown): string
	local keyName = tostring(key)
	return if parentPath == "" then keyName else `{parentPath}/{keyName}`
end

local function isArrayTemplate(template: UnknownTable): boolean
	return next(template) == 1 and next(template, 1) == nil
end

local validateNode: (template: unknown, state: unknown, path: string, issues: { string }) -> ()

-- An absent open collection or array is legitimate; an absent fixed table is
-- reported leaf by leaf, so the warning names the key rather than its parent.
local function reportMissingLeaves(template: UnknownTable, path: string, issues: { string }): ()
	if next(template) == nil or isArrayTemplate(template) then
		return
	end

	for key, expected in template do
		validateNode(expected, nil, childPath(path, key), issues)
	end
end

local function validateArray(template: UnknownTable, state: UnknownTable, path: string, issues: { string }): ()
	local count = 0
	for key in state do
		if type(key) == "number" and key >= 1 and key % 1 == 0 then
			count += 1
		end
	end

	for key, entry in state do
		local entryPath = childPath(path, key)
		if type(key) == "number" and key >= 1 and key % 1 == 0 and key <= count then
			validateNode(template[1], entry, entryPath, issues)
		else
			table.insert(issues, `{entryPath}: unexpected key`)
		end
	end
end

local function validateObject(template: UnknownTable, state: UnknownTable, path: string, issues: { string }): ()
	for key, expected in template do
		validateNode(expected, state[key], childPath(path, key), issues)
	end

	for key in state do
		if template[key] == nil then
			table.insert(issues, `{childPath(path, key)}: unexpected key`)
		end
	end
end

local function validateTable(template: UnknownTable, state: UnknownTable, path: string, issues: { string }): ()
	if next(template) == nil then
		return
	end

	if isArrayTemplate(template) then
		validateArray(template, state, path, issues)
	else
		validateObject(template, state, path, issues)
	end
end

validateNode = function(template: unknown, state: unknown, path: string, issues: { string }): ()
	local templateType = type(template)
	if state == nil then
		if templateType == "table" then
			reportMissingLeaves(template :: UnknownTable, path, issues)
		else
			table.insert(issues, `{path}: expected {templateType}, got missing`)
		end
		return
	end

	local stateType = type(state)
	if stateType ~= templateType then
		table.insert(issues, `{path}: expected {templateType}, got {stateType}`)
		return
	end
	if templateType ~= "table" then
		return
	end

	validateTable(template :: UnknownTable, state :: UnknownTable, path, issues)
end

local function validate(template: unknown, state: unknown): { string }
	local issues: { string } = {}
	validateNode(template, state, "", issues)
	return issues
end

return {
	validate = validate,
}
