local abbreviations = {
	"",
	"K",
	"M",
	"B",
	"T",
	"QA",
	"QI",
	"SX",
	"SP",
	"OC",
	"NO",
	"DC",
	"UD",
	"DD",
	"TD",
	"QAD",
	"QID",
	"SXD",
	"SPD",
	"OCD",
	"NOD",
	"VG",
	"UVG",
}

local NumberFormatter = {}

function NumberFormatter.ClampFloat(num: number, decimalsAmount: number?): number
	if not decimalsAmount then
		decimalsAmount = 2
	end

	return tonumber((`%.0{decimalsAmount}f`):format(tostring(num))) :: number
end

function NumberFormatter.GenericFormat(num: number): string
	local numFloored = math.floor(num)
	local numLength = string.len(tostring(numFloored))
	local abbreviationIndex = (numLength - 1) // 3 + 1
	local mainPart = string.sub(tostring(numFloored), 1, (numLength - 1) % 3 + 1)

	-- Calculate the decimal part
	local decimalPart = ""
	if abbreviationIndex > 1 then
		local scaleFactor = 10 ^ ((abbreviationIndex - 1) * 3)
		local decimalNum = (num / scaleFactor) % 1
		decimalPart = string.format("%.2f", decimalNum):gsub("%.00$", "")
		if decimalPart == "0.00" then
			decimalPart = ""
		else
			decimalPart = decimalPart:sub(2)
		end
	end

	return mainPart .. decimalPart .. abbreviations[abbreviationIndex]
end

return NumberFormatter
