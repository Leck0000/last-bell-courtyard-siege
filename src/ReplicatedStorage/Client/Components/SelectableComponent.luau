--// Roblox Services //--
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local DEFAULT_HOVER_CURSOR = "rbxassetid://82977994181453"
local DEFAULT_RANGE = 40
local TEXT_SIZE = 16
local MESSAGE_WIDTH = 200

--// Fusion References //--
local peek = Fusion.peek
local Children = Fusion.Children

--// References //--
local instances: { Instance } = {}
local rayParams = RaycastParams.new()
rayParams.FilterDescendantsInstances = instances
rayParams.FilterType = Enum.RaycastFilterType.Include
local localPlayer = Players.LocalPlayer
local selectionTokens: { number } = {}
local idItr = 0

--------------------------------------------------------------------------------
--// Component Declaration //--
--------------------------------------------------------------------------------

local SelectableComponent = {
	Tag = "SelectableComponent",
	Ancestors = { Workspace },
	Extensions = {
		BaseComponent,
	},
}

type SelectableComponentData = {
	Color: Fusion.Value<Color3>,
	Range: Fusion.Value<number>,
	Breathing: Fusion.Value<boolean>,
	Message: Fusion.Value<string>,
	CustomCursor: Fusion.Value<string>,
	MousePosition: Fusion.Value<Vector2>,
	Activated: Signal.Signal<RaycastResult>,
}
type SelectableComponentDataInt = {
	_id: number,
}

export type SelectableComponent =
	typeof(setmetatable({} :: SelectableComponentData, SelectableComponent))
	& typeof(Component.getExtensionsType(BaseComponent))
	& Component.ComponentObject
type SelectableComponentInt = SelectableComponent & SelectableComponentDataInt

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function fireRayFromMouse(inputObject: InputObject, distance: number): RaycastResult?
	local camera = Workspace.CurrentCamera
	assert(camera, "SelectableComponent: the workspace has no camera to aim from.")

	local ray: Ray = camera:ScreenPointToRay(inputObject.Position.X, inputObject.Position.Y)
	local origin, direction = ray.Origin, ray.Direction * distance
	return Workspace:Raycast(origin, direction, rayParams)
end

--[[
	The hit on this component's own instance, or nil when the pointer is somewhere
	else. One return value, not two: the old signature declared
	`(boolean, RaycastResult?)` and answered a bare `false` on both refusals, so the
	second value the callers destructure was never the one the signature promised.
]]
local function raycastToInstance(
	self: SelectableComponentInt,
	inputObject: InputObject,
	distance: number
): RaycastResult?
	local rayResult: RaycastResult? = fireRayFromMouse(inputObject, distance)
	if not rayResult then
		return nil
	end

	-- Check if the raycast hit the instance itself or a descendant of it
	local instance: Instance = self.Instance
	if rayResult.Instance ~= instance and not rayResult.Instance:IsDescendantOf(instance) then
		return nil
	end

	return rayResult
end

local function updateMouseCursor(self: SelectableComponentInt): () -> ()
	-- Atomic global state for resetting mouse cursor (so that multiple components aren't overwriting each other)
	table.insert(selectionTokens, self._id)

	UserInputService.MouseIcon = peek(self.CustomCursor)

	return function(): ()
		-- Asserts rather than skips: the janitor runs this exactly once per hover,
		-- and a token that is not there means the bookkeeping has already drifted.
		local index: number? = table.find(selectionTokens, self._id)
		assert(index, "SelectableComponent: the hover token was released twice.")
		table.remove(selectionTokens, index)

		if #selectionTokens == 0 then
			UserInputService.MouseIcon = ""
		end
	end
end

local function displayAsSelected(self: SelectableComponentInt): ()
	local guiInsetSizeY: number = (GuiService:GetGuiInset()).Y

	local janitor: Janitor.Janitor = self:AddTask(Janitor.new(), nil, "HoverJanitor")
	local scope = Fusion:scoped()
	janitor:Add(scope, "doCleanup", "HoverScope")

	janitor:Add(updateMouseCursor(self), true, "HoverCursor")

	local FillTransparency = scope:Value(0)
	local FillTransparencySpring = scope:Spring(FillTransparency, 4, 0)
	scope:Observer(self.Breathing):onBind(function(): ()
		local isBreathing: boolean = peek(self.Breathing)
		local upper = 0.5
		local lower = 0.2
		if isBreathing then
			FillTransparency:set(upper)
			FillTransparencySpring:setPosition(lower)
			FillTransparencySpring:setVelocity(0)
		else
			FillTransparency:set(lower)
			FillTransparencySpring:setPosition(lower)
			FillTransparencySpring:setVelocity(0)
		end
	end)

	local fillTransparency = scope:Computed(function(use: Fusion.Use): number
		return use(FillTransparencySpring)
	end)
	local fillColor = scope:Computed(function(use: Fusion.Use): Color3
		return use(self.Color)
	end)
	local messageText = scope:Computed(function(use: Fusion.Use): string
		return use(self.Message)
	end)
	local messagePosition = scope:Computed(function(use: Fusion.Use): UDim2
		local mousePos: Vector2 = use(self.MousePosition)
		return UDim2.fromOffset(mousePos.X, mousePos.Y + guiInsetSizeY - 20)
	end)
	local messagePositionSpring = scope:Spring(messagePosition, 90, 1.1)
	local messageSize = scope:Value(UDim2.new())

	scope:Observer(messageText):onBind(function(): ()
		local textParams: GetTextBoundsParams = Instance.new("GetTextBoundsParams")
		textParams.Text = peek(messageText)
		textParams.Font = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Regular)
		textParams.Size = TEXT_SIZE
		textParams.Width = MESSAGE_WIDTH
		local size: Vector2 = TextService:GetTextBoundsAsync(textParams)
		messageSize:set(UDim2.fromOffset(size.X, size.Y))
	end)

	-- Define the highlight
	scope:New("Highlight")({
		Name = "HoverHighlight",
		Parent = self.Instance,
		FillColor = fillColor,
		FillTransparency = fillTransparency,
		OutlineTransparency = 0.25,
	})

	-- Define the message UI
	scope:New("ScreenGui")({
		Name = `SelectableComponentUI:{self._id}`,
		Parent = localPlayer:WaitForChild("PlayerGui"),
		IgnoreGuiInset = true,
		ResetOnSpawn = false,

		[Children] = {
			scope:New("TextLabel")({
				Name = "Message",
				Size = messageSize,
				Position = messagePositionSpring,
				AnchorPoint = Vector2.new(0.5, 1),

				BackgroundTransparency = 1,
				Text = messageText,
				TextSize = TEXT_SIZE,
				TextColor3 = Color3.new(1, 1, 1),
				TextStrokeTransparency = 0.4,
			}),
		},
	})
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function SelectableComponent.Construct(self: SelectableComponentInt): ()
	self:DefaultAttribute("Color", Color3.fromHSV(0.128, 1, 1), { "Color3" })
	self:DefaultAttribute("Range", DEFAULT_RANGE, { "number" })
	self:DefaultAttribute("Breathing", true, { "boolean" })
	self:DefaultAttribute("Message", "", { "string" })
	self:DefaultAttribute("CustomCursor", DEFAULT_HOVER_CURSOR, { "string" })
	self.Color = self:OutAttribute("Color")
	self.Range = self:OutAttribute("Range")
	self.Breathing = self:OutAttribute("Breathing")
	self.Message = self:OutAttribute("Message")
	self.CustomCursor = self:OutAttribute("CustomCursor")
	self.Activated = self:RegisterSignal("Activated") :: Signal.Signal<RaycastResult>

	-- Set the mouse state initially
	local mouse: Mouse = localPlayer:GetMouse()
	self.MousePosition = self:Value(Vector2.new(mouse.X, mouse.Y))

	-- Add us to the global state
	table.insert(instances, self.Instance)
	rayParams.FilterDescendantsInstances = instances

	idItr += 1
	self._id = idItr
end

function SelectableComponent.Start(self: SelectableComponentInt): ()
	-- Connect hovering listener
	ContextActionService:BindAction(
		`SelectableComponentHover:{self._id}`,
		function(
			_actionName: string,
			_inputState: Enum.UserInputState,
			inputObject: InputObject
		): Enum.ContextActionResult
			-- Decide if the hover runtime should be setup or not based on mouse position
			if raycastToInstance(self, inputObject, peek(self.Range)) then
				self.MousePosition:set(Vector2.new(inputObject.Position.X, inputObject.Position.Y))

				-- If we don't have a hover janitor yet, then create it
				if not self:GetTask("HoverJanitor") then
					displayAsSelected(self)
				end
			else -- Mouse is no longer on the wall, remove our hover runtime
				if self:GetTask("HoverJanitor") then
					self:RemoveTask("HoverJanitor")
				end
			end

			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.UserInputType.MouseMovement,
		Enum.UserInputType.Touch
	)
	self:AddTask(function(): ()
		ContextActionService:UnbindAction(`SelectableComponentHover:{self._id}`)
	end)

	-- Implement click detection
	ContextActionService:BindAction(
		`SelectableComponentClick:{self._id}`,
		function(
			_actionName: string,
			inputState: Enum.UserInputState,
			inputObject: InputObject
		): Enum.ContextActionResult
			if inputState == Enum.UserInputState.End then
				local rayResult = raycastToInstance(self, inputObject, peek(self.Range))
				if rayResult then
					self.Activated:Fire(rayResult)
				end
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch
	)
	self:AddTask(function(): ()
		ContextActionService:UnbindAction(`SelectableComponentClick:{self._id}`)
	end)
end

function SelectableComponent.Stop(self: SelectableComponentInt): ()
	local index: number? = table.find(instances, self.Instance)
	assert(index, "SelectableComponent: the instance was taken out of the selection list twice.")
	table.remove(instances, index)
	rayParams.FilterDescendantsInstances = instances
end

Component.new(SelectableComponent)
return SelectableComponent :: SelectableComponent
