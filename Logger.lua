-- Shared logger: LrLogger console + append to Desktop/ai-style-editor.log
local LrLogger = import "LrLogger"
local LogPaths = require "LogPaths"

local logger = LrLogger("AIStyleEditor")
logger:enable("logfile")

local LOG_PATH = LogPaths.logFile()

local function fileLog(msg)
	pcall(function()
		local f = io.open(LOG_PATH, "a")
		if f then
			f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(msg) .. "\n")
			f:close()
		end
	end)
end

-- Wrap trace to also append to the Desktop log — but only once. If the module is
-- re-evaluated (e.g. on plugin reload) against the same logger object, re-wrapping would
-- stack fileLog and write every line twice. The guard keeps it idempotent.
if not logger._fileLogWrapped then
	local origTrace = logger.trace
	logger.trace = function(self, msg)
		origTrace(self, msg)
		fileLog(msg)
	end
	logger._fileLogWrapped = true
end

logger.fileLog = function(self, msg) fileLog(msg) end
logger.logPath = LOG_PATH

return logger
