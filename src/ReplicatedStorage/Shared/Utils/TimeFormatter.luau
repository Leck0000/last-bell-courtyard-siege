local TimeFormatter = {}

function TimeFormatter.HourMin(timeInSeconds: number, formatString: string?)
	local EPSILON = 1e-6
	timeInSeconds = math.max(0, math.floor(timeInSeconds + EPSILON)) -- floor safely
	local hour = math.floor(timeInSeconds / (60 * 60))
	local min = math.floor((timeInSeconds % (60 * 60)) / 60)

	return string.format(if formatString then formatString else "%2dH %2dM", hour, min)
end

function TimeFormatter.MinSec(timeInSeconds: number, formatString: string?)
	local EPSILON = 1e-6
	timeInSeconds = math.max(0, math.floor(timeInSeconds + EPSILON)) -- floor safely
	local min = math.floor((timeInSeconds % (60 * 60)) / 60)
	local sec = timeInSeconds % 60

	return string.format(if formatString then formatString else "%2dM %2dS", min, sec)
end

function TimeFormatter.Auto(timeInSeconds: number)
	timeInSeconds = math.max(math.ceil(timeInSeconds), 0)
	if timeInSeconds >= 60 * 60 then
		return TimeFormatter.HourMin(timeInSeconds)
	else
		return TimeFormatter.MinSec(timeInSeconds)
	end
end

return TimeFormatter
