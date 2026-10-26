--[[
	BootstrapperLogic — two-pass require/start loader.

	Exports startServer() and startClient() for the shim scripts in this folder,
	plus `_runBootstrap(scanRoots, requireFn)` for tests to inject fake scan
	trees and require implementations.

	Phase 1 requires every discovered *Service/*Controller module under the scan
	roots (sorted by GetFullName for determinism). Phase 2 iterates the
	successfully required modules and calls Start(self) on any that expose one.
	Both phases continue on error; any failures are aggregated and raised as a
	single error at the end so the caller (rocale task, Studio run, etc.) sees
	exactly what went wrong.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

type RequireFn = (module: ModuleScript) -> any

type RequireSuccess = {
	module: ModuleScript,
	value: any,
}

type RequireFailure = {
	module: ModuleScript,
	err: string,
}

type StartFailure = {
	module: ModuleScript,
	err: string,
}

local function isSampleModule(name: string): boolean
	return name:match("_Sample$") ~= nil
end

local function isSpecModule(name: string): boolean
	return name:match("%.spec$") ~= nil
end

local function isUnderWallyIndex(module: ModuleScript): boolean
	local ancestor: Instance? = module.Parent
	while ancestor ~= nil do
		if ancestor.Name == "_Index" then
			return true
		end
		ancestor = ancestor.Parent
	end

	return false
end

local function shouldRegister(module: ModuleScript): boolean
	if isSampleModule(module.Name) then
		return false
	end
	if isSpecModule(module.Name) then
		return false
	end
	-- Only ever called with GetDescendants output, so a parent always exists;
	-- assert rather than guard so a future caller that breaks that gets a hard
	-- error instead of a silent skip.
	local parent = assert(module.Parent, "shouldRegister received an unparented module")
	if parent:IsA("ModuleScript") then
		return false
	end
	if isUnderWallyIndex(module) then
		return false
	end
	return true
end

local function shouldRequire(module: ModuleScript): boolean
	if module.Name:find("Service") ~= nil or module.Name:find("Controller") ~= nil then
		return true
	end
	-- Systems-folder entities (design.json type:"system") keep verbatim names
	-- (e.g. GameManager, not GameManagerService), so boot them by parent folder.
	-- KEEP IN SYNC WITH: reach.luau (parentIsSystems), script-context.ts
	-- (isAutoLoadedModule), boot-predicate-parity.test.ts.
	-- Same invariant as shouldRegister: only ever called with GetDescendants
	-- output, so assert rather than returning false on an unparented module —
	-- a silent skip would mean a Service never boots.
	local parent = assert(module.Parent, "shouldRequire received an unparented module")
	return parent.Name == "Systems"
end

local function collectModules(scanRoots: { Instance }): { ModuleScript }
	local collected: { ModuleScript } = {}
	for _, root in scanRoots do
		for _, descendant in root:GetDescendants() do
			if
				not descendant:IsA("ModuleScript")
				or not shouldRegister(descendant)
				or not shouldRequire(descendant)
			then
				continue
			end

			table.insert(collected, descendant)
		end
	end
	table.sort(collected, function(a: ModuleScript, b: ModuleScript): boolean
		return a:GetFullName() < b:GetFullName()
	end)
	return collected
end

local function buildFailureSummary(requireFailures: { RequireFailure }, startFailures: { StartFailure }): string
	local lines: { string } = { "Bootstrapper encountered failures:" }
	if #requireFailures > 0 then
		table.insert(lines, "Require failures:")
		for _, failure in requireFailures do
			table.insert(lines, string.format("  - %s: %s", failure.module:GetFullName(), failure.err))
		end
	end
	if #startFailures > 0 then
		table.insert(lines, "Start failures:")
		for _, failure in startFailures do
			table.insert(lines, string.format("  - %s: %s", failure.module:GetFullName(), failure.err))
		end
	end
	return table.concat(lines, "\n")
end

local function runBootstrap(scanRoots: { Instance }, requireFn: RequireFn?): ()
	local effectiveRequire: RequireFn = requireFn
		or function(module: ModuleScript): any
			return (require :: any)(module)
		end

	local modules = collectModules(scanRoots)

	local successes: { RequireSuccess } = {}
	local requireFailures: { RequireFailure } = {}
	for _, module in modules do
		local ok, result = xpcall(function(): any
			return effectiveRequire(module)
		end, debug.traceback)
		if ok then
			table.insert(successes, { module = module, value = result })
		else
			table.insert(requireFailures, { module = module, err = tostring(result) })
		end
	end

	local startFailures: { StartFailure } = {}
	for _, entry in successes do
		local value = entry.value
		if type(value) ~= "table" then
			continue
		end
		local startFn = value.Start
		if type(startFn) ~= "function" then
			continue
		end
		local ok, err = xpcall(function(): string?
			startFn(value)
			return nil
		end, debug.traceback)
		if not ok then
			table.insert(startFailures, { module = entry.module, err = tostring(err) })
		end
	end

	if #requireFailures > 0 or #startFailures > 0 then
		error(buildFailureSummary(requireFailures, startFailures))
	end
end

-- A template-shaped place need not contain every scan root — a server-only game
-- has no ReplicatedStorage.Client, a dependency-free one has no Packages folder.
-- Absent roots are simply not scanned.
local function appendScanRoot(scanRoots: { Instance }, parent: Instance, name: string): ()
	local child = parent:FindFirstChild(name)
	if child ~= nil then
		table.insert(scanRoots, child)
	end
end

-- Which realms this module instance has already started (T-163). A second start
-- re-requires every Service and calls Start on it again, which is how a screen
-- got registered twice and a PlayerAdded handler connected twice.
--
-- Scope worth knowing: this is per MODULE INSTANCE, so it catches a generated
-- script that requires THIS loader and calls start*() after the boot shim
-- already did. It cannot see a SECOND copy of the loader, because that copy has
-- its own upvalues. That was the actual T-163 defect, and it is fixed where it
-- belongs: nothing mounts a second self-starting shim any more. Keep both.
local started: { [string]: boolean } = {}

local function claimStart(realm: string): boolean
	if started[realm] then
		return false
	end
	started[realm] = true
	return true
end

local function startServer(): ()
	if not claimStart("server") then
		warn("Bootstrapper: startServer() already ran on this loader; ignoring the second call")
		return
	end
	local scanRoots: { Instance } = {}
	appendScanRoot(scanRoots, ServerScriptService, "Packages")
	appendScanRoot(scanRoots, ReplicatedStorage, "Packages")
	appendScanRoot(scanRoots, ReplicatedStorage, "Shared")
	appendScanRoot(scanRoots, ServerScriptService, "Server")
	runBootstrap(scanRoots)
end

local function startClient(): ()
	if not claimStart("client") then
		warn("Bootstrapper: startClient() already ran on this loader; ignoring the second call")
		return
	end
	local scanRoots: { Instance } = {}
	appendScanRoot(scanRoots, ReplicatedStorage, "Packages")
	appendScanRoot(scanRoots, ReplicatedStorage, "Shared")
	appendScanRoot(scanRoots, ReplicatedStorage, "Client")
	runBootstrap(scanRoots)
end

-- Exposed so a spec can exercise the claim without a DataModel: start*() itself
-- scans real services and cannot run under jest-roblox.
local function _resetStartClaims(): ()
	started = {}
end

local BootstrapperLogic = {
	startServer = startServer,
	startClient = startClient,
	_runBootstrap = runBootstrap,
	_claimStart = claimStart,
	_resetStartClaims = _resetStartClaims,
}

return BootstrapperLogic
