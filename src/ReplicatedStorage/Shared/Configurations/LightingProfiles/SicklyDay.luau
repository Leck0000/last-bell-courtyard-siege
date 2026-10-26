--!strict
return table.freeze({
	ClockTime = 14, Brightness = 2, ExposureCompensation = 0,
	Ambient = Color3.fromRGB(125, 139, 102), OutdoorAmbient = Color3.fromRGB(184, 201, 149),
	ColorShift_Top = Color3.fromRGB(0, 0, 0), ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
	EnvironmentDiffuseScale = 1, EnvironmentSpecularScale = 0.5,
	FogStart = 100, FogEnd = 1200, FogColor = Color3.fromRGB(184, 201, 149),
	Sky = table.freeze({ CelestialBodiesShown = false, StarCount = 0 }),
	Atmosphere = table.freeze({ Density = 0.18, Offset = 0, Color = Color3.fromRGB(184, 201, 149), Decay = Color3.fromRGB(98, 104, 107), Haze = 0.8, Glare = 0 }),
	BloomEffect = table.freeze({ Intensity = 0.15, Size = 20, Threshold = 1.5 }),
	ColorCorrectionEffect = table.freeze({ Enabled = true, Brightness = 0, Contrast = 0.08, Saturation = -0.12, TintColor = Color3.fromRGB(235, 245, 218) }),
})
