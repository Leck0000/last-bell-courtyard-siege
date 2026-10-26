--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Packages //--
local BaseComponent = require(ReplicatedStorage.Packages.BaseComponent)
local Component = require(ReplicatedStorage.Packages.Component)
local Promise = require(ReplicatedStorage.Packages.Promise)

--// Types //--
type AnimationEntry = {
	Animation: Animation,
	Looped: boolean?,
	Weight: number?,
}

--[[
	Everything the extension keeps per component, held in one record rather than in
	several slots on the component object: a component object carries a single
	indexer type, so differently-typed slots collapse into one another and every
	read of one of them is then reported against the type of the last.
]]
type AnimationLoaderState = {
	Tracks: { [string]: AnimationTrack },
	Weights: { [string]: number? },
}

type AnimationLoaderExtensionData = {
	Animations: { [string]: AnimationEntry }?,
	IdleAnimations: { string }?,
	RandomAnimations: { string }?,
}

--[[
	BaseComponent is named here even though this extension does not list it: the
	loaded tracks are parked with `self:AddTask`, which BaseComponent contributes.

	`AnimationLoaderExtension` itself is NOT named here, and the alias is declared
	ahead of the functions that use it. Naming it would close a cycle — the table
	carries `Starting`, whose receiver is this alias — and Luau breaks that cycle by
	dropping the intersection down to `Component.ComponentObject`, at which point
	`AddTask` and the declared animation fields both stop resolving.
]]
type ComponentObject =
	Component.ComponentObject
	& typeof(Component.getExtensionsType(BaseComponent))
	& AnimationLoaderExtensionData

--[[
	Keyed on the component object rather than parked on it under a symbol: writing a
	symbol slot onto the object is not expressible against its metatable type, and
	`Stopped` below is what keeps this table from outliving the components.
]]
local stateByComponent: { [Component.ComponentObject]: AnimationLoaderState } = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function getState(self: Component.ComponentObject): AnimationLoaderState
	local state = stateByComponent[self]
	assert(state, "AnimationLoaderExtension: animation state read before Starting, or after Stopped.")
	return state
end

local function preloadAnimations(self: ComponentObject): ()
	-- Before the early return: `GetAnimationTrack` and the idle loop both index this
	-- table, and a component with no `Animations` still runs them.
	local state: AnimationLoaderState = { Tracks = {}, Weights = {} }
	stateByComponent[self] = state

	-- The emptiness test as well as the nil one: an empty table declares no
	-- animations, so there is nothing to load and no Animator to require. The
	-- pre-migration code reached the Animator only from inside the loop, so a
	-- component that declared `Animations = {}` alongside no Animator started fine;
	-- with the Animator required above the loop it stopped starting at all.
	local animations: { [string]: AnimationEntry }? = self.Animations
	if not animations or next(animations) == nil then
		return
	end

	local instance = self.Instance
	local animator = instance:FindFirstChildWhichIsA("Animator", true)
	assert(animator, `AnimationLoaderExtension: {instance:GetFullName()} has no Animator to load animations on.`)

	for animName, animData in animations do
		local animationTrack = animator:LoadAnimation(animData.Animation)
		animationTrack.Looped = animData.Looped or false
		state.Tracks[animName] = animationTrack
		state.Weights[animName] = animData.Weight
		self:AddTask(animationTrack)
	end
end

--[[
	The track a component declared under `Animations`. Named here so a name that is
	not declared reports itself rather than failing as an index of nil, three call
	sites down.
]]
local function requireAnimationTrack(self: Component.ComponentObject, animName: string): AnimationTrack
	local animTrack: AnimationTrack? = getState(self).Tracks[animName]
	assert(animTrack, `AnimationLoaderExtension: no animation named "{animName}" is declared.`)
	return animTrack
end

--[[
	Every play goes through here so the declared Weight survives. `Play` resets the
	weight to 1 whenever it is not told otherwise, so an `AdjustWeight` at load time
	is undone by the first play — which is what used to happen.
]]
local function playTrack(self: Component.ComponentObject, animName: string, fadeTime: number?): AnimationTrack
	local animTrack = requireAnimationTrack(self, animName)
	animTrack:Play(fadeTime, getState(self).Weights[animName])
	return animTrack
end

local function playIdleAnimations(self: ComponentObject): ()
	local animList: { string }? = self.IdleAnimations
	if not animList then
		return
	end

	for _, animName in animList do
		playTrack(self, animName)
	end
end

local function playRandomAnimations(self: ComponentObject): ()
	local animList: { string }? = self.RandomAnimations
	if not animList then
		return
	end

	if next(animList) == nil then
		return
	end

	local rnd = Random.new()

	self:AddTask(task.spawn(function(): ()
		while true do
			local animName = animList[math.random(1, #animList)]
			local animTrack = playTrack(self, animName)
			animTrack.Stopped:Wait()
			task.wait(rnd:NextNumber(0.5, 1.2))
		end
	end))
end

--------------------------------------------------------------------------------
--// Extension Methods //--
--------------------------------------------------------------------------------

local function GetAnimationTrack(self: Component.ComponentObject, animName: string): AnimationTrack?
	return getState(self).Tracks[animName]
end

local function PlayAnimation(self: Component.ComponentObject, animName: string): Promise.TypedPromise<()>
	return Promise.try(function(): ()
		local animTrack = requireAnimationTrack(self, animName)

		if animTrack.Looped then
			-- A looped track never reaches `Stopped` on its own, so waiting on one
			-- would leave the promise pending for the life of the component. Both
			-- looped branches settle immediately; only the idle one has to start it.
			if not animTrack.IsPlaying then
				playTrack(self, animName, 0)
			end

			return
		end

		if animTrack.IsPlaying then
			animTrack:Stop(0)
		end

		playTrack(self, animName, 0)
		animTrack.Stopped:Wait()
	end)
end

local function StopAnimation(self: Component.ComponentObject, animName: string): Promise.TypedPromise<()>
	return Promise.try(function(): ()
		requireAnimationTrack(self, animName):Stop(0)
	end)
end

--------------------------------------------------------------------------------
--// Extension Declaration //--
--------------------------------------------------------------------------------

local AnimationLoaderExtension = {}
AnimationLoaderExtension.ClassName = "AnimationLoader"
local Methods = {
	GetAnimationTrack = GetAnimationTrack,
	PlayAnimation = PlayAnimation,
	StopAnimation = StopAnimation,
}
AnimationLoaderExtension.Methods = Methods :: AnimationLoaderExtensionData & typeof(Methods)

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function AnimationLoaderExtension.Starting(self: ComponentObject): ()
	preloadAnimations(self)
	playIdleAnimations(self)
	playRandomAnimations(self)
end

--[[
	The state table is this module's own, so nothing else drops it: without this a
	long-lived server keeps one record — and its track map — per component that has
	ever started.
]]
function AnimationLoaderExtension.Stopped(self: ComponentObject): ()
	stateByComponent[self] = nil
end

return AnimationLoaderExtension
