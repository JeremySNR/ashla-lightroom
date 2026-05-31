-- JPEG preview for the vision model.
-- UI thread: requestBase64Jpeg (requestJpegThumbnail).
-- Background: toBase64Jpeg (LrExportSession) — only when canYield=true.
local LrExportSession = import "LrExportSession"
local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"
local Base64 = require "Base64"
local logger = require "Logger"

local M = {}

-- Call from the UI thread (e.g. inside callWithContext). Invokes callback(b64, err).
function M.requestBase64Jpeg(photo, maxEdge, callback)
	maxEdge = maxEdge or 1024
	photo:requestJpegThumbnail(maxEdge, maxEdge, function(data, err)
		if data and #data > 0 then
			logger:trace("Thumbnail JPEG bytes: " .. tostring(#data))
			callback(Base64.encode(data), nil)
		else
			logger:trace("ThumbnailExporter: no data: " .. tostring(err))
			callback(nil, err or "error loading thumb")
		end
	end)
end

function M.toBase64Jpeg(photo, maxEdge)
	maxEdge = maxEdge or 1024

	local ok, result = pcall(function()
		local tempDir = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "AIStyleEditorThumb")
		LrFileUtils.createAllDirectories(tempDir)

		local session = LrExportSession {
			photosToExport = { photo },
			exportSettings = {
				LR_export_destinationType = "specificFolder",
				LR_export_destinationPathPrefix = tempDir,
				LR_export_useSubfolder = false,
				LR_format = "JPEG",
				LR_export_colorSpace = "sRGB",
				LR_jpeg_quality = 0.7,
				LR_size_doConstrain = true,
				LR_size_maxWidth = maxEdge,
				LR_size_maxHeight = maxEdge,
				LR_size_units = "pixels",
				LR_collisionHandling = "overwrite",
				LR_minimizeEmbeddedMetadata = true,
			},
		}

		session:doExportOnCurrentTask()

		local files = {}
		for entry in LrFileUtils.recursiveDirectoryIterator(tempDir) do
			if entry ~= "." and entry ~= ".." then
				table.insert(files, LrPathUtils.child(tempDir, entry))
			end
		end

		local path = files[1]
		if not path then error("export produced no file") end

		local f = io.open(path, "rb")
		if not f then error("cannot open exported JPEG") end
		local data = f:read("*all")
		f:close()
		pcall(function() LrFileUtils.delete(path) end)

		if not data or #data == 0 then error("empty JPEG") end
		logger:trace("Export JPEG bytes: " .. tostring(#data))
		return Base64.encode(data)
	end)

	if ok then return result, nil end
	return nil, tostring(result)
end

return M
