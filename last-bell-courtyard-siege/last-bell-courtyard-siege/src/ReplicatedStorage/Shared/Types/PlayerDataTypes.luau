export type SharedLeaf = boolean | number | string
export type PlayerDataValue = SharedLeaf | PlayerData | { SharedLeaf }
export type PlayerData = { [string]: PlayerDataValue }

export type ProfileTemplate = {
	Shared: PlayerData,
	Server: PlayerData,
	Version: number,
}

export type DataConfigTemplate = {
	Server: PlayerData,
	Version: number,
}

export type PlayerDataConfig = {
	ProfileStoreName: string,
	ProfileTemplate: DataConfigTemplate,
	Leaderboard: { LeaderboardData },
	Migrator: { DataMigrator },
	Debug: boolean,
}

export type LeaderboardData = {
	Formatter: (number) -> string,
	DisplayName: string,
	IsPrimary: boolean,
	DataKey: string,
}

export type DataMigrator = {
	ToVersion: number,
	Migrate: (Player, PlayerData) -> PlayerData,
}

export type GlobalUpdates = {
	GetActiveUpdates: (GlobalUpdates) -> { { string } },
	GetLockedUpdates: (GlobalUpdates) -> { { string } },
	ListenToNewActiveUpdate: (GlobalUpdates, (number, unknown) -> ()) -> RBXScriptConnection,
	ListenToNewLockedUpdate: (GlobalUpdates, (number, unknown) -> ()) -> RBXScriptConnection,
	LockActiveUpdate: (GlobalUpdates, number) -> (),
	ClearLockedUpdate: (GlobalUpdates, number) -> (),
}

export type ProfileStore = {
	LoadProfileAsync: (ProfileStore, string, LoadType | (number | nil, string | nil) -> LoadType) -> Profile,
	GlobalUpdateProfileAsync: (ProfileStore, string, (GlobalUpdates) -> ()) -> GlobalUpdates | nil,
	ViewProfileAsync: (ProfileStore, string, nil | string) -> Profile | nil,
	ProfileVersionQuery: (
		ProfileStore,
		string,
		nil | Enum.SortDirection,
		nil | DateTime | number,
		nil | DateTime | number
	) -> Profile,
	WipeProfileAsync: (ProfileStore, string) -> boolean,
	Mock: ProfileStore,
}

export type Profile = {
	Data: PlayerData,
	MetaData: {
		ProfileCreateTime: number,
		SessionLoadCount: number,
		ActiveSession: number,
		MetaTags: { [string]: unknown },
		MetaTagsLatest: { [string]: unknown },
	},
	MetaTagsUpdated: RBXScriptSignal,
	RobloxMetaData: { [string]: unknown },
	UserIds: { number },
	KeyInfo: DataStoreKeyInfo,
	KeyInfoUpdated: RBXScriptSignal,
	GlobalUpdates: GlobalUpdates,
	IsActive: (Profile) -> boolean,
	GetMetaTag: (Profile, string) -> unknown,
	Reconcile: (Profile) -> (),
	ListenToRelease: (Profile, (number | nil, string | nil) -> ()) -> RBXScriptConnection,
	Release: (Profile) -> (),
	ListenToHopReady: (Profile, () -> ()) -> RBXScriptConnection,
	AddUserId: (Profile, number) -> (),
	RemoveUserId: (Profile, number) -> (),
	Identify: (Profile) -> string,
	SetMetaTag: (Profile, string, unknown) -> (),
	Save: (Profile) -> (),
	ClearGlobalUpdates: (Profile) -> (),
	OverwriteAsync: (Profile) -> (),
}

export type LoadType = "Repeat" | "Cancel" | "ForceLoad" | "Steal"

return nil
