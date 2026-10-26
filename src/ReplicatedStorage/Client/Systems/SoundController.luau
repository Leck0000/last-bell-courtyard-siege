--// Services //--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Constants //--
local ActiveSoundsFolder = ReplicatedStorage:FindFirstChild("ActiveSounds")
if not ActiveSoundsFolder then
	ActiveSoundsFolder = Instance.new("Folder")
	ActiveSoundsFolder.Name = "ActiveSounds"
	ActiveSoundsFolder.Parent = ReplicatedStorage
end

--------------------------------------------------------------------------------
--// Controller //--
--------------------------------------------------------------------------------

local SoundController = {}

--------------------------------------------------------------------------------
--// Private Functions //--
--------------------------------------------------------------------------------

--- Sounds hang off `Shared`, never the ReplicatedStorage root, and are resolved per call
--- rather than at module scope: the template mounts an EMPTY `src/Shared/Assets`, so
--- indexing `Sounds` while being required took this controller down in any game that
--- ships no sounds.
local function getSoundContainer(): Instance?
	local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
	if not sharedFolder then
		return nil
	end
	local assets = sharedFolder:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	return assets:FindFirstChild("Sounds")
end

local function debug(...): ()
	if RunService:IsStudio() then
		warn(...)
	end
end

local function CreatePart(position: Vector3): Part
	local part = Instance.new("Part")
	part.Transparency = 1
	part.CanCollide = false
	part.Anchored = true
	part.Position = position
	part.Parent = Workspace
	return part
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

function SoundController.PlaySound(
	self: SoundController,
	soundId: string,
	randomize: boolean?,
	playbackSpeed: number?
): Sound?
	assert(soundId, "SoundId is required")
	local soundContainer = getSoundContainer()
	local template = soundContainer and soundContainer:FindFirstChild(soundId)
	if not template or not template:IsA("Sound") then
		debug("SoundId not found in SoundContainer")
		return
	end

	local sound = template:Clone()
	sound.Parent = ActiveSoundsFolder

	if randomize then
		local randomValue = sound.PlaybackSpeed - math.random(-2, 2) / 10
		sound.PlaybackSpeed = randomValue
	elseif playbackSpeed then
		sound.PlaybackSpeed = playbackSpeed
	end

	sound:Play()

	sound.Ended:Connect(function()
		sound:Destroy()
	end)

	return sound
end

function SoundController.PlayAtPosition(
	self: SoundController,
	soundId: string,
	position: Vector3,
	randomize: boolean?,
	playbackSpeed: number?
): Sound?
	assert(soundId, "SoundId is required")
	local soundContainer = getSoundContainer()
	local template = soundContainer and soundContainer:FindFirstChild(soundId)
	if not template or not template:IsA("Sound") then
		debug("SoundId not found in SoundContainer")
		return
	end

	local sound = template:Clone()
	local positionPart = CreatePart(position)
	sound.Parent = positionPart

	if randomize then
		local randomValue = sound.PlaybackSpeed - math.random(-2, 2) / 10
		sound.PlaybackSpeed = randomValue
	elseif playbackSpeed then
		sound.PlaybackSpeed = playbackSpeed
	end

	sound:Play()
	sound.Ended:Connect(function()
		positionPart:Destroy()
	end)

	return sound
end

export type SoundController = typeof(SoundController)

return SoundController
