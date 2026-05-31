-- Resolves log file paths on the user's Desktop (portable across machines).
local LrPathUtils = import "LrPathUtils"

local M = {}

function M.desktopFile(filename)
	local desktop = LrPathUtils.getStandardFilePath("desktop")
	if desktop and desktop ~= "" then
		return LrPathUtils.child(desktop, filename)
	end
	return filename
end

function M.logFile()
	return M.desktopFile("ai-style-editor.log")
end

function M.lastRunJson()
	return M.desktopFile("ai-style-editor-last.json")
end

return M
