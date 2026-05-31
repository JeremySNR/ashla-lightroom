-- Maps the model's JSON edit to a Lightroom develop-settings table, clamping every value.
local M = {}

-- modelKey -> { lrKey, min, max }. Tonal keys use the 2012 (PV3+) suffix.
-- warmth/tintShift use Lightroom's RELATIVE WB keys so we nudge from the shot's own
-- white balance instead of overriding it (absolute Kelvin caused extreme color casts).
local MAP = {
	warmth = { "IncrementalTemperature", -100, 100 },
	tintShift = { "IncrementalTint", -100, 100 },
	exposure = { "Exposure2012", -5.0, 5.0 },
	contrast = { "Contrast2012", -100, 100 },
	highlights = { "Highlights2012", -100, 100 },
	shadows = { "Shadows2012", -100, 100 },
	whites = { "Whites2012", -100, 100 },
	blacks = { "Blacks2012", -100, 100 },
	texture = { "Texture", -100, 100 },
	clarity = { "Clarity2012", -100, 100 },
	dehaze = { "Dehaze", -100, 100 },
	vibrance = { "Vibrance", -100, 100 },
	saturation = { "Saturation", -100, 100 },
	vignette = { "PostCropVignetteAmount", -100, 100 },
	sharpness = { "Sharpness", 0, 150 },
	noiseReduction = { "LuminanceSmoothing", 0, 100 },
	-- Grain (film texture).
	grainAmount = { "GrainAmount", 0, 100 },
	grainSize = { "GrainSize", 0, 100 },
	grainFrequency = { "GrainFrequency", 0, 100 },
}

-- The 8 HSL color channels Lightroom exposes.
local HSL_COLORS = { "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta" }

-- Comprehensive allowlist of numeric develop-setting keys the model may set directly via the
-- "advanced" object, with safe ranges. This is what lets the AI touch every slider.
-- Tone/geometry/crop and lens-profile toggles are intentionally excluded (out of scope, risky).
local ALLOWED = {
	-- Basic tone (direct equivalents of the friendly keys).
	Exposure2012 = { -5, 5 }, Contrast2012 = { -100, 100 },
	Highlights2012 = { -100, 100 }, Shadows2012 = { -100, 100 },
	Whites2012 = { -100, 100 }, Blacks2012 = { -100, 100 },
	Texture = { -100, 100 }, Clarity2012 = { -100, 100 }, Dehaze = { -100, 100 },
	Vibrance = { -100, 100 }, Saturation = { -100, 100 },
	-- White balance (relative recommended; absolute included for completeness).
	IncrementalTemperature = { -100, 100 }, IncrementalTint = { -100, 100 },
	Temperature = { 2000, 50000 }, Tint = { -150, 150 },
	-- Parametric tone curve.
	ParametricShadows = { -100, 100 }, ParametricDarks = { -100, 100 },
	ParametricLights = { -100, 100 }, ParametricHighlights = { -100, 100 },
	ParametricShadowSplit = { 10, 70 }, ParametricMidtoneSplit = { 20, 80 },
	ParametricHighlightSplit = { 30, 90 },
	-- Sharpening.
	Sharpness = { 0, 150 }, SharpenRadius = { 0.5, 3.0 },
	SharpenDetail = { 0, 100 }, SharpenEdgeMasking = { 0, 100 },
	-- Noise reduction.
	LuminanceSmoothing = { 0, 100 }, LuminanceNoiseReductionDetail = { 0, 100 },
	LuminanceNoiseReductionContrast = { 0, 100 }, ColorNoiseReduction = { 0, 100 },
	ColorNoiseReductionDetail = { 0, 100 }, ColorNoiseReductionSmoothness = { 0, 100 },
	-- Grain.
	GrainAmount = { 0, 100 }, GrainSize = { 0, 100 }, GrainFrequency = { 0, 100 },
	-- Post-crop vignette + effects.
	PostCropVignetteAmount = { -100, 100 }, PostCropVignetteMidpoint = { 0, 100 },
	PostCropVignetteFeather = { 0, 100 }, PostCropVignetteRoundness = { -100, 100 },
	PostCropVignetteHighlightContrast = { 0, 100 },
	-- Lens (manual) vignette.
	VignetteAmount = { -100, 100 }, VignetteMidpoint = { 0, 100 },
	-- Defringe.
	DefringePurpleAmount = { 0, 20 }, DefringeGreenAmount = { 0, 20 },
	DefringePurpleHueLo = { 0, 100 }, DefringePurpleHueHi = { 0, 100 },
	DefringeGreenHueLo = { 0, 100 }, DefringeGreenHueHi = { 0, 100 },
	-- Color grading.
	ColorGradeBlending = { 0, 100 }, ColorGradeBalance = { -100, 100 },
	-- Camera calibration.
	ShadowTint = { -100, 100 },
	RedHue = { -100, 100 }, RedSaturation = { -100, 100 },
	GreenHue = { -100, 100 }, GreenSaturation = { -100, 100 },
	BlueHue = { -100, 100 }, BlueSaturation = { -100, 100 },
}

-- Programmatically allow all HSL, color-grade region, and B&W gray-mixer keys.
do
	for _, c in ipairs(HSL_COLORS) do
		ALLOWED["HueAdjustment" .. c] = { -100, 100 }
		ALLOWED["SaturationAdjustment" .. c] = { -100, 100 }
		ALLOWED["LuminanceAdjustment" .. c] = { -100, 100 }
		ALLOWED["GrayMixer" .. c] = { -100, 100 }
	end
	for _, region in ipairs({ "Shadow", "Midtone", "Highlight", "Global" }) do
		ALLOWED["ColorGrade" .. region .. "Hue"] = { 0, 360 }
		ALLOWED["ColorGrade" .. region .. "Sat"] = { 0, 100 }
		ALLOWED["ColorGrade" .. region .. "Lum"] = { -100, 100 }
	end
end

-- Color grading regions -> LR key prefix.
local GRADE_REGIONS = { shadow = "ColorGradeShadow", midtone = "ColorGradeMidtone",
	highlight = "ColorGradeHighlight", global = "ColorGradeGlobal" }

local function clamp(v, min, max)
	if v < min then return min end
	if v > max then return max end
	return v
end

local function setNum(s, key, v, min, max)
	if type(v) == "number" then s[key] = clamp(v, min, max) end
end

-- Tone curve: model gives an array of [input,output] pairs (0-255). LR wants a flat
-- {in0,out0,in1,out1,...} integer array. Returns nil if invalid.
local function flattenCurve(points)
	if type(points) ~= "table" or #points < 2 then return nil end
	local flat = {}
	for _, p in ipairs(points) do
		if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" then
			flat[#flat + 1] = clamp(math.floor(p[1] + 0.5), 0, 255)
			flat[#flat + 1] = clamp(math.floor(p[2] + 0.5), 0, 255)
		end
	end
	return #flat >= 4 and flat or nil
end

-- Applies a crop to settings if the model returned a valid rectangle. Coordinates are fractions
-- of the image (0..1) from the top-left. We require a real, sane rectangle (right>left, bottom>top,
-- and at least 10% of each dimension kept) so a malformed or degenerate crop can't mangle the photo.
local MIN_CROP_FRACTION = 0.1
local function applyCrop(s, crop)
	if type(crop) ~= "table" then return end
	local top, left = crop.top, crop.left
	local bottom, right = crop.bottom, crop.right
	-- Need at least one real edge, otherwise there's nothing to crop.
	if type(top) ~= "number" and type(left) ~= "number"
		and type(bottom) ~= "number" and type(right) ~= "number" then
		return
	end
	-- Default any unspecified edge to the full frame so a single-axis crop still works (e.g. a
	-- letterbox band that only gives top/bottom, leaving the full width).
	top = clamp(type(top) == "number" and top or 0, 0, 1)
	left = clamp(type(left) == "number" and left or 0, 0, 1)
	bottom = clamp(type(bottom) == "number" and bottom or 1, 0, 1)
	right = clamp(type(right) == "number" and right or 1, 0, 1)
	if (right - left) < MIN_CROP_FRACTION or (bottom - top) < MIN_CROP_FRACTION then
		return
	end
	s.CropTop = top
	s.CropLeft = left
	s.CropBottom = bottom
	s.CropRight = right
	if type(crop.angle) == "number" then
		s.CropAngle = clamp(crop.angle, -45, 45)
	end
	s.HasCrop = true
	s.CropConstrainToWarp = false
end

-- The model is told to return crops in the dedicated `crop` object, but it sometimes expresses them
-- as advanced CropTop/Left/Bottom/Right/CropAngle keys instead. Accept either so a valid crop is not
-- silently dropped — the advanced passthrough can't apply Crop* keys (they need validation + HasCrop).
local function cropFromEdit(edit)
	if type(edit.crop) == "table" then return edit.crop end
	local adv = edit.advanced
	if type(adv) == "table" and (type(adv.CropTop) == "number" or type(adv.CropLeft) == "number"
		or type(adv.CropBottom) == "number" or type(adv.CropRight) == "number") then
		return {
			top = adv.CropTop, left = adv.CropLeft,
			bottom = adv.CropBottom, right = adv.CropRight,
			angle = adv.CropAngle,
		}
	end
	return nil
end

-- The model sees the DISPLAY-oriented preview and returns crop fractions in that space, but Lightroom
-- stores CropTop/Left/Bottom/Right relative to the photo's UNROTATED (sensor) orientation. For a rotated
-- or mirrored photo those axes differ, so a wide display band can land as a tall sliver. This maps the
-- model's display-space rect into Lightroom's stored space using the EXIF orientation 2-letter code.
-- Identity for "AB" (normal), so unrotated photos are unaffected. Each branch returns left,top,right,bottom.
local ORIENT_XFORM = {
	-- code = function(l, t, r, b) -> l2, t2, r2, b2  (all 0..1, ordered)
	AB = function(l, t, r, b) return l, t, r, b end,                 -- 1 normal
	BA = function(l, t, r, b) return 1 - r, t, 1 - l, b end,         -- 2 mirror horizontal
	CD = function(l, t, r, b) return 1 - r, 1 - b, 1 - l, 1 - t end, -- 3 rotate 180
	DC = function(l, t, r, b) return l, 1 - b, r, 1 - t end,         -- 4 mirror vertical
	AD = function(l, t, r, b) return t, l, b, r end,                 -- 5 transpose
	BC = function(l, t, r, b) return t, 1 - r, b, 1 - l end,         -- 6 rotate 90 CW
	CB = function(l, t, r, b) return 1 - b, 1 - r, 1 - t, 1 - l end, -- 7 transverse
	DA = function(l, t, r, b) return 1 - b, l, 1 - t, r end,         -- 8 rotate 90 CCW
}

local function orientCrop(crop, orientation)
	if type(crop) ~= "table" then return crop end
	local xform = orientation and ORIENT_XFORM[orientation]
	if not xform then return crop end
	-- Fill missing edges with the full frame so we can rotate a complete rectangle.
	local l = type(crop.left) == "number" and crop.left or 0
	local t = type(crop.top) == "number" and crop.top or 0
	local r = type(crop.right) == "number" and crop.right or 1
	local b = type(crop.bottom) == "number" and crop.bottom or 1
	local l2, t2, r2, b2 = xform(l, t, r, b)
	return { left = l2, top = t2, right = r2, bottom = b2, angle = crop.angle }
end

-- edit: parsed model JSON. brief: metadata (used to decide temp handling).
-- Any valid edit.crop rectangle is applied. Gating lives in the prompt: the model only returns a
-- crop when discretionary cropping is enabled OR the style explicitly requests a format/aspect ratio.
-- Returns a settings table suitable for addDevelopPresetForPlugin.
function M.toDevelopSettings(edit, brief)
	local s = { ProcessVersion = "11.0" }

	for modelKey, spec in pairs(MAP) do
		local v = edit[modelKey]
		if type(v) == "number" then
			s[spec[1]] = clamp(v, spec[2], spec[3])
		end
	end

	-- Tone curve (point curves). Per-channel R/G/B enable film-style color crossover.
	local tc = edit.toneCurve
	if type(tc) == "table" then
		local rgb = flattenCurve(tc.rgb)
		if rgb then s.ToneCurvePV2012 = rgb end
		local r = flattenCurve(tc.red); if r then s.ToneCurvePV2012Red = r end
		local g = flattenCurve(tc.green); if g then s.ToneCurvePV2012Green = g end
		local b = flattenCurve(tc.blue); if b then s.ToneCurvePV2012Blue = b end
	end

	-- HSL per-channel: edit.hsl.orange = { h=, s=, l= }.
	local hsl = edit.hsl
	if type(hsl) == "table" then
		for _, color in ipairs(HSL_COLORS) do
			local c = hsl[color] or hsl[color:lower()]
			if type(c) == "table" then
				setNum(s, "HueAdjustment" .. color, c.h, -100, 100)
				setNum(s, "SaturationAdjustment" .. color, c.s, -100, 100)
				setNum(s, "LuminanceAdjustment" .. color, c.l, -100, 100)
			end
		end
	end

	-- Color grading: edit.colorGrade.shadow = { h=0-360, s=0-100, l=-100..100 }, plus
	-- blending (0-100) and balance (-100..100).
	local cg = edit.colorGrade
	if type(cg) == "table" then
		for region, prefix in pairs(GRADE_REGIONS) do
			local r = cg[region]
			if type(r) == "table" then
				setNum(s, prefix .. "Hue", r.h, 0, 360)
				setNum(s, prefix .. "Sat", r.s, 0, 100)
				setNum(s, prefix .. "Lum", r.l, -100, 100)
			end
		end
		setNum(s, "ColorGradeBlending", cg.blending, 0, 100)
		setNum(s, "ColorGradeBalance", cg.balance, -100, 100)
	end

	-- Black & white conversion (enables the gray mixer in ALLOWED).
	if edit.grayscale == true then
		s.ConvertToGrayscale = true
	end

	-- Advanced passthrough: any allowed Lightroom develop key -> number. This is what gives
	-- the model access to every slider. Unknown keys are ignored; values are clamped.
	if type(edit.advanced) == "table" then
		for key, v in pairs(edit.advanced) do
			local range = ALLOWED[key]
			if range and type(v) == "number" then
				s[key] = clamp(v, range[1], range[2])
			end
		end
	end

	applyCrop(s, orientCrop(cropFromEdit(edit), brief and brief.exifOrientation))

	return s
end

return M
