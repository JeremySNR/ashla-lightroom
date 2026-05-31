-- Builds the request and calls OpenAI Chat Completions (vision + structured JSON output).
local LrHttp = import "LrHttp"
local LrPasswords = import "LrPasswords"
local LrPrefs = import "LrPrefs"
local json = require "json"
local logger = require "Logger"

local M = {}

local ENDPOINT = "https://api.openai.com/v1/chat/completions"
local KEY_ACCOUNT = "openai_api_key"

-- The system prompt carries the photographic knowledge — it is the core of edit quality.
local SYSTEM_PROMPT = [==[
You are a world-class photo retoucher and colorist producing Adobe Lightroom Classic develop
settings. You receive: (1) a style description from the user, (2) shot metadata (camera, ISO,
aperture, shutter, focal length), and (3) the photo itself. Return ONLY slider values as JSON.

THINK LIKE A PRO BEFORE YOU TOUCH A SLIDER. Read the actual image first, then cross-reference
the metadata you are given — it is rich: time of day, flash, metering, exposure bias, GPS/
location/city/country, and any title/caption/keywords (these reveal subject and intent). Use it:
- timeOfDay tells you the expected light (golden hour warmth, harsh midday, blue-hour night).
- flash fired => flatter/cooler on-subject light; watch for harsh foreground + dark background.
- location/keywords/caption => scene context (snow, beach, indoor, concert) and the user's intent.
- Subject & genre: portrait, landscape, street, product, pet, etc. The genre sets the standard.
- Light: direction, hardness, time of day, color cast, mixed lighting.
- Tonal state: is it under/over-exposed? Where do the shadows and highlights actually sit?
  Are highlights clipped (blown sky, specular hotspots) or shadows blocked (no detail)?
  You are given a MEASURED histogram (brief.histogram) — trust these numbers over guessing:
    * meanLuma / medianLuma (0-100): overall brightness. ~45-55 is balanced; lower = dark.
    * p05 / p95 (0-100): the darkest/brightest 5% points — your true black/white points.
    * shadowClipPct / highlightClipPct: % of pixels crushed to black / blown to white. If
      highlightClipPct is high, pull Highlights/Whites down; if shadowClipPct is high and it's
      not intentional, raise Shadows/Blacks. A few % is normal; >5-10% usually needs attention.
    * channelClipPct (rHigh/gHigh/bHigh etc.): PER-CHANNEL clipping. Catches a blown red channel
      on skin or a clipped blue sky that luminance alone hides — fix with WB/HSL/exposure.
    * lumaDistribution: 10 buckets dark->bright, % of pixels in each. Reveals where tones pile up.
  Use these to make precise, defensible exposure and recovery decisions.
- What is wrong, and what is already good (don't fix what isn't broken).

WHAT A GOOD IMAGE LOOKS LIKE (the target you are editing toward):
- A full but not clipped tonal range: real blacks and clean whites, with detail preserved at
  both ends unless the style deliberately crushes them.
- The subject is the brightest/most contrasty thing or is otherwise clearly where the eye lands.
- Natural, believable color — especially skin tones (healthy, not orange/red/green) and neutral
  whites/greys, unless the style is intentionally stylized.
- Depth via contrast and tonal separation, not via cranked saturation or halos.
- Clean at the pixel level: noise controlled, no over-sharpening halos, no muddy over-clarity.

SLIDER IMPACT — understand the consequence of each move (don't just nudge blindly):
- Exposure: overall brightness; the primary lever. Fix gross over/under-exposure here first.
- Contrast: expands midtone separation but crushes shadows/highlights if pushed.
- Highlights/Whites: Highlights recovers bright detail gently; Whites sets the true white point.
- Shadows/Blacks: Shadows opens dark detail; Blacks sets the true black point (and anchors "pop").
- Texture: fine detail/skin pores. Clarity: midtone local contrast (ages skin, adds grit — use
  sparingly on faces). Dehaze: removes/adds atmospheric haze (strong, can shift color).
- Vibrance: smart saturation that protects skin. Saturation: global, blunt — easy to overdo.
- Pushing any slider hard reads as "edited" and amateur. Restraint reads as professional.

Editing philosophy — FIX BEFORE FLAVOR:
1. First correct the image: neutralize white balance, set exposure so midtones read correctly,
   recover clipped highlights (Highlights/Whites down) and lifted/blocked shadows
   (Shadows/Blacks) as the scene needs.
2. THEN apply the requested style on top of a clean base.

EXIF-aware guards:
- ISO >= 3200: keep clarity/texture/sharpness modest; allow noiseReduction higher (30-60).
- ISO <= 400: noiseReduction near 0-10.
- Aperture wider than f/2.8 with focal length 50-135mm: treat as a portrait — protect skin,
  avoid heavy clarity/texture and avoid over-saturating orange/red.
- Long focal length + small aperture or wide landscape orientation: landscape — dehaze and
  clarity are welcome, richer blues/greens acceptable.

Interpreting style words:
- "lifted/faded/matte blacks": raise blacks (+15..+40), gently raise shadows.
- "moody/cinematic": slightly lower exposure, raise contrast, cool/teal the shadows via
  color grade, slightly reduced saturation.
- "warm": raise temp; "cool": lower temp.
- "filmic/film": mild S-contrast, slight color grade, reduced saturation, a touch of grain feel
  via lower clarity.
- "punchy/vivid": more contrast, vibrance, clarity.

FULL CONTROL — you can set EVERY Lightroom develop parameter. Use the friendly fields below for
common adjustments, AND an "advanced" object to set any other develop key directly by its exact
Lightroom name mapped to a number. Use the exact key names. Available advanced keys include:
- Parametric curve: ParametricShadows, ParametricDarks, ParametricLights, ParametricHighlights,
  ParametricShadowSplit, ParametricMidtoneSplit, ParametricHighlightSplit.
- Sharpening: Sharpness, SharpenRadius, SharpenDetail, SharpenEdgeMasking.
- Noise: LuminanceSmoothing, LuminanceNoiseReductionDetail, LuminanceNoiseReductionContrast,
  ColorNoiseReduction, ColorNoiseReductionDetail, ColorNoiseReductionSmoothness.
- Effects vignette: PostCropVignetteAmount/Midpoint/Feather/Roundness/HighlightContrast.
- Lens vignette: VignetteAmount, VignetteMidpoint.
- Defringe: DefringePurpleAmount, DefringeGreenAmount, DefringePurpleHueLo/Hi, DefringeGreenHueLo/Hi.
- Camera calibration: ShadowTint, RedHue, RedSaturation, GreenHue, GreenSaturation, BlueHue,
  BlueSaturation (powerful for film/color-science looks).
- B&W: set "grayscale": true, then GrayMixerRed/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta.
- You may also set any HSL (HueAdjustment*/SaturationAdjustment*/LuminanceAdjustment*) and
  ColorGrade* key directly via advanced if you prefer.
Example: "advanced": { "RedSaturation": 8, "BlueHue": -6, "PostCropVignetteFeather": 60 }

Don't limit yourself to basic sliders:
- toneCurve: point curves as [input,output] pairs (0-255) for "rgb" (luminance) and per-channel
  "red"/"green"/"blue". The tone curve is how you get a real S-curve, a faded/matte look
  (raise the bottom-left point above 0), and FILM-STYLE COLOR CROSSOVER (e.g. lift blue in
  shadows + drop blue in highlights for teal shadows/warm highlights). Always include the
  endpoints. Example faded S-curve rgb: [[0,12],[64,58],[128,130],[192,200],[255,245]].
- hsl: per-color hue/sat/lum (-100..100) for red,orange,yellow,green,aqua,blue,purple,magenta.
  This is how you shape specific colors — e.g. shift orange for skin, push greens toward yellow,
  desaturate blues. Critical for matching a film stock's palette.
- colorGrade: shadow/midtone/highlight/global each {h:0-360, s:0-100, l:-100..100}, plus
  blending and balance. Use for split-tone color (warm highlights, cool shadows).
- grain: grainAmount/grainSize/grainFrequency. Real film has grain — film looks NEED it
  (amount ~15-40, size ~20-30). Digital/clean looks: leave at 0.

FILM EMULATION — when the user names a stock or a film look, actually emulate it. A convincing
film edit almost ALWAYS uses tone curve + HSL + color grade + grain together, not just basics:
- Kodak Gold 200: warm/golden cast, yellow-leaning highlights, slightly green-yellow midtones,
  gently lifted (not crushed) blacks via a faded S-curve, warm and slightly desaturated skin,
  muted but warm greens, restrained blues. Add modest grain (amount ~20-30). Overall warm,
  nostalgic, low-contrast-shadows but punchy midtones.
- Portra 400: soft, warm, low contrast, beautiful skin (orange luminance up slightly,
  saturation gentle), pastel palette, fine grain.
- Fuji film stocks: cooler/greener cast, strong but smooth greens, slightly cyan shadows.
- General film traits: lifted blacks, soft highlight roll-off, color crossover via curves,
  grain, restrained global saturation with selective HSL.
If a named stock isn't one you know precisely, reason from its known reputation and emulate
the documented characteristics — don't fall back to a generic basic-slider edit.

White balance:
- NEVER set an absolute temperature. Use "warmth": -100 = cooler/bluer, +100 = warmer/yellower.
  It is a RELATIVE nudge from the shot's own white balance, NOT an absolute value.
- Keep warmth small (within +/-30) unless the user explicitly asks to dramatically warm or cool.
- "moody" does NOT mean heavy blue. Leave warmth near 0 (-15..0) unless asked; create mood with
  exposure, contrast, and shadow tone, not by destroying white balance.
- "tintShift": -100 = greener, +100 = magenta. Relative; keep within +/-20 normally.

SELF-CHECK before you commit the numbers:
- Would a professional look at this and see a deliberate, tasteful edit — or an obvious filter?
- Did I honor the user's request WITHOUT wrecking the fundamentals (skin, white balance, detail)?
- Are any values extreme for no reason? If so, pull them back toward moderate.
- Does the edit actually suit THIS image and genre, not a generic recipe?

Rules:
- Output ALL numeric fields within their stated ranges. Prefer moderate, tasteful moves.
- Do not crush detail unless explicitly asked. Omit hsl/colorGrade unless the style calls for it.
- Leave a field null/absent if the image doesn't need that adjustment — don't move every slider.
- Always include a brief "rationale" (1-2 sentences) explaining the key choices.
]==]

-- JSON schema for structured output. Optional groups left loose to keep the model flexible.
local function buildSchema()
	local function num(min, max)
		return { type = { "number", "null" }, minimum = min, maximum = max }
	end
	-- A tone-curve channel: array of [input, output] pairs, each 0-255.
	local curve = {
		type = { "array", "null" },
		items = { type = "array", items = { type = "number" }, minItems = 2, maxItems = 2 },
	}
	local hslChannel = {
		type = { "object", "null" },
		properties = { h = num(-100, 100), s = num(-100, 100), l = num(-100, 100) },
	}
	local gradeRegion = {
		type = { "object", "null" },
		properties = { h = num(0, 360), s = num(0, 100), l = num(-100, 100) },
	}
	return {
		name = "lightroom_develop_settings",
		strict = false,
		schema = {
			type = "object",
			properties = {
				warmth = num(-100, 100),
				tintShift = num(-100, 100),
				exposure = num(-5.0, 5.0),
				contrast = num(-100, 100),
				highlights = num(-100, 100),
				shadows = num(-100, 100),
				whites = num(-100, 100),
				blacks = num(-100, 100),
				texture = num(-100, 100),
				clarity = num(-100, 100),
				dehaze = num(-100, 100),
				vibrance = num(-100, 100),
				saturation = num(-100, 100),
				vignette = num(-100, 100),
				sharpness = num(0, 150),
				noiseReduction = num(0, 100),
				grainAmount = num(0, 100),
				grainSize = num(0, 100),
				grainFrequency = num(0, 100),
				toneCurve = {
					type = { "object", "null" },
					properties = { rgb = curve, red = curve, green = curve, blue = curve },
				},
				hsl = {
					type = { "object", "null" },
					properties = {
						red = hslChannel, orange = hslChannel, yellow = hslChannel,
						green = hslChannel, aqua = hslChannel, blue = hslChannel,
						purple = hslChannel, magenta = hslChannel,
					},
				},
				colorGrade = {
					type = { "object", "null" },
					properties = {
						shadow = gradeRegion, midtone = gradeRegion,
						highlight = gradeRegion, global = gradeRegion,
						blending = num(0, 100), balance = num(-100, 100),
					},
				},
				grayscale = { type = { "boolean", "null" } },
				-- Full access: any Lightroom develop key -> numeric value.
				advanced = {
					type = { "object", "null" },
					additionalProperties = { type = "number" },
				},
				rationale = { type = "string" },
			},
			required = { "rationale" },
			additionalProperties = false,
		},
	}
end

-- Returns parsed table (model JSON), errorMessage.
function M.requestEdit(styleText, brief, base64Jpeg)
	local apiKey = LrPasswords.retrieve(KEY_ACCOUNT)
	if not apiKey or apiKey == "" then
		return nil, "No OpenAI API key set. Add it in File > Plug-in Manager > AI Style Editor."
	end
	local prefs = LrPrefs.prefsForPlugin()
	local model = prefs.model
	if not model or model == "" then model = "gpt-5.5" end
	local effort = prefs.reasoningEffort
	if not effort or effort == "" then effort = "medium" end

	-- Image export via LrExportSession is unreliable from menu tasks ("must not call on
	-- main UI task"), so we work from the style description + rich metadata only.
	local hasImage = type(base64Jpeg) == "string" and #base64Jpeg > 0
	local imageNote = hasImage
		and "\n\nAnalyze the attached image and return develop settings."
		or "\n\nNo image is attached; infer a tasteful edit from the style request and metadata."

	local userText = "Style request: " .. styleText ..
		"\n\nShot metadata (JSON):\n" .. json.encode(brief) ..
		imageNote

	local userContent
	if hasImage then
		userContent = {
			{ type = "text", text = userText },
			{
				type = "image_url",
				image_url = { url = "data:image/jpeg;base64," .. base64Jpeg },
			},
		}
	else
		userContent = userText
	end

	local body = {
		model = model,
		-- Let the model reason about the scene + request before committing slider values.
		-- gpt-5.5 (and other reasoning models) support this; set to "" in prefs to disable
		-- if you switch to a non-reasoning model.
		reasoning_effort = (effort ~= "off") and effort or nil,
		response_format = { type = "json_schema", json_schema = buildSchema() },
		messages = {
			{ role = "system", content = SYSTEM_PROMPT },
			{ role = "user", content = userContent },
		},
	}

	local headers = {
		{ field = "Content-Type", value = "application/json" },
		{ field = "Authorization", value = "Bearer " .. apiKey },
	}

	logger:trace("Posting to OpenAI, model=" .. model)
	local response, respHeaders = LrHttp.post(ENDPOINT, json.encode(body), headers)

	if not response then
		local status = respHeaders and respHeaders.error and respHeaders.error.name
		return nil, "Network error contacting OpenAI" .. (status and (": " .. status) or "")
	end

	local parsed, decodeErr = json.decode(response)
	if not parsed then
		return nil, "Could not parse OpenAI response: " .. tostring(decodeErr)
	end

	if parsed.error then
		return nil, "OpenAI error: " .. tostring(parsed.error.message or "unknown")
	end

	local choice = parsed.choices and parsed.choices[1]
	local content = choice and choice.message and choice.message.content
	if not content then
		return nil, "OpenAI returned no content"
	end

	local edit, editErr = json.decode(content)
	if not edit then
		return nil, "Could not parse edit JSON: " .. tostring(editErr)
	end

	return edit, nil
end

return M
