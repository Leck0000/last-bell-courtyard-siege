--!strict
export type MobType = "Student" | "Athlete" | "Staff" | "Brute"
export type MobData = { DisplayName: string, RespawnDelay: number?, Health: number }
local MobType = { Student = "Student" :: MobType, Athlete = "Athlete" :: MobType, Staff = "Staff" :: MobType, Brute = "Brute" :: MobType }
MobType.__METADATA = {
 Student = { DisplayName = "Student", Health = 60 },
 Athlete = { DisplayName = "Athlete", Health = 90 },
 Staff = { DisplayName = "Cafeteria Staff", Health = 70 },
 Brute = { DisplayName = "Teacher Brute", Health = 500 },
} :: { [MobType]: MobData }
return table.freeze(MobType)
