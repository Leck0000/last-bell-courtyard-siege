--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

--// Dependencies //--
local TweenModelProperties = require(ReplicatedStorage.Shared.Utils.TweenModelProperties)

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local TogglePlayerTweenInfo = TweenInfo.new(0.3)
local CameraSpringFrequency = 5 -- The dampening factor at which the camera follows the character
local CameraTweenBackTime = 0.3 -- Time it takes to tween back camera when it is reset
local HIDDEN_TRANSPARENCY = 0.8
local UNSUPPORTED_INSTANCE_ERR = "FocusCameraComponent: %s is neither a Model nor a BasePart."
local CHARACTER_LOAD_TIMEOUT = 60
local NO_ROOT_PART_ERR = "FocusCameraComponent: %s never loaded a HumanoidRootPart."
local NO_HUMANOID_ERR = "FocusCameraComponent: %s never loaded a Humanoid."
local NO_CAMERA_ERR = "FocusCameraComponent: the workspace has no camera to drive."

--// Fusion References //--
local peek = Fusion.peek

--// References //--
local LocalPlayer = Players.LocalPlayer
local globalJanitor = Janitor.new()
local character: Model?
local humanoid: Humanoid?
local rootPart: BasePart?
local idItr = 0

--[[
	Read per call rather than held from require time. `Workspace.CurrentCamera` is
	nil for the opening frames of a client session and is replaced outright whenever
	the game swaps cameras, so a module-scope `assert` on it refused to load the
	whole component — no tag bound, nothing to retry — and a module-scope local kept
	driving a camera the game had already put down. SelectableComponent already reads
	the camera this way.
]]
local function getCamera(): Camera
	local camera = Workspace.CurrentCamera
	assert(camera, NO_CAMERA_ERR)
	return camera
end

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

--[[
	Sample for player focus for inventory system
	```lua
		local function toggleFocusCameraOnPlayer(bool: boolean)
			if bool then
				self._cachedWalkSpeed = StarterPlayer.CharacterWalkSpeed
				humanoid.WalkSpeed = 0

				local relativeCameraOffset = CFrame.new(Vector3.new(-0.4, 0.7, -6.5), Vector3.new(-3, 0, 0))
				character:SetAttribute("RelativeCameraOffset", relativeCameraOffset)
				character:SetAttribute("HideOtherPlayers", true)
				CollectionService:AddTag(character, "FocusCameraComponent")
			else
				CollectionService:RemoveTag(character, "FocusCameraComponent")
				character:SetAttribute("RelativeCameraOffset", nil)
				character:SetAttribute("HideOtherPlayers", nil)

				humanoid.WalkSpeed = self._cachedWalkSpeed
			end
		end
	```
--]]

local FocusCameraComponent = {
	Tag = "FocusCameraComponent",
	Ancestors = { Workspace },
	Extensions = { BaseComponent },
}

type CameraSpring<T> = {
	Goal: Fusion.Value<T>,
	Spring: Fusion.Spring<T>,
}

type FocusCameraComponentData = {
	RelativeCameraOffset: Fusion.Value<CFrame?>,
	HideOtherPlayers: Fusion.Value<boolean?>,
	HideLocalPlayer: Fusion.Value<boolean?>,
	FieldOfView: Fusion.Value<number?>,
	CameraSpeed: Fusion.Value<number>,
}
type FocusCameraComponentDataInt = {
	_cachedCameraOffset: Vector3?,
	_cachedCameraCFrame: CFrame?,
	_cachedFieldOfView: number?,
	_goalCameraCFrame: CFrame?,
	_enabled: boolean,
	_id: number,
	_springs: {
		CameraPosition: CameraSpring<Vector3>,
		CameraLookVector: CameraSpring<Vector3>,
		CameraUpVector: CameraSpring<Vector3>,
		FieldOfView: CameraSpring<number>,
	},
}

export type FocusCameraComponent =
	typeof(setmetatable({} :: FocusCameraComponentData, FocusCameraComponent))
	& typeof(Component.getExtensionsType(BaseComponent))
	& Component.ComponentObject
type FocusCameraComponentInt = FocusCameraComponent & FocusCameraComponentDataInt

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

local function getModelSize(model: Instance): Vector3
	if model:IsA("Model") then
		return model:GetExtentsSize()
	end

	-- Named here rather than left to the caller, which used to meet a nil size and
	-- fail on `targetSize.X` with nothing naming the instance that caused it.
	assert(model:IsA("BasePart"), string.format(UNSUPPORTED_INSTANCE_ERR, model:GetFullName()))
	return model.Size
end

local function getCameraOffset(fov: number, targetSize: Vector3): number
	local x, y, z = targetSize.X, targetSize.Y, targetSize.Z
	local maxSize = math.sqrt(x ^ 2 + y ^ 2 + z ^ 2)
	local fac = math.tan(math.rad(fov) / 2)
	local depth = 0.5 * maxSize / fac
	return depth + maxSize / 2
end

--- Where the camera wants to sit for this instance, this frame.
local function getGoalCameraCFrame(self: FocusCameraComponentInt): CFrame
	local instance = self.Instance :: PVInstance
	local relativeCameraOffset = peek(self.RelativeCameraOffset)
	if relativeCameraOffset then
		return instance:GetPivot() * relativeCameraOffset
	end

	local cameraRelativeOffset = getCameraOffset(getCamera().FieldOfView, getModelSize(instance)) * 0.8
	return instance:GetPivot() * CFrame.new(0, 0, cameraRelativeOffset)
end

local function setCharacter(char: Model): ()
	if char == character then
		return
	end

	character = nil
	rootPart = nil
	humanoid = nil

	-- Asserts rather than a silent return. Waiting a full minute and then tracking
	-- nothing, quietly, is how the camera ends up frozen with no way to tell why.
	local newRootPart = char:WaitForChild("HumanoidRootPart", CHARACTER_LOAD_TIMEOUT) :: BasePart?
	assert(newRootPart, string.format(NO_ROOT_PART_ERR, char:GetFullName()))
	local newHumanoid = char:WaitForChild("Humanoid", CHARACTER_LOAD_TIMEOUT) :: Humanoid?
	assert(newHumanoid, string.format(NO_HUMANOID_ERR, char:GetFullName()))

	rootPart = newRootPart
	humanoid = newHumanoid
	character = char
end

local function togglePlayer(otherPlayer: Player, bool: boolean): ()
	globalJanitor:Remove(otherPlayer.UserId)
	local function toggleCharacter(otherCharacter: Model): ()
		TweenModelProperties(otherCharacter, TogglePlayerTweenInfo, {
			LocalTransparencyModifier = if bool then 0 else HIDDEN_TRANSPARENCY,
		})
	end

	if otherPlayer.Character then
		task.defer(toggleCharacter, otherPlayer.Character)
	end

	if not bool then
		globalJanitor:Add(otherPlayer.CharacterAdded:Connect(toggleCharacter), nil, otherPlayer.UserId)
	end
end

local function togglePlayers(bool: boolean): ()
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer == LocalPlayer then
			continue
		end

		togglePlayer(otherPlayer, bool)
	end
end

local function tweenCameraBack(self: FocusCameraComponentInt): ()
	local id = self._id

	local cachedCameraOffset = self._cachedCameraOffset
	local cachedCameraCFrame = self._cachedCameraCFrame
	local cachedFieldOfView = self._cachedFieldOfView

	globalJanitor:Add(function(): ()
		local camera = getCamera()
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end)

	if not (cachedCameraOffset and cachedCameraCFrame and cachedFieldOfView) then
		globalJanitor:Cleanup()
		return
	end

	local camera = getCamera()
	local oldFieldOfView = camera.FieldOfView
	local oldCFrame = camera.CFrame

	local timeElapsed = 0
	RunService:BindToRenderStep(
		"TweenBack" .. tostring(id),
		Enum.RenderPriority.Camera.Value - 1,
		function(dt: number): ()
			timeElapsed += dt

			local currentRootPart = rootPart
			if not currentRootPart then
				RunService:UnbindFromRenderStep("TweenBack" .. tostring(id))
				return
			end

			local newPos = currentRootPart.Position + cachedCameraOffset
			local targetCFrame = CFrame.lookAt(newPos, newPos + cachedCameraCFrame.LookVector)
			camera.CFrame = oldCFrame:Lerp(targetCFrame, math.min(timeElapsed / CameraTweenBackTime, 1))
			camera.FieldOfView = lerp(oldFieldOfView, cachedFieldOfView, math.min(timeElapsed / CameraTweenBackTime, 1))
		end
	)
	globalJanitor:Add(function(): ()
		RunService:UnbindFromRenderStep("TweenBack" .. tostring(id))
	end)
	globalJanitor:Add(task.delay(CameraTweenBackTime, function(): ()
		globalJanitor:Cleanup()
	end))
end

local function resetCamera(self: FocusCameraComponentInt): ()
	if not self._enabled then
		return
	end
	self._enabled = false

	if peek(self.HideOtherPlayers) then
		togglePlayers(true)
	end
	if peek(self.HideLocalPlayer) then
		togglePlayer(LocalPlayer, true)
	end

	RunService:UnbindFromRenderStep("UpdateCamera" .. tostring(self._id))

	-- Spawn a task to tween the camera back
	tweenCameraBack(self)
end

local function updateSpringsPosition(self: FocusCameraComponentInt, positionCFrame: CFrame): ()
	self._springs.CameraLookVector.Spring:setPosition(positionCFrame.LookVector)
	self._springs.CameraUpVector.Spring:setPosition(positionCFrame.UpVector)
	self._springs.CameraPosition.Spring:setPosition(positionCFrame.Position)
	self._springs.FieldOfView.Spring:setPosition(getCamera().FieldOfView)
end

local function updateSpringsGoal(self: FocusCameraComponentInt, goalCFrame: CFrame): ()
	self._springs.CameraLookVector.Goal:set(goalCFrame.LookVector)
	self._springs.CameraUpVector.Goal:set(goalCFrame.UpVector)
	self._springs.CameraPosition.Goal:set(goalCFrame.Position)

	local fieldOfView = peek(self.FieldOfView)
	if fieldOfView then
		self._springs.FieldOfView.Goal:set(fieldOfView)
	end
end

local function updateCamera(self: FocusCameraComponentInt): ()
	self._goalCameraCFrame = getGoalCameraCFrame(self)
	updateSpringsGoal(self, self._goalCameraCFrame)

	local lookVector = peek(self._springs.CameraLookVector.Spring)
	local upVector = peek(self._springs.CameraUpVector.Spring)
	local position = peek(self._springs.CameraPosition.Spring)
	local fieldOfView = peek(self._springs.FieldOfView.Spring)

	local cameraCFrame = CFrame.lookAt(position, position + lookVector, upVector)
	local camera = getCamera()
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = fieldOfView
	camera.CFrame = cameraCFrame
end

local function setupCamera(self: FocusCameraComponentInt): ()
	-- An assert, not a guard: `Start` runs once per tagged instance and is the only
	-- caller, so a second setup would mean the framework had changed underneath us.
	assert(not self._enabled, "FocusCameraComponent: the camera was set up twice for one instance.")
	self._enabled = true

	globalJanitor:Cleanup()

	globalJanitor:Add(function(): ()
		resetCamera(self)
	end, nil, "ResetCamera" .. tostring(self._id))

	self._goalCameraCFrame = getGoalCameraCFrame(self)

	-- Cache the original camera offset and CFrame
	local camera = getCamera()
	--[[
		Written only when there is a root part to measure from; the field is left
		alone otherwise, which reads back the same nil. Same reason as
		PartTeleportServerComponent.TargetAttachment: `getExtensionsType` leaves most
		of its method slots unbound, and the `any` they become carries
		`tweenCameraBack`'s non-nil refinement into this field's write type, which an
		explicit nil no longer satisfies. `setupCamera` runs once per component, so
		there is never a stale offset to clear.
	]]
	local currentRootPart = rootPart
	if currentRootPart then
		self._cachedCameraOffset = camera.CFrame.Position - currentRootPart.Position
	end
	self._cachedCameraCFrame = camera.CFrame
	self._cachedFieldOfView = camera.FieldOfView

	updateSpringsPosition(self, self._cachedCameraCFrame)
	updateSpringsGoal(self, self._goalCameraCFrame)

	camera.CameraType = Enum.CameraType.Scriptable

	RunService:BindToRenderStep(
		"UpdateCamera" .. tostring(self._id),
		Enum.RenderPriority.Camera.Value - 1,
		function(_dt: number): ()
			if not rootPart then
				return
			end
			updateCamera(self)
		end
	)
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function FocusCameraComponent.Construct(self: FocusCameraComponentInt): ()
	self:DefaultAttribute("CameraSpeed", CameraSpringFrequency)
	self.RelativeCameraOffset = self:OutAttribute("RelativeCameraOffset")
	self.HideOtherPlayers = self:OutAttribute("HideOtherPlayers")
	self.HideLocalPlayer = self:OutAttribute("HideLocalPlayer")
	self.FieldOfView = self:OutAttribute("FieldOfView")
	self.CameraSpeed = self:OutAttribute("CameraSpeed")

	local camera = getCamera()
	local cameraPositionGoal = self:Value(camera.CFrame.Position)
	local cameraLookVectorGoal = self:Value(camera.CFrame.LookVector)
	local cameraUpVectorGoal = self:Value(camera.CFrame.UpVector)
	local fieldOfViewGoal = self:Value(camera.FieldOfView)

	self._springs = {
		CameraPosition = {
			Goal = cameraPositionGoal,
			Spring = self:Spring(cameraPositionGoal, self.CameraSpeed, 1),
		},
		CameraLookVector = {
			Goal = cameraLookVectorGoal,
			Spring = self:Spring(cameraLookVectorGoal, self.CameraSpeed, 1),
		},
		CameraUpVector = {
			Goal = cameraUpVectorGoal,
			Spring = self:Spring(cameraUpVectorGoal, self.CameraSpeed, 1),
		},
		FieldOfView = {
			Goal = fieldOfViewGoal,
			Spring = self:Spring(fieldOfViewGoal, self.CameraSpeed, 1),
		},
	}

	idItr += 1
	self._id = idItr
end

function FocusCameraComponent.Start(self: FocusCameraComponentInt): ()
	setupCamera(self)
	self:Observer(self.HideOtherPlayers):onBind(function(): ()
		togglePlayers(not peek(self.HideOtherPlayers))
	end)
	self:Observer(self.HideLocalPlayer):onBind(function(): ()
		togglePlayer(LocalPlayer, not peek(self.HideLocalPlayer))
	end)
end

function FocusCameraComponent.Stop(self: FocusCameraComponentInt): ()
	globalJanitor:Remove("ResetCamera" .. tostring(self._id))
end

-- Bind-and-check, at require time. A framework start hook used to gate this; with
-- the framework gone there is no later moment to run it in, because a component
-- has no module lifecycle hook of its own — `Start` is per tagged instance.
-- Neither line yields, which `ComponentService.EnsureUnyieldingRequire` requires
-- of every `*Component` module it loads.
LocalPlayer.CharacterAdded:Connect(setCharacter)

if LocalPlayer.Character then
	task.defer(setCharacter, LocalPlayer.Character)
end

Component.new(FocusCameraComponent)
return FocusCameraComponent :: FocusCameraComponent
