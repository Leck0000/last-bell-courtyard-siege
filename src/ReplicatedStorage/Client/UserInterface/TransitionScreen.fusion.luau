--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

--// Dependencies //--
local Fusion = require(ReplicatedStorage.Packages.Fusion)

--// Constants //--
local DEFAULT_TRANSITION_TIME = 0.4
local PLAYER_GUI_TIMEOUT = 5
local NO_HOST_ERR = "TransitionScreen: no Parent was given and there is no LocalPlayer to host the screen on."
local NO_PLAYER_GUI_ERR = "TransitionScreen: the LocalPlayer has no PlayerGui to host the screen on."

local Children = Fusion.Children

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

--[[
	Runs the caller's callback and hands back what it raised, or nil. Called rather
	than raised on the wipe thread: the rest of that thread is what lifts the screen
	again, so a callback that raised took the lift with it and left an opaque black
	frame standing for the rest of the session.

	The inner wrapper declares a return because `pcall` is typed to hand back exactly
	what its function returns, and a `() -> ()` callback leaves nowhere for the error
	to arrive in.
]]
local function runCallback(callback: () -> ()): string?
	local _ok, failure = pcall(function(): string?
		callback()
		return nil
	end)

	return failure
end

--------------------------------------------------------------------------------
--// Main Component //--
--------------------------------------------------------------------------------

type TransitionScreenProps = {
	TransitionCallback: (() -> ())?,
	TimeUntilCleanup: number?,
	TransitionTime: number?,
	Parent: Instance?,
	Scope: Fusion.Scope<typeof(Fusion)>?,
}

return function(props: TransitionScreenProps): ()
	local TimeUntilCleanup = props.TimeUntilCleanup or 0
	local TransitionTime = props.TransitionTime or DEFAULT_TRANSITION_TIME
	local scope: Fusion.Scope<typeof(Fusion)> = if props.Scope then props.Scope:innerScope() else Fusion:scoped()

	-- A local, not `props.Parent`: the props table belongs to the caller, and
	-- writing the screen back into it lost the caller its own nil on every reuse.
	local parent = props.Parent
	if not parent then
		local localPlayer = Players.LocalPlayer
		assert(localPlayer, NO_HOST_ERR)

		-- Bounded, and named when it runs out. The pre-migration lookup was the
		-- non-yielding `Players.LocalPlayer.PlayerGui`; an unbounded WaitForChild
		-- turns "there is no PlayerGui" from an error into a caller parked forever.
		-- A PlayerGui that is already there costs no yield at all.
		local playerGui = localPlayer:WaitForChild("PlayerGui", PLAYER_GUI_TIMEOUT)
		assert(playerGui, NO_PLAYER_GUI_ERR)

		parent = scope:New("ScreenGui")({
			Name = "TransitionScreen",
			Parent = playerGui,
			ScreenInsets = Enum.ScreenInsets.None,
			ClipToDeviceSafeArea = false,
			ResetOnSpawn = false,
			DisplayOrder = 99,
		})
	end

	-- Held rather than looked up again by name. The wipe used to re-find both of
	-- these with FindFirstChild and give up silently when the search missed, which
	-- skipped the caller's TransitionCallback and left the black frame standing.
	local uiGradient = scope:New("UIGradient")({
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.001, 0),
			NumberSequenceKeypoint.new(0.999, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Color = ColorSequence.new(Color3.fromRGB(0, 0, 0)),
		Rotation = 45,
		Offset = Vector2.new(1, 0),
	})

	scope:New("Frame")({
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(2, 2),
		Parent = parent,
		[Children] = { uiGradient },
	})

	local thread = task.spawn(function(): ()
		TweenService:Create(
			uiGradient,
			TweenInfo.new(TransitionTime, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
			{ Offset = Vector2.new(0, 0) }
		):Play()
		task.wait(TransitionTime)

		local transitionCallback = props.TransitionCallback
		if transitionCallback then
			local failure = runCallback(transitionCallback)
			if failure then
				warn(failure)
			end
		end

		task.wait(TimeUntilCleanup)
		TweenService:Create(
			uiGradient,
			TweenInfo.new(TransitionTime, Enum.EasingStyle.Cubic, Enum.EasingDirection.In),
			{ Offset = Vector2.new(-1, 0) }
		):Play()
		task.wait(TransitionTime)
		scope:doCleanup()
	end)

	table.insert(scope, function(): ()
		-- Deferred, because the thread cleans its own scope on the way out and a
		-- coroutine cannot cancel itself. Wrapped in a closure rather than passed as
		-- defer arguments so that the guard has somewhere to live.
		task.defer(function(): ()
			if coroutine.status(thread) ~= "dead" then
				task.cancel(thread)
			end
		end)
	end)
end
