--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--// Dependencies //--
local InteractionService = require(ReplicatedStorage.Shared.Systems.InteractionService)
local createProximityPrompt = require(ReplicatedStorage.Shared.Utils.CreateProximityPrompt)

--// Packages //--
local BaseObject = require(ReplicatedStorage.Packages.BaseObject)
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local TESTING_MODE = RunService:IsStudio()
-- Marks every prompt this package creates. An attribute rather than a table of
-- our own because it replicates: a client-side sweep has to spare the prompt a
-- server-side Interaction owns.
local OWNED_PROMPT_ATTRIBUTE = "ParalovInteractionPrompt"
-- Mirrors ASSIGNED_KEY_ATTRIBUTE in pipeline-v2's lune/emit_geometry.luau.
local ASSIGNED_KEY_ATTRIBUTE = "ParalovAssignedKey"
-- An authored Name has no length limit and is the game's text, not ours.
local LOG_FIELD_LIMIT = 120
local DefaultPromptProperties: { [string]: unknown } = {
	ActionText = "Interact",
	ObjectText = "Object",
	RequiresLineOfSight = false,
	MaxActivationDistance = 10,
}

--------------------------------------------------------------------------------
--// Object Decleration //--
--------------------------------------------------------------------------------

local InteractionStatic = {}

local Interaction = {}
Interaction.ClassName = "Interaction"
Interaction.__index = Interaction

-- Values are `UsedAs`, so a caller can hand over a plain value or a Fusion state
-- object and Hydrate binds whichever it gets.
export type PromptProperties = {
	ActionText: Fusion.UsedAs<string>?,
	MaxActivationDistance: Fusion.UsedAs<number>?,
	ObjectText: Fusion.UsedAs<string>?,
	Parent: PVInstance | Attachment,
	RequiresLineOfSight: Fusion.UsedAs<boolean>?,
}

-- UpdateProperties merges into what the prompt already has, so every key is
-- optional here; SetProperties replaces the set and needs a Parent.
export type PromptPropertyUpdate = {
	ActionText: Fusion.UsedAs<string>?,
	MaxActivationDistance: Fusion.UsedAs<number>?,
	ObjectText: Fusion.UsedAs<string>?,
	Parent: (PVInstance | Attachment)?,
	RequiresLineOfSight: Fusion.UsedAs<boolean>?,
}

export type InteractionProps = {
	ActionText: Fusion.UsedAs<string>?,
	InstantActivation: boolean,
	MaxActivationDistance: Fusion.UsedAs<number>?,
	ObjectText: Fusion.UsedAs<string>?,
	OnActivated: (Player: Player) -> (),
	Parent: PVInstance | Attachment,
	RequiresLineOfSight: Fusion.UsedAs<boolean>?,
}

-- Underscore-prefixed fields are private by convention, not by type: a method
-- declared on a narrower self is one no caller outside this file can invoke.
type InteractionData = {
	_enabledBeforeOccupy: boolean,
	_instantActivation: boolean,
	_occupied: Player | false,
	_onActivated: (Player: Player) -> (),
	_properties: PromptProperties,
	_proximityPrompt: ProximityPrompt,
}

export type Interaction = typeof(setmetatable({} :: InteractionData, Interaction)) & BaseObject.BaseObject

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

-- The property tables are declared field by field for the caller's sake; the
-- default fill and the merge address them by dynamic key.
local function asPropertyBag(properties: PromptProperties | PromptPropertyUpdate): { [string]: unknown }
	return (properties :: unknown) :: { [string]: unknown }
end

local function isPlayerAlive(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildWhichIsA("Humanoid", true)
	if not humanoid then
		return false
	end

	return humanoid:GetState() ~= Enum.HumanoidStateType.Dead
end

local function occupy(self: Interaction, player: Player): boolean
	if self._occupied then
		return false
	end

	self._enabledBeforeOccupy = self._proximityPrompt.Enabled
	self:SetEnabled(false)
	self._occupied = player

	return true
end

local function unoccupy(self: Interaction): ()
	if not self._occupied then
		return
	end

	self:SetEnabled(self._enabledBeforeOccupy)
	self._occupied = false
end

local function activate(self: Interaction, player: Player): ()
	local interactionToken = if RunService:IsServer() then nil else InteractionService:AddModalRequest()

	-- Wrapped rather than passed straight to pcall: pcall is typed
	-- `(f: (A...) -> R..., A...) -> (boolean, R...)`, and a callback declared `()`
	-- makes R... empty, so the error value would have nowhere to land.
	local success, err = pcall(function(): string?
		self._onActivated(player)
		return nil
	end)

	-- The lock and the modal request are released on every exit, the re-raising
	-- Studio one included: a leaked lock disables this prompt for the rest of the
	-- session, and a leaked modal request disables every prompt in the game.
	if interactionToken then
		InteractionService:RemoveModalRequest(interactionToken)
	end

	unoccupy(self)

	if success then
		return
	end

	if TESTING_MODE then
		error(err, 0)
	end

	warn(err)
end

local function trigger(self: Interaction, player: Player): ()
	if not isPlayerAlive(player) then
		return
	end

	if self._instantActivation or occupy(self, player) then
		activate(self, player)
	end
end

-- Every Interaction owns the attachment it creates. Adopting one that is already
-- there would hand two Interactions a parent only the first of them destroys; a
-- caller that wants a fixed location passes the Attachment as Parent instead.
local function getPromptParent(self: Interaction, instance: Model | BasePart): Attachment
	local primaryPart = if instance:IsA("Model") then instance.PrimaryPart else instance
	assert(primaryPart, "PrimaryPart missing for " .. instance:GetFullName())

	local attachment = Instance.new("Attachment")
	self:AddTask(attachment)

	attachment.Position = Vector3.new(0, 0, -primaryPart.Size.Z / 2 * 0.7)
	attachment.Name = "ProximityLocation"
	attachment.Parent = primaryPart

	return attachment
end

-- A Model and its PrimaryPart are ONE host: Roblox renders a prompt on either at
-- the same spot, and the attachment this package creates hangs off the part.
local function hostsOf(anchor: Instance): { Instance }
	local hosts: { Instance } = { anchor }

	if anchor:IsA("Model") then
		local primaryPart: Instance? = anchor.PrimaryPart
		if primaryPart ~= nil then
			table.insert(hosts, primaryPart)
		end

		return hosts
	end

	local model = anchor.Parent
	if model ~= nil and model:IsA("Model") and model.PrimaryPart == anchor then
		table.insert(hosts, model)
	end

	return hosts
end

-- One key=value field out of a name the game authored. A Name keeps its line
-- terminators through the .rbxm round trip, so an authored one interpolated raw
-- lets a crafted landmark forge a second log event; every LineTerminator plus
-- VT, FF and NEL goes to a space. That space is itself a field separator, so the
-- result is quoted, and a quote inside it is escaped rather than allowed to close
-- the field early and inject one.
local function forLog(text: string): string
	local flattened = string.gsub(text, "[\n\r\v\f]", " ")
	flattened = string.gsub(flattened, "\u{0085}", " ")
	flattened = string.gsub(flattened, "\u{2028}", " ")
	flattened = string.gsub(flattened, "\u{2029}", " ")

	-- Bounded BEFORE escaping, so the cut can never land between a backslash and
	-- the character it escapes. Cut by bytes rather than characters: the branch a
	-- utf8.offset cut needs can only fire on a field longer than this, and Roblox
	-- caps a Name below it, so nothing but GetFullName() could ever reach the
	-- other side. A split trailing character costs one glyph in a diagnostic.
	local bounded = string.sub(flattened, 1, LOG_FIELD_LIMIT)
	local escaped = string.gsub(bounded, '[\\"]', "\\%0")

	return `"{escaped}"`
end

--- What a destroyed placeholder left for the prompt that replaces it, and the keys that made it the twin.
--- `held` while a live Interaction's prompt stands in for it, so a second one on the host is not given it too.
type Twin = {
	name: string,
	attributes: { [string]: unknown },
	keyboard: Enum.KeyCode,
	gamepad: Enum.KeyCode,
	assigned: boolean,
	held: boolean,
}

-- Not in a Twin, so the weak key below is the only reference to where it stood.
type Placed = { place: Instance, twin: Twin }

-- The first Interaction.new destroys the placeholder, so a teardown and rebuild on the same
-- host finds the twin here instead. Keyed weakly by the instance the placeholder stood under.
local rememberedTwins: { [Instance]: { Twin } } = {}

local function remember(placed: Placed): ()
	local twins: { Twin } = rememberedTwins[placed.place] or {}
	rememberedTwins[placed.place] = twins

	local twin = placed.twin
	for index, other in twins do
		if other.keyboard == twin.keyboard and other.gamepad == twin.gamepad then
			twins[index] = twin
			return
		end
	end

	table.insert(twins, twin)
end

local function destroyIfTwin(host: Instance, candidate: Instance, prompt: ProximityPrompt): Placed?
	if not candidate:IsA("ProximityPrompt") then
		return nil
	end

	-- Exactly `true`, the only value this package writes: a prompt carrying the
	-- attribute with any other value is the game's, and the game does not own it.
	if candidate:GetAttribute(OWNED_PROMPT_ATTRIBUTE) == true then
		return nil
	end

	-- Both keys, not either: exclusivity is per button, so a prompt that shares
	-- only the gamepad default is a second action on its own keyboard key and an
	-- "Inspect" on F beside this "Buy" on E has to survive.
	if candidate.KeyboardKeyCode ~= prompt.KeyboardKeyCode or candidate.GamepadKeyCode ~= prompt.GamepadKeyCode then
		return nil
	end

	-- The package's own marks stay its own: a copied assigned-key mark would hand this key to
	-- the next Interaction on the host, beside a prompt its sweep spares.
	local attributes = candidate:GetAttributes()
	local assigned = attributes[ASSIGNED_KEY_ATTRIBUTE] == true
	attributes[OWNED_PROMPT_ATTRIBUTE] = nil
	attributes[ASSIGNED_KEY_ATTRIBUTE] = nil

	-- Tags are not carried: a game that wires Triggered from a tag's added signal would
	-- run beside OnActivated on every press. The declared path is name and place alone.
	local placed: Placed = {
		-- Every candidate onHosts yields is a child of a host or of a host's attachment.
		place = assert(candidate.Parent, "a swept prompt has a parent"),
		twin = {
			name = candidate.Name,
			attributes = attributes,
			keyboard = candidate.KeyboardKeyCode,
			gamepad = candidate.GamepadKeyCode,
			assigned = assigned,
			held = false,
		},
	}

	-- One line per deletion: a playtest still pressing a dead prompt needs to see
	-- whether the sweep ran at all.
	warn(
		`[INTERACTION] twin_prompt_destroyed host={forLog(host:GetFullName())} prompt={forLog(candidate.Name)} key={candidate.KeyboardKeyCode.Name}`
	)
	candidate:Destroy()
	return placed
end

-- Roblox shows ONE prompt per key, so a prompt already on the host wins the
-- binding over the one being created here and swallows every press. The caller
-- cannot delete it instead: it is authored geometry, its name is the author's,
-- and a miss is silent. Destroyed rather than disabled, because a disabled twin
-- at the same point still takes the key.
--
-- Two levels deep and no further: a prompt under a CHILD model or part belongs
-- to that instance's own interaction, not to this one.
type OnHost = { host: Instance, candidate: Instance }

local function onHosts(target: PVInstance | Attachment): { OnHost }
	local found: { OnHost } = {}
	local anchor = if target:IsA("Attachment") then target.Parent else target
	if anchor == nil then
		return found
	end

	for _, host in hostsOf(anchor) do
		for _, child in host:GetChildren() do
			table.insert(found, { host = host, candidate = child })

			if child:IsA("Attachment") then
				for _, grandChild in child:GetChildren() do
					table.insert(found, { host = host, candidate = grandChild })
				end
			end
		end
	end

	return found
end

-- Every instance a swept prompt can stand under: each host and its attachments.
local function placesOf(target: PVInstance | Attachment): { Instance }
	local places: { Instance } = {}
	local anchor = if target:IsA("Attachment") then target.Parent else target
	if anchor == nil then
		return places
	end

	for _, host in hostsOf(anchor) do
		table.insert(places, host)
		for _, child in host:GetChildren() do
			if child:IsA("Attachment") then
				table.insert(places, child)
			end
		end
	end

	return places
end

local function rememberedOn(target: PVInstance | Attachment, matches: (twin: Twin) -> boolean): Placed?
	for _, place in placesOf(target) do
		local twins: { Twin } = rememberedTwins[place] or {}
		for _, twin in twins do
			if matches(twin) then
				return { place = place, twin = twin }
			end
		end
	end

	return nil
end

local function clearTwinPrompts(target: PVInstance | Attachment, prompt: ProximityPrompt): Placed?
	local first: Placed? = nil
	for _, item in onHosts(target) do
		local placed = destroyIfTwin(item.host, item.candidate, prompt)
		if first == nil then
			first = placed
		end
	end

	if first ~= nil then
		remember(first)
		return first
	end

	return rememberedOn(target, function(twin: Twin): boolean
		return not twin.held and twin.keyboard == prompt.KeyboardKeyCode and twin.gamepad == prompt.GamepadKeyCode
	end)
end

-- T-281: the geometry harness moves a prompt off a key a nearby host already
-- binds and marks it. Ours takes that key BEFORE the sweep, so the moved prompt
-- is the twin it deletes; left on E, ours would bring the clash straight back.
local function takeAssignedKey(target: PVInstance | Attachment, prompt: ProximityPrompt): ()
	for _, item in onHosts(target) do
		local candidate = item.candidate
		if candidate:IsA("ProximityPrompt") and candidate:GetAttribute(ASSIGNED_KEY_ATTRIBUTE) == true then
			-- Both keys, because destroyIfTwin matches both.
			prompt.KeyboardKeyCode = candidate.KeyboardKeyCode
			prompt.GamepadKeyCode = candidate.GamepadKeyCode
			return
		end
	end

	local remembered = rememberedOn(target, function(twin: Twin): boolean
		return twin.assigned and not twin.held
	end)
	if remembered ~= nil then
		prompt.KeyboardKeyCode = remembered.twin.keyboard
		prompt.GamepadKeyCode = remembered.twin.gamepad
	end
end

local function createPrompt(self: Interaction, properties: PromptProperties): ()
	self._proximityPrompt = createProximityPrompt()
	self._proximityPrompt:SetAttribute(OWNED_PROMPT_ATTRIBUTE, true)

	self:AddTask(self._proximityPrompt)
	self:AddTask(self._proximityPrompt.Triggered:Connect(function(player: Player): ()
		trigger(self, player)
	end))

	local parent = properties.Parent
	takeAssignedKey(parent, self._proximityPrompt)

	-- A contract declares the placeholder's path and a bot presses it there, so ours
	-- takes its name and attributes and, unless the caller handed an Attachment, its
	-- place. Into `properties`, because every rebind re-hydrates Parent from there.
	local placed = clearTwinPrompts(parent, self._proximityPrompt)
	if placed ~= nil then
		local twin = placed.twin
		twin.held = true
		self:AddTask(function(): ()
			twin.held = false
		end)

		self._proximityPrompt.Name = twin.name
		for attribute, value in twin.attributes do
			self._proximityPrompt:SetAttribute(attribute, value)
		end
	end

	-- Tested positively, not as `not parent:IsA("Attachment")`: only the positive
	-- form narrows PVInstance to the Model-or-BasePart getPromptParent needs.
	if parent:IsA("Model") or parent:IsA("BasePart") then
		-- A Model or BasePart target sweeps only its hosts' children and their
		-- attachments' children, so the twin stood on a PVInstance or an Attachment.
		properties.Parent = if placed ~= nil
			then placed.place :: PVInstance | Attachment
			else getPromptParent(self, parent)
	end

	self:SetProperties(properties)
end

local function bindProperties(self: Interaction): ()
	local scope = Fusion:scoped()
	self:AddTask(scope, "doCleanup", "BindProperties")
	scope:Hydrate(self._proximityPrompt)((self._properties :: unknown) :: Fusion.PropertyTable)

	-- Hydrate always adopts its target into the scope. The prompt belongs to the
	-- janitor, so leaving it there would destroy it on the next rebind.
	local index = assert(table.find(scope, self._proximityPrompt), "Hydrate did not adopt the prompt into its scope")
	table.remove(scope, index)
end

--------------------------------------------------------------------------------
--// Constructor //--
--------------------------------------------------------------------------------

function InteractionStatic.new(props: InteractionProps): Interaction
	local base = (BaseObject.new() :: unknown) :: { [string]: unknown }
	local self = (setmetatable(base, Interaction) :: unknown) :: Interaction

	self._instantActivation = props.InstantActivation
	self._onActivated = props.OnActivated
	self._occupied = false
	self._enabledBeforeOccupy = true

	-- Forwarded key by key rather than cloned-and-stripped: InstantActivation and
	-- OnActivated configure the Interaction, and Hydrate would try to write them
	-- onto the prompt.
	createPrompt(self, {
		ActionText = props.ActionText,
		MaxActivationDistance = props.MaxActivationDistance,
		ObjectText = props.ObjectText,
		Parent = props.Parent,
		RequiresLineOfSight = props.RequiresLineOfSight,
	})

	return self
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function Interaction.UpdateProperties(self: Interaction, properties: PromptPropertyUpdate): ()
	local ownProperties = asPropertyBag(self._properties)
	for property, value in asPropertyBag(properties) do
		ownProperties[property] = value
	end

	bindProperties(self)
end

function Interaction.SetProperties(self: Interaction, properties: PromptProperties): ()
	-- Defaults land on our own copy: the caller keeps ownership of the table it
	-- passed, and a value it did supply is never replaced by a default.
	local ownProperties = table.clone(properties)
	local bag = asPropertyBag(ownProperties)
	for property, value in DefaultPromptProperties do
		if bag[property] == nil then
			bag[property] = value
		end
	end

	self._properties = ownProperties
	bindProperties(self)
end

function Interaction.SetEnabled(self: Interaction, enabled: boolean): ()
	self._proximityPrompt.Enabled = enabled
end

-- BaseObject.IsA walks the metatable chain comparing ClassName, so the metatable
-- of Interaction has to BE the BaseObject class rather than wrap it.
setmetatable(Interaction, BaseObject.getBaseObjectClass())
-- Made weak only here: a module-scope setmetatable ahead of the class's own makes luau-lsp
-- drop the class's methods from `self` across the module.
setmetatable(rememberedTwins, { __mode = "k" })

return InteractionStatic
