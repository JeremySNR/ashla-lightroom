-- Writes the last run's brief, model output, and mapped settings to Desktop JSON.
local json = require "json"
local LogPaths = require "LogPaths"

local M = {}

local LOG_PATH = LogPaths.lastRunJson()

function M.writeRun(record)
	local ok, encoded = pcall(json.encode, record)
	if not ok then return end
	local f = io.open(LOG_PATH, "w")
	if not f then return end
	f:write(encoded)
	f:close()
end

M.path = LOG_PATH

return M
