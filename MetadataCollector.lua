-- Collects shot metadata + key current develop settings into a brief table for the model.
local LrTasks = import "LrTasks"
local logger = require "Logger"

local M = {}

-- Raw metadata keys we care about (EXIF / camera).
local RAW_KEYS = {
	"isoSpeedRating", "aperture", "shutterSpeed", "focalLength",
	"cameraMake", "cameraModel", "lens", "fileFormat", "isCropped",
	"dimensions", "croppedDimensions", "orientation",
}

-- Human-readable metadata (Lightroom formats these nicely). Gives the model shooting
-- context (lighting, flash, metering) and semantic intent (title/caption/keywords).
local FORMATTED_KEYS = {
	"flash", "exposureBias", "exposureProgram", "meteringMode",
	"focalLength35mm", "lens", "subjectDistance", "brightnessValue",
	"dateTimeOriginal", "gps", "gpsAltitude", "location", "city",
	"stateProvince", "country", "title", "caption", "keywordTags",
}

-- Current develop settings we surface so edits are relative, not destructive.
local SETTING_KEYS = {
	"WhiteBalance", "Temperature", "Tint", "ProcessVersion", "CameraProfile",
	"Exposure2012", "Contrast2012",
}

local function round(n, places)
	if type(n) ~= "number" then return n end
	local mult = 10 ^ (places or 2)
	return math.floor(n * mult + 0.5) / mult
end

-- Lightroom's dimension raw-metadata can be a { width, height } table or a "W x H" string.
-- Returns numeric width, height (or nil, nil if unparseable).
local function parseDimensions(d)
	if type(d) == "table" then
		return tonumber(d.width), tonumber(d.height)
	elseif type(d) == "string" then
		local w, h = d:match("(%d+)%s*[xX]%s*(%d+)")
		return tonumber(w), tonumber(h)
	end
	return nil, nil
end

-- Parse the hour from a "YYYY-MM-DD HH:MM:SS" capture timestamp -> rough lighting context.
local function timeOfDay(dateTimeStr)
	if type(dateTimeStr) ~= "string" then return nil end
	local hour = dateTimeStr:match("%d+%-%d+%-%d+%s+(%d+):")
	hour = tonumber(hour)
	if not hour then return nil end
	if hour < 6 or hour >= 21 then return "night"
	elseif hour < 8 then return "early morning / golden hour"
	elseif hour < 11 then return "morning"
	elseif hour < 15 then return "midday"
	elseif hour < 18 then return "afternoon"
	else return "evening / golden hour" end
end

-- Returns a plain table describing the shot, safe to JSON-encode.
function M.collect(photo)
	local raw = {}
	for _, k in ipairs(RAW_KEYS) do
		local ok, v = pcall(function() return photo:getRawMetadata(k) end)
		if ok and v ~= nil then raw[k] = v end
	end

	-- aperture is the f-number denominator (e.g. 2.8); shutterSpeed in seconds.
	local brief = {
		camera = (raw.cameraMake and raw.cameraModel)
			and (raw.cameraMake .. " " .. raw.cameraModel) or raw.cameraModel,
		lens = raw.lens,
		iso = raw.isoSpeedRating,
		aperture = raw.aperture and ("f/" .. round(raw.aperture, 1)) or nil,
		shutterSeconds = raw.shutterSpeed and round(raw.shutterSpeed, 4) or nil,
		focalLengthMm = raw.focalLength and round(raw.focalLength, 0) or nil,
		fileFormat = raw.fileFormat,
		isRaw = raw.fileFormat == "RAW" or raw.fileFormat == "DNG",
	}

	-- Pixel dimensions feed aspect-ratio framing for cinematic/film-format requests. Lightroom may
	-- return "dimensions" as a { width, height } table OR a "W x H" string depending on the build, so
	-- handle both; prefer the cropped dimensions (what the model actually sees) when present.
	local w, h = parseDimensions(raw.croppedDimensions)
	if not (w and h) then w, h = parseDimensions(raw.dimensions) end
	if w and h then
		brief.width = w
		brief.height = h
		brief.orientation = w >= h and "landscape" or "portrait"
	else
		logger:trace("MetadataCollector: no usable dimensions (dimensions=" .. type(raw.dimensions)
			.. ", croppedDimensions=" .. type(raw.croppedDimensions) .. ")")
	end

	-- The orientation flag (Lightroom 2-letter code, e.g. "AB" normal, "BC"/"DA" rotated 90 deg) is
	-- needed to map a display-space crop into Lightroom's stored-orientation crop coordinates. Without
	-- it, a wide band on a rotated photo gets applied as a tall sliver.
	if type(raw.orientation) == "string" then
		brief.exifOrientation = raw.orientation
		logger:trace("MetadataCollector: orientation=" .. raw.orientation)
	else
		logger:trace("MetadataCollector: orientation unavailable (" .. type(raw.orientation) .. ")")
	end

	-- Rich human-readable metadata. Only include non-empty values.
	local meta = {}
	for _, k in ipairs(FORMATTED_KEYS) do
		local ok, v = pcall(function() return photo:getFormattedMetadata(k) end)
		if ok and v ~= nil and v ~= "" then meta[k] = v end
	end
	brief.metadata = meta
	brief.timeOfDay = timeOfDay(meta.dateTimeOriginal)

	if next(meta) == nil then
		logger:trace("MetadataCollector: no formatted metadata on this photo")
	end

	brief.currentSettings = {}

	return brief
end

-- Call from a background async task (canYield=true). Safe to skip if unavailable.
function M.enrichDevelopSettings(photo, brief)
	if not LrTasks.canYield() then
		logger:trace("MetadataCollector: skipping develop settings (not on async task)")
		return
	end

	-- getDevelopSettings yields, so it must run under LrTasks.pcall — a plain pcall fails with
	-- "Yielding is not allowed within a C or metamethod call" and currentSettings stays empty.
	local settings = {}
	local ok, dev = LrTasks.pcall(function() return photo:getDevelopSettings() end)
	if ok and dev then
		for _, k in ipairs(SETTING_KEYS) do
			if dev[k] ~= nil then settings[k] = dev[k] end
		end
		brief.currentSettings = settings

		-- Orientation is carried in the develop settings (the SDK's authoritative source), and it is
		-- far more reliable than getRawMetadata("orientation"), which returns nil for many files (it
		-- did for this one). Lightroom stores crop coords in the photo's PRE-orientation (sensor)
		-- pixel space, so SettingsMapper needs this 2-letter code to transform a display-space crop
		-- into stored space — otherwise a wide band on a rotated photo applies as a tall sliver.
		-- Only fill if the raw-metadata pass (in M.collect) didn't already supply it.
		if type(dev.orientation) == "string" and dev.orientation ~= "" then
			if not brief.exifOrientation then brief.exifOrientation = dev.orientation end
			logger:trace("MetadataCollector: develop orientation=" .. dev.orientation)
		else
			logger:trace("MetadataCollector: develop orientation unavailable (" .. type(dev.orientation) .. ")")
		end

		logger:trace("MetadataCollector: develop settings captured")
	elseif not ok then
		logger:trace("MetadataCollector: getDevelopSettings failed: " .. tostring(dev))
	end
end

return M
