export type CollisionGroup = "Default" | "Player" | "Mob"
local CollisionGroup = {
 Mob = "Mob",
	Default = "Default",
	Player = "Player",
}
return table.freeze(CollisionGroup)
