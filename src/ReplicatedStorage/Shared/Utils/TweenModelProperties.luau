--// Roblox Services //--
local TweenService = game:GetService("TweenService")

--// Types //--
export type TweenProperties = { [string]: unknown }

local function tweenModelCFrame(model: PVInstance, tweenInfo: TweenInfo, cframe: CFrame): Tween
	local CFrameValue = Instance.new("CFrameValue")
	CFrameValue.Value = model:GetPivot()

	CFrameValue:GetPropertyChangedSignal("Value"):Connect(function(): ()
		model:PivotTo(CFrameValue.Value)
	end)

	local tween = TweenService:Create(CFrameValue, tweenInfo, { Value = cframe })
	tween:Play()

	tween.Completed:Connect(function(): ()
		CFrameValue:Destroy()
	end)

	return tween
end

local function tweenModelScale(model: Model, tweenInfo: TweenInfo, scale: number): Tween
	local ScaleValue = Instance.new("NumberValue")
	ScaleValue.Value = model:GetScale()

	ScaleValue:GetPropertyChangedSignal("Value"):Connect(function(): ()
		model:ScaleTo(ScaleValue.Value)
	end)

	local tween = TweenService:Create(ScaleValue, tweenInfo, { Value = scale })
	tween:Play()

	tween.Completed:Connect(function(): ()
		ScaleValue:Destroy()
	end)

	return tween
end

return function(model: PVInstance, tweenInfo: TweenInfo, propertyTable: TweenProperties): { Tween }
	assert(model, "TweenModelProperties: model is nil")

	local tweens: { Tween } = {}
	local parts = model:GetDescendants()
	table.insert(parts, model)

	-- `propertyTable` belongs to the caller and CFrame/Scale are consumed here, so
	-- the consumption happens on a copy. Reusing one table across two calls used to
	-- silently lose both keys from the second call onwards.
	local partProperties: TweenProperties = table.clone(propertyTable)

	local cframe = partProperties.CFrame
	if typeof(cframe) == "CFrame" then
		table.insert(tweens, tweenModelCFrame(model, tweenInfo, cframe))
		partProperties.CFrame = nil
	end

	local scale = partProperties.Scale
	if typeof(scale) == "number" then
		-- Named here rather than left to `TweenService:Create`, which meets the
		-- unconsumed `Scale` key further down and reports it against a part the
		-- caller never mentioned.
		assert(model:IsA("Model"), `TweenModelProperties: Scale requires a Model, got a {model.ClassName}`)
		table.insert(tweens, tweenModelScale(model, tweenInfo, scale))
		partProperties.Scale = nil
	end

	for _, part in parts do
		if part:IsA("BasePart") then
			local tween = TweenService:Create(part, tweenInfo, partProperties)
			table.insert(tweens, tween)
			tween:Play()
		end
	end

	return tweens
end
