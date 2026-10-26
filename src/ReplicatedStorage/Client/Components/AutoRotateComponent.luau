--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local MISSING_PRIMARY_PART_ERR = "AutoRotateComponent | Model %s must have a PrimaryPart."
local MISSING_AXIS_ERR = "AutoRotateComponent: 'RotationAxis' attribute is required."
local BAD_AXIS_ERR = "AutoRotateComponent: 'RotationAxis' attribute must be a Vector3."

--// Fusion References //--
local peek = Fusion.peek

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

local AutoRotateComponent = {
	Tag = "AutoRotateComponent",
	Ancestors = { Workspace },
	Extensions = { BaseComponent },
}

type AutoRotateComponentData = {
	Axis: Fusion.Value<Vector3?>,
}
type AutoRotateComponentDataInt = {
	_initialized: boolean,
}

export type AutoRotateComponent =
	typeof(setmetatable({} :: AutoRotateComponentData, AutoRotateComponent))
	& typeof(Component.getExtensionsType(BaseComponent))
	& Component.ComponentObject
type AutoRotateComponentInt = AutoRotateComponent & AutoRotateComponentDataInt

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

--[[
	BEHAVIOUR CHANGE, kept deliberately: a RotationAxis attribute removed at runtime
	reads as no rotation rather than as an error. The pre-migration code peeked the
	value straight, so removing the attribute wrote `AssemblyAngularVelocity = nil`
	on the observer thread -- an error Fusion swallows -- and left the instance
	spinning at whatever it last carried. Zero is what the component's own
	`shouldRender` already treats a missing axis as, and it actually stops the
	assembly. `Construct` still refuses to start without the attribute, so this
	silences nothing that was ever configured wrong at bind time.
]]
local function getAxis(self: AutoRotateComponentInt): Vector3
	return peek(self.Axis) or Vector3.zero
end

--- Writes one velocity onto the instance, every part beneath it, and every later one.
local function applyAngularVelocity(self: AutoRotateComponentInt, velocity: Vector3): ()
	if self.Instance:IsA("BasePart") then
		self.Instance.AssemblyAngularVelocity = velocity
	end
	for _, descendant in self.Instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.AssemblyAngularVelocity = velocity
		end
	end
	self:AddTask(
		self.Instance.DescendantAdded:Connect(function(descendant: Instance): ()
			if descendant:IsA("BasePart") then
				descendant.AssemblyAngularVelocity = velocity
			end
		end),
		nil,
		"SetAngularVelocityDescendantAdded"
	)
end

local function updateObjectOrientation(self: AutoRotateComponentInt, dt: number): ()
	if not self._initialized then
		self._initialized = true
		dt += math.random() * 60
	end

	local axis = getAxis(self)

	local deltaOrientation = dt * axis
	local instance = self.Instance :: PVInstance
	instance:PivotTo(
		instance:GetPivot() * CFrame.fromOrientation(deltaOrientation.X, deltaOrientation.Y, deltaOrientation.Z)
	)

	-- Guarded like `updateAngularVelocity` and FloatingComponent already were: a
	-- Model has no AssemblyAngularVelocity, and Construct admits Models explicitly,
	-- so this raised on every frame for every tagged Model.
	if self.Instance:IsA("BasePart") then
		self.Instance.AssemblyAngularVelocity = axis
	end
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function AutoRotateComponent.Construct(self: AutoRotateComponentInt): ()
	assert(
		(self.Instance:IsA("Model") and self.Instance.PrimaryPart) or self.Instance:IsA("BasePart"),
		string.format(MISSING_PRIMARY_PART_ERR, self.Instance:GetFullName())
	)

	local axis = self:GetAttribute("RotationAxis")
	assert(axis, MISSING_AXIS_ERR)
	assert(typeof(axis) == "Vector3", BAD_AXIS_ERR)

	self.Axis = self:OutAttribute("RotationAxis")
	self._initialized = false
end

function AutoRotateComponent.Start(self: AutoRotateComponentInt): ()
	-- onBind, not onChange: this is what pushes the axis onto the descendants and
	-- installs the DescendantAdded handler, and on onChange it did not run until
	-- something wrote the attribute a second time.
	self:Observer(self.Axis):onBind(function(): ()
		applyAngularVelocity(self, getAxis(self))
	end)

	local shouldRender = self:Computed(function(use: Fusion.Use): boolean
		local axis = use(self.Axis)
		return axis ~= nil and axis.Magnitude > 0
	end)
	self:Observer(shouldRender):onBind(function(): ()
		if peek(shouldRender) then
			self:AddTask(
				RunService.RenderStepped:Connect(function(dt: number): ()
					updateObjectOrientation(self, dt)
				end),
				"Disconnect",
				"RenderSteppedUpdate"
			)
		else
			self:RemoveTask("RenderSteppedUpdate")
		end
	end)
end

--[[
	Puts the assembly back at rest, as `FloatingComponent.Stop` does for its own.
	Without it, untagging left the instance and every part beneath it carrying the
	last axis the component wrote -- the tag was gone, the render step was gone, and
	the model kept turning under physics for the rest of the session.
]]
function AutoRotateComponent.Stop(self: AutoRotateComponentInt): ()
	applyAngularVelocity(self, Vector3.zero)
end

Component.new(AutoRotateComponent)
return AutoRotateComponent :: AutoRotateComponent
