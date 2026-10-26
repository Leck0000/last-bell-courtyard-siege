-- Hides, de-collides and welds one part of the clone to the root part. Unanchored:
-- an anchored part welded to the character would anchor the character.
local function attachPart(part: BasePart, rootPart: BasePart)
	if not part:IsA("MeshPart") and not part:FindFirstChildOfClass("SpecialMesh") then
		part.Transparency = 1
	end
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	local weld = Instance.new("WeldConstraint")
	weld.Parent = part
	weld.Part0 = part
	weld.Part1 = rootPart
end

return function(thingToClone: PVInstance, character: Model, relativeCFrame: CFrame?)
	if not thingToClone:IsA("PVInstance") then
		warn(thingToClone:GetFullName() .. " is not a PVInstance")
	end
	relativeCFrame = relativeCFrame or CFrame.new()
	local itemClone = thingToClone:Clone()
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	itemClone.Parent = rootPart
	itemClone:PivotTo(rootPart.CFrame * relativeCFrame)
	if itemClone:IsA("BasePart") then
		attachPart(itemClone, rootPart)
	else
		for _, descendant in itemClone:GetDescendants() do
			if descendant:IsA("BasePart") then
				attachPart(descendant, rootPart)
			end
		end
	end
	return itemClone
end
