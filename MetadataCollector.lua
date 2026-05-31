-- Collects shot metadata + key current develop settings into a brief table for the model.
local LrTasks = import "LrTasks"
local logger = require "Logger"

local M = {}

-- Raw metadata keys we care about (EXIF / camera).
local RAW_KEYS = {
	"isoSpeedRating", "aperture", "shutterSpeed", "focalLength",
	"cameraMake", "cameraModel", "lens", "fileFormat", "isCropped",
	"dimensions",
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

	if type(raw.dimensions) == "table" then
		brief.width = raw.dimensions.width
		brief.height = raw.dimensions.height
		if brief.width and brief.height then
			brief.orientation = brief.width >= brief.height and "landscape" or "portrait"
		end
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

	local settings = {}
	local ok, dev = pcall(function() return photo:getDevelopSettings() end)
	if ok and dev then
		for _, k in ipairs(SETTING_KEYS) do
			if dev[k] ~= nil then settings[k] = dev[k] end
		end
		brief.currentSettings = settings
		logger:trace("MetadataCollector: develop settings captured")
	elseif not ok then
		logger:trace("MetadataCollector: getDevelopSettings failed: " .. tostring(dev))
	end
end

return M
