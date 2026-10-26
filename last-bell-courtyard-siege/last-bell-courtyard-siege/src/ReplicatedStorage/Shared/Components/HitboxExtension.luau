--[[
    @class HitboxExtension
	This extension handles implementation of hitboxes, calling Component:OnTouched(interactor: Player) once any player hits it.
	Note that Component:OnTouched(interactor: Player) will yeild the debounce until its done

	How to use the hitbox extension:
	```lua
	function YourComponent:OnTouched(interactor: Player)
		-- interactor is the player who touched the hitbox.
	end
	```

	 (Optional) Custom handling of Touched event:
	```lua
	function YourComponent:HandleHitboxTouched(hit: BasePart): Player?
		-- hit is the part that triggered the touch event.
	end
	```
]]

--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)

--// Constants //--
local DEBOUNCE_TIME = 0.1

--// Types //--
--[[
	Everything the extension keeps per component, held in one record rather than in
	several slots on the component object: a component object carries a single
	indexer type, so differently-typed slots collapse into one another and every
	read of one of them is then reported against the type of the last.
]]
type HitboxState = {
	Debounce: boolean,
	Enabled: boolean,
	Hitboxes: { BasePart },
	ResolveToucher: (hit: BasePart) -> Player?,
}

--[[
	The receivers name `Component.ComponentObject` rather than the local
	`ComponentObject`: that alias names this table back, and the cycle resolves to a
	free `[any]` indexer which then answers for every other method on the object —
	`AddTask` among them.
]]
type HitboxExtensionData = {
	HandleHitboxTouched: ((self: Component.ComponentObject, hit: BasePart) -> Player?)?,
	OnTouched: (self: Component.ComponentObject, interactor: Player) -> (),
}

--[[
	BaseComponent is named here even though this extension does not list it: the
	touch connections go through `self:AddTask`, which BaseComponent contributes,
	so a component that lists HitboxExtension without it errors at the first
	descendant.

	`HitboxExtension` itself is NOT named here, and the alias is declared ahead of
	the functions that use it. Naming it would close a cycle — the table carries
	`Started`, whose receiver is this alias — and Luau breaks that cycle by dropping
	the intersection down to `Component.ComponentObject`, at which point `AddTask`
	and `OnTouched` both stop resolving. `HitboxExtensionData` is intersected
	directly instead, which is the half of the extension this module reads.
]]
type ComponentObject = Component.ComponentObject & typeof(Component.getExtensionsType(BaseComponent)) & HitboxExtensionData

--[[
	Keyed on the component object rather than parked on it under a symbol: writing a
	symbol slot onto the object is not expressible against its metatable type, and
	`Stopped` below is what keeps this table from outliving the components.
]]
local stateByComponent: { [Component.ComponentObject]: HitboxState } = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function getState(self: Component.ComponentObject): HitboxState
	local state = stateByComponent[self]
	assert(state, "HitboxExtension: hitbox state read before Started, or after Stopped.")
	return state
end

--[[
	`handler` arrives as a parameter rather than as an upvalue of the returned
	closure: Luau drops the `if handleHitboxTouched then` refinement on a local the
	closure captures, so the optional receiver has to be narrowed at the call.
]]
local function makeResolveToucher(
	componentObject: Component.ComponentObject,
	handler: (self: Component.ComponentObject, hit: BasePart) -> Player?
): (hit: BasePart) -> Player?
	return function(hit: BasePart): Player?
		return handler(componentObject, hit)
	end
end

local function resolveTouchingPlayer(hit: BasePart): Player?
	return Players:GetPlayerFromCharacter(hit.Parent)
end

local function handleHitbox(self: ComponentObject, hitbox: Instance): ()
	if not hitbox:IsA("BasePart") then
		return
	end

	local state = getState(self)
	if table.find(state.Hitboxes, hitbox) then
		return
	end

	-- The current enabled state, not `true`: a part added after
	-- `SetHitboxesEnabled(false)` must not come up touchable.
	hitbox.CanTouch = state.Enabled
	table.insert(state.Hitboxes, hitbox)

	self:AddTask(hitbox.Touched:Connect(function(hit: BasePart): ()
		local player = state.ResolveToucher(hit)

		if not state.Debounce and player then
			state.Debounce = true

			local startedAt = os.clock()

			-- Always pcalled. The un-pcalled Studio branch this replaces left the
			-- debounce latched on any error OnTouched raised, so the hitbox went
			-- dead for the rest of the session — and only where developers work.
			local success, err = pcall(self.OnTouched, self, player)
			if not success then
				warn(err)
			end

			-- os.clock, not os.time: os.time has one-second resolution, so the
			-- subtraction was either 0 or a whole second depending on where the
			-- touch landed against the wall clock.
			task.wait(DEBOUNCE_TIME - (os.clock() - startedAt))

			state.Debounce = false
		end
	end))
end

--------------------------------------------------------------------------------
--// Extension Methods //--
--------------------------------------------------------------------------------

local function SetHitboxesEnabled(self: Component.ComponentObject, enabled: boolean): ()
	local state = getState(self)
	state.Enabled = enabled

	for _, hitbox in state.Hitboxes do
		hitbox.CanTouch = enabled
	end
end

--------------------------------------------------------------------------------
--// Extension Declaration //--
--------------------------------------------------------------------------------

local HitboxExtension = {}

local Methods = {
	SetHitboxesEnabled = SetHitboxesEnabled,
}
HitboxExtension.Methods = Methods :: HitboxExtensionData & typeof(Methods)

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function HitboxExtension.Started(self: ComponentObject): ()
	-- At start, not at the first touch. A component with no OnTouched used to warn
	-- once per touch and drop it, so the omission surfaced only when a player
	-- happened to walk into the hitbox.
	assert(
		self.OnTouched,
		`HitboxExtension: {self.Instance:GetFullName()} lists HitboxExtension but implements no OnTouched.`
	)

	local handleHitboxTouched = self.HandleHitboxTouched
	local state: HitboxState = {
		Debounce = false,
		Enabled = true,
		Hitboxes = {},
		ResolveToucher = if handleHitboxTouched
			then makeResolveToucher(self, handleHitboxTouched)
			else resolveTouchingPlayer,
	}
	stateByComponent[self] = state

	local instance = self.Instance
	handleHitbox(self, instance)
	for _, part in instance:GetDescendants() do
		handleHitbox(self, part)
	end
	self:AddTask(instance.DescendantAdded:Connect(function(part: Instance): ()
		handleHitbox(self, part)
	end))
end

--[[
	The state table is this module's own, so nothing else drops it: without this a
	long-lived server keeps one record — and its part list — per component that has
	ever started.
]]
function HitboxExtension.Stopped(self: ComponentObject): ()
	stateByComponent[self] = nil
end

return HitboxExtension
