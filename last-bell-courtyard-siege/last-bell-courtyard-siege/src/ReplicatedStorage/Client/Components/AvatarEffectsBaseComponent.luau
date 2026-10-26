--!strict
--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Packages //--
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--- The part of a consumer's component this mixin uses. A consumer merges this table
--- into a component class built on base-component, which is what supplies every member
--- below apart from `Render`, `AttributeName` and the two optional inputs.
export type AvatarEffectsHost = {
	--- The attribute naming the equipped item, e.g. `EquippedTower1`.
	AttributeName: string,
	--- The instance carrying the attributes. When it is a Player, the mixin re-renders
	--- on every respawn.
	Instance: Instance,
	--- Set by `Started`: the equipped item id while every gate is open, false otherwise.
	IsActive: Fusion.Computed<unknown>?,
	--- Optional second attribute that must be truthy for the effect to be active.
	IsEnabledAttributeName: string?,
	--- Optional caller-owned state that must be truthy for the effect to be active.
	TogglingValue: Fusion.StateObject<unknown>?,

	AddTask: (self: AvatarEffectsHost, task: RBXScriptConnection) -> RBXScriptConnection,
	Computed: (self: AvatarEffectsHost, callback: (use: Fusion.Use) -> unknown) -> Fusion.Computed<unknown>,
	Observer: (self: AvatarEffectsHost, watching: Fusion.StateObject<unknown>) -> Fusion.Observer,
	Render: (self: AvatarEffectsHost) -> (),
	Value: (self: AvatarEffectsHost, initialValue: unknown) -> Fusion.Value<unknown>,
}

local AvatarEffectsBaseComponent = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

--- Mirrors an attribute into a Fusion value, kept current for as long as the host lives.
local function trackAttribute(self: AvatarEffectsHost, attributeName: string): Fusion.Value<unknown>
	local instance = self.Instance
	local state = self:Value(instance:GetAttribute(attributeName))

	self:AddTask(instance:GetAttributeChangedSignal(attributeName):Connect(function(): ()
		state:set(instance:GetAttribute(attributeName))
	end))

	return state
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function AvatarEffectsBaseComponent.Started(self: AvatarEffectsHost): ()
	assert(self.AttributeName, "AvatarEffectsBaseComponent requires an AttributeName")

	local equippedId = trackAttribute(self, self.AttributeName)
	local statesToCheck: { Fusion.StateObject<unknown> } = { equippedId }

	local isEnabledAttributeName = self.IsEnabledAttributeName
	if isEnabledAttributeName then
		table.insert(statesToCheck, trackAttribute(self, isEnabledAttributeName))
	end

	local togglingValue = self.TogglingValue
	if togglingValue then
		table.insert(statesToCheck, togglingValue)
	end

	local isActive = self:Computed(function(use: Fusion.Use): unknown
		local currentEquippedId = use(equippedId)
		if not currentEquippedId then
			return false
		end

		for _, state in statesToCheck do
			if not use(state) then
				return false
			end
		end

		return currentEquippedId
	end)
	self.IsActive = isActive

	self:Render()
	self:Observer(isActive):onChange(function(): ()
		self:Render()
	end)

	local instance = self.Instance
	if instance:IsA("Player") then
		self:AddTask(instance.CharacterAdded:Connect(function(): ()
			self:Render()
		end))
	end
end

export type AvatarEffectsBaseComponent = typeof(AvatarEffectsBaseComponent)
return AvatarEffectsBaseComponent
