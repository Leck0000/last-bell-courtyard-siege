--!strict
-- Red accents, neutral fill and long visibility preserve navigable silhouettes.
return table.freeze({
	ClockTime = 0, Brightness = 1.5, ExposureCompensation = 0.15,
	Ambient = Color3.fromRGB(110, 100, 98), OutdoorAmbient = Color3.fromRGB(105, 111, 108),
	ColorShift_Top = Color3.fromRGB(216, 58, 54), ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
	EnvironmentDiffuseScale = 1, EnvironmentSpecularScale = 0.5,
	FogStart = 100, FogEnd = 1200, FogColor = Color3.fromRGB(98, 104, 107),
	Sky = table.freeze({ CelestialBodiesShown = false, StarCount = 0 }),
	Atmosphere = table.freeze({ Density = 0.18, Offset = 0, Color = Color3.fromRGB(150, 135, 130), Decay = Color3.fromRGB(98, 104, 107), Haze = 0.8, Glare = 0 }),
	BloomEffect = table.freeze({ Intensity = 0.15, Size = 20, Threshold = 1.5 }),
	ColorCorrectionEffect = table.freeze({ Enabled = true, Brightness = 0, Contrast = 0.08, Saturation = -0.12, TintColor = Color3.fromRGB(255, 225, 220) }),
})
