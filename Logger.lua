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

local origTrace = logger.trace
logger.trace = function(self, msg)
	origTrace(self, msg)
	fileLog(msg)
end

logger.fileLog = function(self, msg) fileLog(msg) end
logger.logPath = LOG_PATH

return logger
