--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local MISSING_PRIMARY_PART_ERR = "FloatingComponent | Model %s must have a PrimaryPart."
local MISSING_FREQUENCY_ERR = "FloatingComponent: 'FloatingFrequency' attribute is required."
local BAD_FREQUENCY_ERR = "FloatingComponent: 'FloatingFrequency' attribute must be a number."
local MISSING_AMPLITUDE_ERR = "FloatingComponent: 'FloatingAmplitude' attribute is required."
local BAD_AMPLITUDE_ERR = "FloatingComponent: 'FloatingAmplitude' attribute must be a number."

--// Fusion References //--
local peek = Fusion.peek

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

local FloatingComponent = {
	Tag = "FloatingComponent",
	Ancestors = { Workspace },
	Extensions = { BaseComponent },
}

type FloatingComponentData = {
	Amplitude: Fusion.Value<number?>,
	Frequency: Fusion.Value<number?>,
}
type FloatingComponentDataInt = {
	_initialized: boolean,
	_time: number,
	_pivotPart: BasePart,
	_originalPivot: CFrame,
}

export type FloatingComponent =
	typeof(setmetatable({} :: FloatingComponentData, FloatingComponent))
	& typeof(Component.getExtensionsType(BaseComponent))
	& Component.ComponentObject
type FloatingComponentInt = FloatingComponent & FloatingComponentDataInt

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

--- The part whose PivotOffset the bob is driven through.
local function getPivotPart(instance: Instance): BasePart
	if instance:IsA("Model") then
		local primaryPart = instance.PrimaryPart
		assert(primaryPart, string.format(MISSING_PRIMARY_PART_ERR, instance:GetFullName()))
		return primaryPart
	end

	assert(instance:IsA("BasePart"), string.format(MISSING_PRIMARY_PART_ERR, instance:GetFullName()))
	return instance
end

local function updateLinearVelocity(self: FloatingComponentInt, velocity: Vector3): ()
	if self.Instance:IsA("BasePart") then
		self.Instance.AssemblyLinearVelocity = velocity
	end
	for _, descendant in self.Instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = velocity
		end
	end
	self:AddTask(
		self.Instance.DescendantAdded:Connect(function(descendant: Instance): ()
			if descendant:IsA("BasePart") then
				descendant.AssemblyLinearVelocity = velocity
			end
		end),
		nil,
		"SetLinearVelocityDescendantAdded"
	)
end

local function updateObjectAmplitude(self: FloatingComponentInt, dt: number): ()
	if not self._initialized then
		self._initialized = true
		dt += math.random() * 60
	end

	-- Asserts rather than fallbacks: the render step is bound only while both
	-- attributes are present, and unbound the moment either goes, so there is no
	-- reachable frame where these are missing.
	local amplitude = peek(self.Amplitude)
	local frequency = peek(self.Frequency)
	assert(amplitude, MISSING_AMPLITUDE_ERR)
	assert(frequency, MISSING_FREQUENCY_ERR)

	self._time += dt
	local theta = self._time * frequency * math.pi

	amplitude *= math.sin(theta)
	local pivot = self.Instance:GetPivot()
	local prevPivotOffset = self._pivotPart.PivotOffset
	local newPivotOffset = self._originalPivot:ToWorldSpace(CFrame.new(0, -amplitude, 0))
	self._pivotPart.PivotOffset = newPivotOffset
	self.Instance:PivotTo(pivot)

	local velocity = -(newPivotOffset.Position - prevPivotOffset.Position) / dt
	updateLinearVelocity(self, velocity)
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function FloatingComponent.Construct(self: FloatingComponentInt): ()
	self._pivotPart = getPivotPart(self.Instance)

	local floatingFrequency = self:GetAttribute("FloatingFrequency")
	assert(floatingFrequency, MISSING_FREQUENCY_ERR)
	assert(typeof(floatingFrequency) == "number", BAD_FREQUENCY_ERR)
	local floatingAmplitude = self:GetAttribute("FloatingAmplitude")
	assert(floatingAmplitude, MISSING_AMPLITUDE_ERR)
	assert(typeof(floatingAmplitude) == "number", BAD_AMPLITUDE_ERR)

	self.Amplitude = self:OutAttribute("FloatingAmplitude")
	self.Frequency = self:OutAttribute("FloatingFrequency")

	self._originalPivot = self._pivotPart.PivotOffset
	self._initialized = false
	self._time = 0
end

function FloatingComponent.Start(self: FloatingComponentInt): ()
	local shouldRender = self:Computed(function(use: Fusion.Use): boolean
		return use(self.Frequency) ~= nil and use(self.Amplitude) ~= nil
	end)
	self:Observer(shouldRender):onBind(function(): ()
		if peek(shouldRender) then
			self:AddTask(
				RunService.RenderStepped:Connect(function(dt: number): ()
					updateObjectAmplitude(self, dt)
				end),
				"Disconnect",
				"RenderStepped"
			)
		else
			self:RemoveTask("RenderStepped")
			updateLinearVelocity(self, Vector3.zero)
		end
	end)
end

--[[
	Puts the instance back where the tag found it. `_originalPivot` was cached for
	exactly this and was otherwise write-only, so untagging used to leave the part
	frozen at whatever offset the last sine happened to produce, still carrying its
	last non-zero velocity.
]]
function FloatingComponent.Stop(self: FloatingComponentInt): ()
	local pivot = self.Instance:GetPivot()
	self._pivotPart.PivotOffset = self._originalPivot
	self.Instance:PivotTo(pivot)

	updateLinearVelocity(self, Vector3.zero)
end

Component.new(FloatingComponent)
return FloatingComponent :: FloatingComponent
