--// Roblox Services //--
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--// Types //--
type RequireFn = (module: ModuleScript) -> unknown

--// References //--
-- Discovery only knows which module to load at runtime, which luau-lsp cannot
-- resolve ("Unknown require: unsupported path"). Going through a typed alias
-- keeps require resolution out of it without reaching for `any`.
local requireModule: RequireFn = require

-- Keyed on the name alone, not on what the module returned: a component module
-- is free to return nil or false, and either would read as "never seen".
local loadedComponentNames: { [string]: boolean } = {}
local blacklist: { [string]: boolean } = {}
local didLoadComponents = false

--------------------------------------------------------------------------------
--// Service //--
--------------------------------------------------------------------------------

local ComponentService = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

-- Requires a module on a thread of its own, so a component that yields at
-- require time is still SUSPENDED when task.spawn returns and can be told apart
-- from one that finished.
--
-- Reports rather than raises. The scan is one pass over the whole place, so a
-- raise here costs every component discovered after the bad one, in every realm
-- folder still to come, and one unloadable module takes the place with it. The
-- warning is what the pre-Knit version lacked: it asserted on the spawned
-- thread, where nothing could see it and the pass reported success having
-- loaded nothing.
local function EnsureUnyieldingRequire(module: ModuleScript): ()
	local requireOk = false
	local requireError: unknown

	local thread = task.spawn(function(): ()
		requireOk, requireError = pcall(function(): ()
			requireModule(module)
		end)
	end)

	if coroutine.status(thread) ~= "dead" then
		warn("ComponentService: Component Require Yielded: " .. module.Name)
		return
	end

	if not requireOk then
		warn(`ComponentService: Failed to load component: {module.Name}\n{tostring(requireError)}`)
	end
end

local function requireComponents(): ()
	local function loadComponentsFromFolder(folder: Instance): ()
		for _, module in folder:GetDescendants() do
			if not (module:IsA("ModuleScript") and module.Name:match("Component$")) then
				continue
			end
			if blacklist[module.Name] then
				continue
			end

			if loadedComponentNames[module.Name] then
				warn("ComponentService: Duplicate component module found: " .. module.Name)
			end

			loadedComponentNames[module.Name] = true
			EnsureUnyieldingRequire(module)
		end
	end

	-- Same tolerance the bootstrapper grants its own scan roots: a template-shaped
	-- place need not have every realm folder, and a missing one is not an error.
	local function loadComponentsFromRoot(parent: Instance, name: string): ()
		local folder = parent:FindFirstChild(name)
		if folder == nil then
			return
		end

		loadComponentsFromFolder(folder)
	end

	if RunService:IsServer() then
		loadComponentsFromRoot(ServerScriptService, "Server")
	else
		loadComponentsFromRoot(ReplicatedStorage, "Client")
	end
	loadComponentsFromRoot(ReplicatedStorage, "Shared")
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[[
	Blacklists names from being registered as components.
	Must be called before `ComponentService.Start`; a later call warns and has no
	effect.
]]
function ComponentService.Blacklist(self: ComponentService, ...: string): ()
	if didLoadComponents then
		warn("ComponentService:Blacklist() called after components were loaded. This will have no effect.")
		return
	end

	-- Validated in full before anything is written: a rejected call must not leave
	-- the arguments preceding the bad one blacklisted.
	local names: { string } = {}
	for index = 1, select("#", ...) do
		local name: unknown = select(index, ...)
		if type(name) ~= "string" then
			error("ComponentService:Blacklist() expects string arguments, got " .. type(name), 2)
		end

		table.insert(names, name)
	end

	for _, name in names do
		blacklist[name] = true
	end
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function ComponentService.Start(): ()
	-- Set before the scan, not after: this flag IS the "after start" boundary
	-- Blacklist documents, so no call may take effect once the pass has begun.
	didLoadComponents = true
	requireComponents()
end

export type ComponentService = typeof(ComponentService)
return ComponentService
