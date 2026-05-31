-- Turns a settings table into a plugin develop preset and applies it to the photo.
local LrApplication = import "LrApplication"
local logger = require "Logger"

local M = {}

-- Applies settings to photo. Must be called from a task; performs the catalog write itself.
-- Returns true, or false + errorMessage.
function M.apply(photo, settings, presetName)
	presetName = presetName or "Ashla"

	local ok, preset = pcall(function()
		return LrApplication.addDevelopPresetForPlugin(_PLUGIN, presetName, settings)
	end)
	if not ok or not preset then
		return false, "Failed to create develop preset: " .. tostring(preset)
	end

	local catalog = LrApplication.activeCatalog()
	local ok, err = catalog:withWriteAccessDo("Ashla", function()
		photo:applyDevelopPreset(preset, _PLUGIN)
	end, { timeout = 10 })

	if ok == false then
		return false, tostring(err or "write access denied")
	end

	logger:trace("Applied Ashla preset")
	return true
end

return M
