--!strict
local State = {}
export type Snapshot = {
	mode: string, phase: string, day: number, seconds: number, nights: number,
	outcome: string, roof: boolean, provisioned: boolean, evac: string,
	hunger: number, thirst: number, infection: number, downed: boolean, revive: number,
	inventory: { [string]: number }, feedback: string, success: boolean, noise: string, assembly: string,
}
export type Event = {
	kind: string, phase: string?, day: number?, seconds: number?, nights: number?,
	outcome: string?, roof: boolean?, provisioned: boolean?, evac: string?,
	hunger: number?, thirst: number?, infection: number?, downed: boolean?, revive: number?,
	item: string?, count: number?, message: string?, success: boolean?, cue: string?, assembly: string?,
}
function State.initial(): Snapshot
	return { mode = "Scavenging", phase = "Day", day = 1, seconds = 300, nights = 0,
		outcome = "Active", roof = false, provisioned = false, evac = "Unrequested",
		hunger = 100, thirst = 100, infection = 0, downed = false, revive = 0,
		inventory = {}, feedback = "Search costs time and noise. Craft at physical stations.",
		success = true, noise = "Noise draws patrols — move carefully.", assembly = "Squad location pending" }
end
local function mode(s: Snapshot): string
	if s.outcome ~= "Active" and s.outcome ~= "" then return "Result" end
	if s.downed then return "Downed" end
	if s.nights >= 10 then return "Evacuating" end
	if s.phase == "Night" then return "Defending" end
	return "Scavenging"
end
function State.transition(previous: Snapshot, e: Event): Snapshot
	local s = table.clone(previous)
	s.inventory = table.clone(previous.inventory)
	if e.kind == "Session" then
		if e.phase ~= nil then s.phase = e.phase end
		if e.day ~= nil then s.day = e.day end
		if e.seconds ~= nil then s.seconds = math.max(0, e.seconds) end
		if e.nights ~= nil then s.nights = e.nights end
		if e.outcome ~= nil then s.outcome = e.outcome end
		if e.roof ~= nil then s.roof = e.roof end
		if e.provisioned ~= nil then s.provisioned = e.provisioned end
	elseif e.kind == "Evac" then
		if e.evac ~= nil then s.evac = e.evac end
	elseif e.kind == "Survival" then
		if e.hunger ~= nil then s.hunger = math.clamp(e.hunger, 0, 100) end
		if e.thirst ~= nil then s.thirst = math.clamp(e.thirst, 0, 100) end
		if e.infection ~= nil then s.infection = math.clamp(e.infection, 0, 100) end
		if e.downed ~= nil then s.downed = e.downed end
		if e.revive ~= nil then s.revive = math.max(0, e.revive) end
	elseif e.kind == "Inventory" and e.item ~= nil and e.count ~= nil then
		s.inventory[e.item] = math.max(0, math.floor(e.count))
	elseif e.kind == "Feedback" then
		s.feedback = e.message or ""
		s.success = e.success == true
	elseif e.kind == "Assembly" and e.assembly ~= nil then
		s.assembly = e.assembly
	elseif e.kind == "Cue" and e.cue ~= nil then
		s.noise = "NOISE / " .. e.cue .. " — patrols may investigate."
	end
	s.mode = mode(s)
	return s
end
function State.clock(seconds: number): string
	local n = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", math.floor(n / 60), n % 60)
end
State.previews = {
	Scavenging = State.transition(State.initial(), { kind = "Inventory", item = "Scrap", count = 12 }),
	Defending = State.transition(State.initial(), { kind = "Session", phase = "Night", day = 5, nights = 4, seconds = 178 }),
	Downed = State.transition(State.initial(), { kind = "Survival", downed = true, revive = 24, hunger = 31, thirst = 46, infection = 62 }),
	Evacuating = State.transition(State.initial(), { kind = "Session", nights = 10, roof = true, provisioned = true, seconds = 90 }),
	Result = State.transition(State.initial(), { kind = "Session", outcome = "Evacuated", nights = 10, seconds = 18 }),
}
return table.freeze(State)
