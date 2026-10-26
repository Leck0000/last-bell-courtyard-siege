export type MobStatus = "Destroyed" | "Damaged" | "Intact"
-- Annotated, not bare literals: an unannotated field widens to `string`, and
-- every consumer returning one where a MobStatus is declared then fails analysis.
local MobStatus = {
	Destroyed = "Destroyed" :: MobStatus,
	Damaged = "Damaged" :: MobStatus,
	Intact = "Intact" :: MobStatus,
}
return MobStatus
