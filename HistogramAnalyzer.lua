-- Computes a real histogram by exporting a small uncompressed TIFF and parsing its pixels.
-- Lightroom's SDK exposes no histogram/pixel API, so export-and-read is the only accurate route.
local LrExportSession = import "LrExportSession"
local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"
local logger = require "Logger"

local M = {}

local MAX_EDGE = 200 -- keeps the pixel loop fast (<= 40k pixels)

----------------------------------------------------------------------
-- Binary helpers (1-based positions, matching string.byte).
----------------------------------------------------------------------
local function u16(d, p, le)
	local a, b = string.byte(d, p), string.byte(d, p + 1)
	if not a or not b then return nil end
	if le then return a + b * 256 else return a * 256 + b end
end

local function u32(d, p, le)
	local a, b, c, e = string.byte(d, p), string.byte(d, p + 1),
		string.byte(d, p + 2), string.byte(d, p + 3)
	if not (a and b and c and e) then return nil end
	if le then return a + b * 256 + c * 65536 + e * 16777216
	else return a * 16777216 + b * 65536 + c * 256 + e end
end

local TYPE_SIZE = { [1] = 1, [2] = 1, [3] = 2, [4] = 4, [5] = 8 }

-- Reads the values of an IFD entry (entryPos is 1-based start of the 12-byte entry).
local function readEntry(d, entryPos, le)
	local typ = u16(d, entryPos + 2, le)
	local count = u32(d, entryPos + 4, le)
	local size = TYPE_SIZE[typ] or 1
	local total = size * count
	local valPos
	if total <= 4 then
		valPos = entryPos + 8
	else
		valPos = u32(d, entryPos + 8, le) + 1 -- TIFF offsets are 0-based
	end
	local vals = {}
	for i = 0, count - 1 do
		local p = valPos + i * size
		if size == 2 then vals[#vals + 1] = u16(d, p, le)
		elseif size == 4 then vals[#vals + 1] = u32(d, p, le)
		else vals[#vals + 1] = string.byte(d, p) end
	end
	return vals
end

----------------------------------------------------------------------
-- TIFF parse -> tone statistics.
----------------------------------------------------------------------
local function analyzeTiff(data)
	if #data < 8 then return nil, "file too small" end
	local bo = data:sub(1, 2)
	local le
	if bo == "II" then le = true elseif bo == "MM" then le = false
	else return nil, "not a TIFF" end

	local ifd = u32(data, 5, le) + 1
	local n = u16(data, ifd, le)
	if not n then return nil, "bad IFD" end

	local tags = {}
	for i = 0, n - 1 do
		local entryPos = ifd + 2 + i * 12
		local tag = u16(data, entryPos, le)
		tags[tag] = readEntry(data, entryPos, le)
	end

	local compression = tags[259] and tags[259][1] or 1
	local planar = tags[284] and tags[284][1] or 1
	local samples = tags[277] and tags[277][1] or 3
	local bits = tags[258] and tags[258][1] or 8
	local stripOffsets = tags[273]
	local stripCounts = tags[279]

	if compression ~= 1 then return nil, "compressed TIFF unsupported" end
	if planar ~= 1 then return nil, "planar TIFF unsupported" end
	if bits ~= 8 then return nil, "non-8-bit TIFF unsupported" end
	if not stripOffsets or not stripCounts then return nil, "no strips" end
	if samples < 3 then return nil, "needs RGB" end

	-- Accumulate luminance histogram + per-channel clip counts.
	local luma = {}
	for i = 0, 255 do luma[i] = 0 end
	local total = 0
	local clip = { rHigh = 0, gHigh = 0, bHigh = 0, rLow = 0, gLow = 0, bLow = 0 }

	for s = 1, #stripOffsets do
		local off = stripOffsets[s] + 1
		local cnt = stripCounts[s]
		local p = off
		local stop = off + cnt - samples
		while p <= stop do
			local r = string.byte(data, p)
			local g = string.byte(data, p + 1)
			local b = string.byte(data, p + 2)
			if r and g and b then
				local y = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
				if y > 255 then y = 255 end
				luma[y] = luma[y] + 1
				total = total + 1
				if r >= 253 then clip.rHigh = clip.rHigh + 1 elseif r <= 2 then clip.rLow = clip.rLow + 1 end
				if g >= 253 then clip.gHigh = clip.gHigh + 1 elseif g <= 2 then clip.gLow = clip.gLow + 1 end
				if b >= 253 then clip.bHigh = clip.bHigh + 1 elseif b <= 2 then clip.bLow = clip.bLow + 1 end
			end
			p = p + samples
		end
	end

	if total == 0 then return nil, "no pixels" end

	-- Derived stats, all on a 0-100 scale for the model.
	local function pct(count) return math.floor((count / total) * 1000 + 0.5) / 10 end
	local function toScale(v255) return math.floor((v255 / 255) * 100 + 0.5) end

	local sum, cumulative = 0, 0
	local median, p05, p95
	for i = 0, 255 do
		sum = sum + i * luma[i]
	end
	for i = 0, 255 do
		cumulative = cumulative + luma[i]
		local frac = cumulative / total
		if not p05 and frac >= 0.05 then p05 = i end
		if not median and frac >= 0.5 then median = i end
		if not p95 and frac >= 0.95 then p95 = i end
	end

	-- Coarse 10-bucket luminance distribution (% of pixels per bucket).
	local buckets = {}
	for b = 0, 9 do buckets[b + 1] = 0 end
	for i = 0, 255 do
		local b = math.min(9, math.floor(i / 25.6)) + 1
		buckets[b] = buckets[b] + luma[i]
	end
	for b = 1, 10 do buckets[b] = pct(buckets[b]) end

	return {
		meanLuma = toScale(sum / total),
		medianLuma = toScale(median or 0),
		p05 = toScale(p05 or 0),
		p95 = toScale(p95 or 255),
		shadowClipPct = pct(luma[0] + luma[1] + luma[2]),
		highlightClipPct = pct(luma[253] + luma[254] + luma[255]),
		channelClipPct = {
			rHigh = pct(clip.rHigh), gHigh = pct(clip.gHigh), bHigh = pct(clip.bHigh),
			rLow = pct(clip.rLow), gLow = pct(clip.gLow), bLow = pct(clip.bLow),
		},
		lumaDistribution = buckets, -- 10 buckets, dark -> bright
	}
end

----------------------------------------------------------------------
-- Public: export a small TIFF and analyze it. Returns stats table or nil, err.
-- Must run inside an async task. Never throws.
----------------------------------------------------------------------
function M.analyze(photo)
	local ok, result = pcall(function()
		local tempDir = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "AIStyleEditorHist")
		LrFileUtils.createAllDirectories(tempDir)

		local session = LrExportSession {
			photosToExport = { photo },
			exportSettings = {
				LR_export_destinationType = "specificFolder",
				LR_export_destinationPathPrefix = tempDir,
				LR_export_useSubfolder = false,
				LR_format = "TIFF",
				LR_export_colorSpace = "sRGB",
				LR_export_bitDepth = 8,
				LR_tiff_compressionMethod = "compressionMethod_None",
				LR_tiff_preserveTransparency = false,
				LR_size_doConstrain = true,
				LR_size_maxWidth = MAX_EDGE,
				LR_size_maxHeight = MAX_EDGE,
				LR_size_units = "pixels",
				LR_collisionHandling = "overwrite",
				LR_minimizeEmbeddedMetadata = true,
			},
		}

		logger:trace("HistogramAnalyzer: session created, calling doExportOnCurrentTask")
		session:doExportOnCurrentTask()
		logger:trace("HistogramAnalyzer: doExportOnCurrentTask done")

		local files = {}
		for entry in LrFileUtils.recursiveDirectoryIterator(tempDir) do
			if entry ~= "." and entry ~= ".." then
				table.insert(files, LrPathUtils.child(tempDir, entry))
			end
		end

		local path = files[1]
		if not path then error("export produced no file") end

		local f = io.open(path, "rb")
		if not f then error("cannot open exported TIFF") end
		local data = f:read("*all")
		f:close()
		pcall(function() LrFileUtils.delete(path) end)

		local stats, err = analyzeTiff(data)
		if not stats then error(err or "parse failed") end
		return stats
	end)

	if ok then return result end
	logger:trace("Histogram analysis failed: " .. tostring(result))
	return nil, tostring(result)
end

return M
