--!strict
--// Roblox Services //--
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--// Constants //--
local DEFAULT_TWEEN_DURATION = 5
local CUSTOM_ENUMS_PATH = { "Shared", "CustomEnums", "CustomEnums" }
local LIGHTING_PROFILES_PATH = { "Shared", "Configurations", "LightingProfiles" }

--// Types //--
--- What a consumer profile may hold: a scalar is written straight onto `Lighting`,
--- a nested table onto the post-processing child its ClassName key names.
type LightingPropertyValue = boolean | number | string | Color3 | EnumItem
type LightingEffectProperties = { [string]: LightingPropertyValue }
type LightingProfile = { [string]: LightingPropertyValue | LightingEffectProperties }

--// References //--
local currentProfileName: string? = nil

--- The transition in flight. A profile applied over a running one has to stop it
--- first, or the old tweens keep writing the properties the new one just set.
local activeTweens: { Tween } = {}

--------------------------------------------------------------------------------
--// Controller //--
--------------------------------------------------------------------------------

local LightingController = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

--[=[
	Walks `ReplicatedStorage` down `path`, or nil when the consumer game has not
	created that tree.

	Every segment is a FindFirstChild on purpose: a raw index throws on the
	missing segment, and the bootstrapper turns a require-time throw in any one
	controller into a failure of the whole client boot.
]=]
local function findInReplicatedStorage(path: { string }): Instance?
	local current: Instance = ReplicatedStorage
	for _, segment in path do
		local child = current:FindFirstChild(segment)
		if child == nil then
			return nil
		end

		current = child
	end

	return current
end

--[=[
	The consumer's `CustomEnums.LightingProfileName` table, or nil when the game
	ships no usable custom enums.

	`pcall(require, module)` rather than `require(module)`: the path is only known
	at runtime, and luau-lsp rejects a dynamic require expression outright.
]=]
local function findProfileNames(): { [string]: unknown }?
	local module = findInReplicatedStorage(CUSTOM_ENUMS_PATH)
	if module == nil then
		return nil
	end

	local ok, customEnums: unknown = pcall(require, module)
	if not ok or typeof(customEnums) ~= "table" then
		return nil
	end

	local names = (customEnums :: { LightingProfileName: unknown }).LightingProfileName
	if typeof(names) ~= "table" then
		return nil
	end

	return names :: { [string]: unknown }
end

--[=[
	Narrows whatever a profile module returned, or nil when it honours no contract
	this module can apply.

	No `IsA("ModuleScript")` check: `require` of anything else throws, and the
	pcall already turns that into the same nil.
]=]
local function asLightingProfile(module: Instance): LightingProfile?
	local ok, profile: unknown = pcall(require, module)
	if not ok or typeof(profile) ~= "table" then
		return nil
	end

	return profile :: LightingProfile
end

--- Luau cannot typecheck `instance[name] = value` for a name known only at
--- runtime, and profile keys are consumer data. Widening through `unknown` keeps
--- the write untyped without reaching for `any`.
local function asPropertyBag(instance: Instance): LightingEffectProperties
	return (instance :: unknown) :: LightingEffectProperties
end

--- The effect is left with the name `Instance.new` gives it, which is already its
--- ClassName — consumers reach it as `Lighting.BloomEffect` either way.
local function createPostProcessEffect(effectClassName: string): Instance
	local NewEffect = Instance.new(effectClassName)
	NewEffect.Parent = Lighting
	return NewEffect
end

local function getPostProcessingInstance(className: string): Instance
	return Lighting:FindFirstChildOfClass(className) or createPostProcessEffect(className)
end

local function stopActiveTweens(): ()
	for _, tween in activeTweens do
		tween:Cancel()
		tween:Destroy()
	end

	table.clear(activeTweens)
end

--- Profiles fully replace each other, so a Lighting child the target profile does
--- not name by ClassName goes away. The blast radius is every child of Lighting,
--- not only the effect instances this module created.
local function destroyChildrenAbsentFromProfile(profile: LightingProfile): ()
	for _, v in Lighting:GetChildren() do
		if not profile[v.ClassName] then
			v:Destroy()
		end
	end
end

local function instantEffect(profile: LightingProfile): ()
	stopActiveTweens()

	for prop, value in profile do
		if typeof(value) == "table" then -- it is a Post Processing Effect
			local EffectInstance = getPostProcessingInstance(prop)
			for ppeProperty, propertyValue in value do
				asPropertyBag(EffectInstance)[ppeProperty] = propertyValue
			end
		else
			asPropertyBag(Lighting)[prop] = value
		end
	end

	destroyChildrenAbsentFromProfile(profile)
end

local function tweenEffect(profile: LightingProfile, duration: number): ()
	stopActiveTweens()

	local LightingTweenProperties: LightingEffectProperties = {}
	local tweenInfo = TweenInfo.new(duration)

	for prop, value in profile do
		if type(value) == "table" then -- it is a Post Processing Effect
			local EffectInstance = getPostProcessingInstance(prop)
			local ObjectTweenSettings: LightingEffectProperties = {}
			for ppeProperty, propertyValue in value do
				-- Strings are asset ids and the like; TweenService rejects them.
				if type(propertyValue) == "string" then
					asPropertyBag(EffectInstance)[ppeProperty] = propertyValue
				else
					ObjectTweenSettings[ppeProperty] = propertyValue
				end
			end

			table.insert(activeTweens, TweenService:Create(EffectInstance, tweenInfo, ObjectTweenSettings))
		elseif type(value) ~= "string" then
			LightingTweenProperties[prop] = value
		else
			asPropertyBag(Lighting)[prop] = value
		end
	end

	destroyChildrenAbsentFromProfile(profile)

	table.insert(activeTweens, TweenService:Create(Lighting, tweenInfo, LightingTweenProperties))
	for _, t in activeTweens do
		t:Play()
	end
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--- The profile currently applied to Lighting, or nil before the first successful
--- `UpdateLighting`.
function LightingController.GetCurrentProfile(self: LightingController): string?
	return currentProfileName
end

function LightingController.UpdateLighting(
	self: LightingController,
	profileName: string,
	instant: boolean?,
	duration: number?
): ()
	duration = duration or DEFAULT_TWEEN_DURATION
	assert(type(profileName) == "string", "Light profile name must be a string")
	assert(type(instant) == "boolean" or instant == nil, "Instant must be a boolean")
	assert(type(duration) == "number", "Duration must be a number")

	local profileNames = findProfileNames()
	assert(profileNames ~= nil and profileNames[profileName] ~= nil, "Light profile is not valid")

	local profilesFolder = findInReplicatedStorage(LIGHTING_PROFILES_PATH)
	local ProfileModule = if profilesFolder ~= nil then profilesFolder:FindFirstChild(profileName) else nil
	if ProfileModule == nil then
		warn("LightingController:UpdateLighting() | Lighting profile does not exist!")
		return
	end

	local profile = asLightingProfile(ProfileModule)
	if profile == nil then
		warn("LightingController:UpdateLighting() | Lighting profile is not valid!")
		return
	end

	if profileName == currentProfileName then
		return
	end

	if instant then
		instantEffect(profile)
	else
		tweenEffect(profile, duration)
	end

	-- Set last: an apply that throws on consumer-authored data must leave the
	-- name retryable rather than latching a profile that is not on screen.
	currentProfileName = profileName
end

export type LightingController = typeof(LightingController)

return LightingController
