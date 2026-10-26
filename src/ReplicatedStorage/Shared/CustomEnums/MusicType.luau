--!strict
local MusicType = { SiegeScore = "SiegeScore" }
-- typeof preserves the package dictionary's string-key inference with one slot.
export type MusicType = typeof(MusicType.SiegeScore)
export type MusicData = { SoundId: number, IsBackgroundMusic: boolean?, VolumeFactor: number?, DecryptionKey: string? }
local metadata: { [MusicType]: MusicData } = {}
MusicType.__METADATA = table.freeze(metadata)
return table.freeze(MusicType)
