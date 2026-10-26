type Weight = number | NumberRange | () -> number | NumberRange
export type WeightedItem<T> = {
	Weight: Weight,
	Value: T,
}

export type WeightedTable<T> = { WeightedItem<T> }

export type ProbabilityDistributor<T> = {
	new: (weights: { WeightedItem<T> }, randomOrSeed: (Random | number)?) -> ProbabilityDistributor<T>,
	Roll: (self: ProbabilityDistributor<T>, luck: number?) -> T,
}

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local ProbabilityDistributor = {}
ProbabilityDistributor.ClassName = "ProbabilityDistributor"
ProbabilityDistributor.__index = ProbabilityDistributor
ProbabilityDistributor.__call = function(t, ...): ProbabilityDistributor<any> | any
	if t == ProbabilityDistributor then
		return ProbabilityDistributor.new(...)
	end
	return t:Roll(...)
end

--[[
	Constructs a new ProbabilityDistributor

	@param weights: {WeightedItem<T>} - A table of weights to distribute.

	@param randomOrSeed: (Random | number)? - An optional random number generator to use for the rolls. If a
		number is passed, it will be used as the seed for a new random number generator. If nothing is passed,
		it will create a new Random and use the current time as the seed.
	
	@returns ProbabilityDistributor<T> - A new probability distributor of type T. Where T is the type of the
		value of the weighted item.
]]
function ProbabilityDistributor.new<T>(
	weights: { WeightedItem<T> },
	randomOrSeed: (Random | number)?
): ProbabilityDistributor<T>
	assert(type(weights) == "table", "Weights must be a table.")

	local self = setmetatable({
		NumberGenerator = if typeof(randomOrSeed) == "Random"
			then randomOrSeed
			else Random.new(randomOrSeed or os.clock()),

		MaxRepetitions = 100,
		OrderedWeights = {},
		TotalWeight = 0,
	}, ProbabilityDistributor)

	for i, item in weights do
		local weight = item.Weight
		if typeof(weight) == "function" then
			weight = weight()
		end
		if typeof(weight) == "NumberRange" then
			weight = self.NumberGenerator:NextInteger(weight.Min, weight.Max)
		end
		assert(type(weight) == "number", "Weight must be a number.")

		self.TotalWeight += weight
		table.insert(self.OrderedWeights, {
			Weight = weight,
			Value = item.Value,
			Order = i,
		})
	end

	table.sort(self.OrderedWeights, function(a, b)
		return a.Weight > b.Weight
	end)

	return self :: ProbabilityDistributor<T>
end

--[[
	Rolls the probability distributor for a weighted item.

	@param luck: number? - A number between 0 and 1 that determines how lucky the roll is. The number
		acts as a chance that it rerolls the item for a better version. 'Better'ness is determined by
		the initial order of the weights table.

	@return T - The value of the item that was rolled.
]]
function ProbabilityDistributor:Roll<T>(luck: number?): T
	local NumberGenerator: Random = self.NumberGenerator

	local totalWeight = self.TotalWeight
	local orderedWeights: { WeightedItem<T> & { Order: number } } = self.OrderedWeights

	luck = luck or 0
	assert(luck >= 0 and luck <= 1, "Ensure luck is between 0 and 1.")

	local repetitions, maxRepetitions = 0, self.MaxRepetitions
	local bestIdx, returnItem = -1, nil
	repeat
		repetitions += 1
		local randomV = math.clamp((NumberGenerator:NextNumber() * totalWeight), 0, totalWeight)

		local runningTotal = 0
		for i = 1, #orderedWeights do
			local item = orderedWeights[i]

			runningTotal += item.Weight
			if randomV <= runningTotal then
				if item.Order > bestIdx then
					bestIdx = item.Order
					returnItem = item
				end
				break
			end
		end
	until NumberGenerator:NextNumber() >= luck or repetitions >= maxRepetitions

	return returnItem.Value
end

return table.freeze(ProbabilityDistributor)
