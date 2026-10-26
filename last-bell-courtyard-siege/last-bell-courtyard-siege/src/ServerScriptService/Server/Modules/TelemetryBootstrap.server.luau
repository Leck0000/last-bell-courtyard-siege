--!strict
--[[
	Starts the shipped game's telemetry, if this build belongs to a run.

	WHY IT IS HERE AND NOT AT `src/Server/`. `setup.luau`'s `realmTree` mounts
	the standard subdirectories of each realm and deliberately puts no `$path` on
	the realm node itself, so a file at `src/Server/` is in no Rojo project,
	reaches no place, and raises nothing anywhere — the exact silent death this
	module exists to detect. `RunStamp.luau` is written beside this file, in this
	directory, for the same reason.
	`packages/sandbox/tests/unit/project-template/telemetry-bootstrap-drift.test.ts`
	fails if either one stops being reachable.

	`RunStamp` is written into the workspace by the controlPlane before the rojo
	build, so a template checkout belonging to no run simply has no sibling and
	this script returns having done nothing. That is the supported state for
	anyone using the template directly, not a degraded one — and the same is true
	of a build whose package set does not carry `ParalovTelemetry`.

	The whole body is `pcall`'d. This runs in every game we generate, and a raise
	here would be an error in somebody else's product; the module it starts holds
	the same property from the other side (see `paralov-telemetry`).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function moduleChild(parent: Instance, name: string): ModuleScript?
	local found = parent:FindFirstChild(name)
	if found ~= nil and found:IsA("ModuleScript") then
		return found
	end
	return nil
end

local function start(): ()
	-- A Script mounted in a Folder always has one; assert rather than guard so a
	-- restructure that breaks it is loud (inside the `pcall`) instead of silent.
	local here = assert(script.Parent, "TelemetryBootstrap must run beside RunStamp")

	local stamp = moduleChild(here, "RunStamp")
	if stamp == nil then
		return
	end

	local packages = ReplicatedStorage:FindFirstChild("Packages")
	if packages == nil then
		return
	end
	local telemetry = moduleChild(packages, "ParalovTelemetry")
	if telemetry == nil then
		return
	end

	local run = require(stamp)
	-- The four fields `renderRunStamp` emits, by name. `endpoint` is the WHOLE
	-- url, route included: the stamp's writer owns the route, and the module
	-- posts what it is handed, verbatim.
	require(telemetry).start({
		endpoint = run.endpoint,
		runId = run.runId,
		projectId = run.projectId,
		token = run.token,
	})
end

pcall(start)
