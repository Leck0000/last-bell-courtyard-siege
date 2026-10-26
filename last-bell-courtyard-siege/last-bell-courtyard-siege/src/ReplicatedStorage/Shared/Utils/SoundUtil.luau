--!strict

--// Roblox Services //--
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

--// Constants //--
-- Hard cap so an emitter whose Sound never fires `.Ended` (a failed SoundId load,
-- a streaming gap) still cleans up. `Debris:AddItem` is the fallback that makes
-- this leak-safe: it destroys the instance after the timeout regardless of
-- whether the sound ever played. Every re-invented inline `Instance.new("Sound")`
-- helper in generated games leaked exactly here.
local MAX_EMITTER_LIFETIME = 10

-- The one group every sound this module plays is routed through. A settings
-- control is then `SoundUtil.getMasterGroup().Volume = value` — one write that
-- covers sounds created before AND after it runs.
--
-- Without it there is nothing in the place to set, and every generated volume
-- control has to invent its own mechanism. All three that tried in the
-- 2026-08-21 evaluation invented a broken one: a `SoundService:GetDescendants()`
-- sweep over a container that is empty (sounds live under Workspace emitters,
-- not under SoundService) and would in any case miss every sound created after
-- it ran; a `_targetVolume` computed and then discarded; and a literal
-- `SoundService.AmbientReverb = SoundService.AmbientReverb -- harmless touch`.
local MASTER_GROUP_NAME = "Master"

--// Types //--
export type PlayOptions = {
	volume: number?,
	playbackSpeed: number?,
	parent: Instance?,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local SoundUtil = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

-- Bound the cleanup timeout by the known sound length when it's already loaded,
-- else fall back to the hard cap. `TimeLength` is 0 until the asset loads, so at
-- call time this is almost always the cap — which is the point (never wait on a
-- load that may fail).
local function cleanupLifetime(sound: Sound): number
	if sound.TimeLength > 0 then
		return math.min(sound.TimeLength + 1, MAX_EMITTER_LIFETIME)
	end
	return MAX_EMITTER_LIFETIME
end

local cachedMaster: SoundGroup? = nil

-- Resolve the master group, creating it once. Cached, but the cache is
-- re-validated against `.Parent` rather than trusted: a group destroyed by game
-- code (or never re-created after a soft reload) would otherwise leave every
-- later sound assigned to an orphan and silently outside the volume control.
--
-- `FindFirstChild` before `Instance.new` so two callers racing on first use —
-- or a game that pre-authored the group in its own tree — converge on ONE
-- group. Two groups named Master would split the routing, which is the same
-- desync shape as the two independent `isMuted` stores two evaluated games
-- shipped.
local function getMasterGroup(): SoundGroup
	local cached = cachedMaster
	if cached and cached.Parent then
		return cached
	end

	local existing = SoundService:FindFirstChild(MASTER_GROUP_NAME)
	if existing and existing:IsA("SoundGroup") then
		cachedMaster = existing
		return existing
	end

	local group = Instance.new("SoundGroup")
	group.Name = MASTER_GROUP_NAME
	group.Volume = 1
	group.Parent = SoundService
	cachedMaster = group
	return group
end

-- Applied by BOTH `playAt` and `playOn`, which is what makes the routing total.
-- Assigning the group in one of them would leave the other's sounds ungrouped
-- and the volume control half-working — worse than not working, because it
-- looks wired.
local function applyOptions(sound: Sound, options: PlayOptions?)
	local opts: PlayOptions = options or {}
	sound.Volume = opts.volume or 0.5
	sound.PlaybackSpeed = opts.playbackSpeed or 1
	sound.SoundGroup = getMasterGroup()
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--- The master `SoundGroup` every sound this module plays is routed through,
--- created under `SoundService` on first use.
---
--- This is the seam a settings control writes: `getMasterGroup().Volume = v`
--- affects every sound already playing and every sound created later. Do NOT
--- sweep `SoundService:GetDescendants()` — the sounds are parented to their
--- emitters, not to the service, and a sweep is a snapshot that misses
--- everything created after it.
function SoundUtil.getMasterGroup(): SoundGroup
	return getMasterGroup()
end

--- Play a one-shot sound at a world position. Creates a temporary anchored,
--- non-colliding, invisible emitter Part, plays the sound, and ALWAYS cleans up:
--- `.Ended` destroys it early on normal completion, and `Debris:AddItem` is the
--- fallback so a failed SoundId load (where `.Ended` never fires) cannot leak the
--- emitter. Returns the Sound so callers can inspect / connect to it.
function SoundUtil.playAt(soundId: string, position: Vector3, options: PlayOptions?): Sound
	local opts: PlayOptions = options or {}

	local emitter = Instance.new("Part")
	emitter.Name = "SoundEmitter"
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.CanTouch = false
	emitter.Transparency = 1
	emitter.Size = Vector3.one * 0.1
	emitter.Position = position

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	applyOptions(sound, opts)
	sound.Parent = emitter

	emitter.Parent = opts.parent or Workspace

	-- Register the fallback BEFORE Play so even an immediate load failure is
	-- bounded.
	Debris:AddItem(emitter, cleanupLifetime(sound))
	sound.Ended:Connect(function()
		emitter:Destroy()
	end)
	sound:Play()

	return sound
end

--- Play a one-shot sound parented to an existing instance (no temporary emitter).
--- The Sound is destroyed on `.Ended`, and `Debris:AddItem` is the fallback so a
--- failed load cannot leak it.
function SoundUtil.playOn(target: Instance, soundId: string, options: PlayOptions?): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	applyOptions(sound, options)
	sound.Parent = target

	Debris:AddItem(sound, cleanupLifetime(sound))
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	sound:Play()

	return sound
end

return table.freeze(SoundUtil)
