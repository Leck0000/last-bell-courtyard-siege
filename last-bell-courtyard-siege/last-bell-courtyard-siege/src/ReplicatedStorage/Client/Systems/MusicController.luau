--// Roblox Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local Workspace = game:GetService("Workspace")

--// Dependencies //--
local CustomEnums = require(ReplicatedStorage.Shared.CustomEnums.CustomEnums)

--// Packages //--
local Signal = require(ReplicatedStorage.Packages.Signal)
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Sift = require(ReplicatedStorage.Packages.Sift)

--// Constants //--
local MUSIC_METADATA: { [CustomEnums.MusicType]: CustomEnums.MusicData } = CustomEnums.MusicType.__METADATA
local DEFAULT_FADE_DURATION = 0.5
local DEFAULT_VOLUME = 0.5
local RNG = Random.new()

--// References //--
local scope = Fusion:scoped()
local VolumeTweenInfo: Fusion.Value<TweenInfo> =
	scope:Value(TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
local MasterVolume: Fusion.Value<number> = scope:Value(DEFAULT_VOLUME)
local VolumeFactor: Fusion.Value<number> = scope:Value(1)
local AudioPlayer = scope:New("AudioPlayer")({
	Parent = Workspace,
	Looping = true,
	Volume = scope:Tween(
		scope:Computed(function(use)
			return use(MasterVolume) * use(VolumeFactor)
		end),
		VolumeTweenInfo
	),
}) :: AudioPlayer
do
	local AudioListener = scope:New("AudioListener")({
		Parent = Workspace.CurrentCamera,
	})
	local AudioDeviceOutput = scope:New("AudioDeviceOutput")({
		Parent = AudioListener,
	})
	scope:New("Wire")({
		Parent = AudioDeviceOutput,
		TargetInstance = AudioDeviceOutput,
		SourceInstance = AudioPlayer,
	})
end
local endedConnection: RBXScriptConnection? = nil
local currentMusicType: CustomEnums.MusicType? = nil
-- Set the moment a pause fade starts and cleared the moment playback is asked
-- for again. The fade's deferred stop reads it, so a `Play` or `Resume` that
-- lands mid-fade cancels that stop instead of losing the track it just started.
local isPaused = false

--------------------------------------------------------------------------------
--// Controller //--
--------------------------------------------------------------------------------

local MusicController = {
	Ended = Signal.new(),
}
type MusicController = typeof(MusicController)

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

local function registerSong(musicType: CustomEnums.MusicType): ()
	local musicData = MUSIC_METADATA[musicType]
	if musicData.DecryptionKey then
		ContentProvider:RegisterEncryptedAsset("rbxassetid://" .. musicData.SoundId, musicData.DecryptionKey)
	end
end

local function getBackgroundMusic(prevMusicType: CustomEnums.MusicType?): CustomEnums.MusicType?
	-- `Sift.Dictionary.keys` infers its key generic from the indexer, and the old
	-- solver widens each option of a singleton-string union back to `string`, so the
	-- result needs re-narrowing to the enum it was built from.
	local musicTypes = Sift.Dictionary.keys(Sift.Dictionary.filter(MUSIC_METADATA, function(value)
		return value.IsBackgroundMusic
	end)) :: { CustomEnums.MusicType }

	if #musicTypes == 0 then
		warn("No songs to choose from")
		return
	end

	if #musicTypes == 1 then
		return musicTypes[1]
	end

	local musicType: CustomEnums.MusicType
	repeat
		musicType = musicTypes[RNG:NextInteger(1, #musicTypes)]
	until musicType ~= prevMusicType

	return musicType
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function MusicController.GetAudioPlayer(self: MusicController): AudioPlayer
	return AudioPlayer
end

function MusicController.Play(
	self: MusicController,
	musicType: CustomEnums.MusicType,
	fadeDuration: number?,
	yieldUntilStart: boolean?
): ()
	local musicData = MUSIC_METADATA[musicType]
	if not musicData then
		return
	end

	currentMusicType = musicType
	isPaused = false

	VolumeTweenInfo:set(
		TweenInfo.new(fadeDuration or DEFAULT_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	)
	VolumeFactor:set(musicData.VolumeFactor or 1)

	AudioPlayer.TimePosition = 0
	AudioPlayer.Asset = "rbxassetid://" .. musicData.SoundId
	AudioPlayer:Play()

	if yieldUntilStart then
		while AudioPlayer.TimePosition <= 0 do
			task.wait()
			AudioPlayer.TimePosition = 0
		end
	end

	endedConnection = endedConnection and endedConnection:Disconnect()
	endedConnection = AudioPlayer.Ended:Connect(function(): ()
		endedConnection = endedConnection and endedConnection:Disconnect()
		self.Ended:Fire()
	end)
end

function MusicController.Pause(self: MusicController, fadeDuration: number?, callback: (() -> ())?): ()
	if not AudioPlayer.IsPlaying then
		return
	end

	isPaused = true
	VolumeTweenInfo:set(
		TweenInfo.new(fadeDuration or DEFAULT_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	)
	VolumeFactor:set(0)
	task.delay(fadeDuration or DEFAULT_FADE_DURATION, function(): ()
		if not isPaused then
			return
		end

		AudioPlayer:Stop()
		if callback then
			callback()
		end
	end)
end

function MusicController.Stop(self: MusicController, fadeDuration: number?, callback: (() -> ())?): ()
	endedConnection = endedConnection and endedConnection:Disconnect()
	self:Pause(fadeDuration or DEFAULT_FADE_DURATION, function(): ()
		self.Ended:Fire()
		if callback then
			callback()
		end
	end)
end

function MusicController.Resume(self: MusicController, fadeDuration: number?): ()
	if not isPaused and AudioPlayer.IsPlaying then
		return
	end

	isPaused = false

	local volumeFactor = 1
	if currentMusicType then
		volumeFactor = MUSIC_METADATA[currentMusicType].VolumeFactor or 1
	end

	VolumeTweenInfo:set(
		TweenInfo.new(fadeDuration or DEFAULT_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	)
	VolumeFactor:set(volumeFactor)
	AudioPlayer:Play()
end

function MusicController.SetVolume(self: MusicController, volume: number): ()
	MasterVolume:set(volume)
end

function MusicController.ResetVolume(self: MusicController): ()
	MasterVolume:set(DEFAULT_VOLUME)
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

function MusicController.Start(self: MusicController): ()
	local prevMusicType: CustomEnums.MusicType?
	local musicType: CustomEnums.MusicType? = getBackgroundMusic(prevMusicType)
	if musicType then
		prevMusicType = musicType
		self:Play(musicType)
	end

	self.Ended:Connect(function(): ()
		musicType = getBackgroundMusic(prevMusicType)
		prevMusicType = musicType
		if musicType then
			self:Play(musicType)
		end
	end)
end

do
	for musicType: CustomEnums.MusicType in MUSIC_METADATA do
		registerSong(musicType)
	end
end

return MusicController
