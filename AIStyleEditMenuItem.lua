--[[
AI Style Edit — menu entry point.

LrExportSession ("must not call on main UI task") was the only consistently failing
piece across every threading variant. It is removed entirely: no thumbnail export,
no histogram export. The plugin sends the style description + photo metadata to the
model (text only) and applies the returned develop settings.

Threading:
  UI thread  → dialog + metadata (getRawMetadata / getFormattedMetadata)
  postAsync  → getDevelopSettings, OpenAI (LrHttp), apply preset
]]
local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrBinding = import "LrBinding"
local LrView = import "LrView"
local LrTasks = import "LrTasks"
local LrPathUtils = import "LrPathUtils"

local MetadataCollector = require "MetadataCollector"
local ThumbnailExporter = require "ThumbnailExporter"
local OpenAIClient = require "OpenAIClient"
local SettingsMapper = require "SettingsMapper"
local PresetApplier = require "PresetApplier"
local DebugLog = require "DebugLog"
local Base64 = require "Base64"
local logger = require "Logger"

-- Read a reference image file and return { b64 = ..., mime = ... }, or nil + error. The reference
-- is whatever the user picks (a sample shot of the look they want); we send it as-is so the model
-- can match its grade. Cap the size so a huge file can't blow up the request.
local MAX_REF_BYTES = 8 * 1024 * 1024
local MIME_BY_EXT = {
	jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png",
	webp = "image/webp", gif = "image/gif",
}

local function readReferenceImage(path)
	if not path or path == "" then return nil end
	local f = io.open(path, "rb")
	if not f then return nil, "could not open reference image" end
	local data = f:read("*all")
	f:close()
	if not data or #data == 0 then return nil, "reference image was empty" end
	if #data > MAX_REF_BYTES then
		return nil, "reference image too large (" .. math.floor(#data / 1048576) .. " MB; max 8 MB)"
	end
	local ext = (LrPathUtils.extension(path) or ""):lower()
	return { b64 = Base64.encode(data), mime = MIME_BY_EXT[ext] or "image/jpeg" }
end

local pipelineRunning = false

-- "I'm Feeling Lucky": no user style. We hand the model a directive to diagnose the photo and
-- produce the best professional edit it can, leaning on its own judgement instead of a style brief.
local LUCKY_DIRECTIVE =
	"AUTO / \"I'm Feeling Lucky\" mode — the user did NOT specify a style. Study the attached image "
	.. "and every piece of metadata, diagnose what THIS specific photo needs, and produce the best "
	.. "possible professional edit. Nail the fundamentals first (white balance, exposure, a full "
	.. "tonal range, highlight/shadow recovery, believable skin and memory colors), then apply a "
	.. "tasteful, genre-appropriate finish that makes this image look its best. Stay restrained and "
	.. "natural — aim for a polished result a top editor would sign off on, not a heavy stylization. "
	.. "Pick the look that best suits the subject, light, and mood you actually see."

local function promptForStyle(context)
	local props = LrBinding.makePropertyTable(context)
	props.styleText = ""
	props.refPath = nil
	props.refLabel = "No reference image — optional"

	local f = LrView.osFactory()
	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),
		f:static_text {
			title = "Describe the look you want:",
			font = "<system/bold>",
		},
		f:edit_field {
			value = LrView.bind("styleText"),
			width_in_chars = 50,
			height_in_lines = 4,
			immediate = true,
		},
		f:static_text {
			title = 'e.g. "moody cinematic, lifted matte blacks, warm skin tones"',
			text_color = import("LrColor")(0.5, 0.5, 0.5),
		},
		f:spacer { height = 6 },
		f:static_text {
			title = "Reference look (optional) — match the grade of an example image:",
			font = "<system/bold>",
		},
		f:row {
			spacing = f:label_spacing(),
			f:push_button {
				title = "Choose reference image…",
				action = function()
					local chosen = LrDialogs.runOpenPanel {
						title = "Choose a reference image to match",
						canChooseFiles = true,
						canChooseDirectories = false,
						allowsMultipleSelection = false,
						fileTypes = { "jpg", "jpeg", "png", "webp", "gif" },
					}
					if chosen and chosen[1] then
						props.refPath = chosen[1]
						props.refLabel = LrPathUtils.leafName(chosen[1])
					end
				end,
			},
			f:push_button {
				title = "Clear",
				action = function()
					props.refPath = nil
					props.refLabel = "No reference image — optional"
				end,
			},
			f:static_text {
				title = LrView.bind("refLabel"),
				width_in_chars = 28,
				text_color = import("LrColor")(0.5, 0.5, 0.5),
			},
		},
		f:static_text {
			title = "…or click \"I'm Feeling Lucky\" to let the AI pick the best edit for you.",
			text_color = import("LrColor")(0.5, 0.5, 0.5),
		},
	}

	local result = LrDialogs.presentModalDialog {
		title = "AI Style Edit",
		contents = contents,
		actionVerb = "Generate Edit",
		otherVerb = "I'm Feeling Lucky",
	}

	-- "other" = I'm Feeling Lucky: ignore typed text, but still honor a reference if one was chosen.
	if result == "other" then
		return LUCKY_DIRECTIVE, props.refPath
	end
	if result == "ok" and ((props.styleText and props.styleText ~= "") or props.refPath) then
		-- A reference image alone is a valid request even without typed text.
		local text = (props.styleText and props.styleText ~= "") and props.styleText
			or "Match the attached reference look as closely as is tasteful for this photo."
		return text, props.refPath
	end
	return nil
end

local function startPipeline(photo, styleText, brief, base64Jpeg, refPath)
	pipelineRunning = true
	logger:trace("=== NEW RUN === Style request: " .. styleText)
	logger:trace("mode: build 20 | text+metadata+image+reference | hasImage="
		.. tostring(base64Jpeg ~= nil) .. " | hasRef=" .. tostring(refPath ~= nil)
		.. " | steps: metadata -> openai -> apply")

	LrFunctionContext.postAsyncTaskWithContext("aiStyleEditPipeline", function(context)
		logger:trace("pipeline task; canYield=" .. tostring(LrTasks.canYield()))

		local ok, err = LrTasks.pcall(function()
			MetadataCollector.enrichDevelopSettings(photo, brief)

			local refImage
			if refPath then
				local ref, refErr = readReferenceImage(refPath)
				if ref then
					logger:trace("reference image loaded (" .. tostring(#ref.b64) .. " b64 chars, " .. ref.mime .. ")")
					refImage = ref
				else
					logger:trace("reference image skipped: " .. tostring(refErr))
				end
			end

			logger:trace("openai: requesting edit")
			local edit, aiErr = OpenAIClient.requestEdit(styleText, brief, base64Jpeg, refImage)
			if not edit then
				error(aiErr or "OpenAI request failed")
			end
			logger:trace("openai: ok")

			local settings = SettingsMapper.toDevelopSettings(edit, brief)

			DebugLog.writeRun {
				styleText = styleText,
				brief = brief,
				modelEdit = edit,
				mappedSettings = settings,
			}

			logger:trace("apply: starting")
			local applyOk, applyErr = PresetApplier.apply(photo, settings)
			if not applyOk then
				error(applyErr or "failed to apply preset")
			end
			logger:trace("apply: ok")

			LrDialogs.message(
				"AI Style Edit applied",
				edit.rationale or "Edit applied.",
				"info"
			)
		end)

		pipelineRunning = false

		if not ok then
			logger:trace("pipeline error: " .. tostring(err))
			LrDialogs.message("AI Style Edit failed", tostring(err), "critical")
		end
	end)
end

LrFunctionContext.callWithContext("aiStyleEditPrompt", function(context)
	if pipelineRunning then
		LrDialogs.message(
			"AI Style Edit",
			"An edit is already in progress. Wait for it to finish.",
			"warning"
		)
		return
	end

	local catalog = LrApplication.activeCatalog()
	local photo = catalog:getTargetPhoto()
	if not photo then
		LrDialogs.message("AI Style Edit", "Select a single photo first.", "warning")
		return
	end

	local styleText, refPath = promptForStyle(context)
	if not styleText then return end

	logger:trace("collecting metadata on UI thread; canYield=" .. tostring(LrTasks.canYield()))
	local brief = MetadataCollector.collect(photo)
	logger:trace("metadata collected")

	-- Capture a JPEG preview for the vision model. requestJpegThumbnail is only reliable on the
	-- UI thread (background requests return "error loading thumb" — see THREADING.md), so we do it
	-- here and launch the pipeline from its callback. Two gotchas handled:
	--   1. The callback can fire more than once (a cached/nil thumb first, then the full render),
	--      so we ONLY launch on a successful payload and let a one-shot guard pick the first good one.
	--   2. If no usable thumbnail ever arrives, a timeout fallback launches text-only so we never hang.
	local started = false
	local function launch(b64)
		if started then return end
		started = true
		startPipeline(photo, styleText, brief, b64, refPath)
	end

	logger:trace("requesting JPEG thumbnail on UI thread; canYield=" .. tostring(LrTasks.canYield()))
	local reqOk = pcall(function()
		ThumbnailExporter.requestBase64Jpeg(photo, 1024, function(b64, err)
			if b64 and not err then
				logger:trace("thumbnail ready (" .. tostring(#b64) .. " b64 chars)")
				launch(b64)
			else
				logger:trace("thumbnail attempt empty/error: " .. tostring(err))
			end
		end)
	end)

	-- Fallback so a missing/failed thumbnail can't stall the run. If a real image arrives first,
	-- the guard makes this a no-op; otherwise we proceed text-only after a short wait.
	LrTasks.startAsyncTask(function()
		if not reqOk then
			logger:trace("requestJpegThumbnail threw; proceeding text-only")
			launch(nil)
			return
		end
		LrTasks.sleep(6)
		if not started then
			logger:trace("no thumbnail within timeout; proceeding text-only")
			launch(nil)
		end
	end)
end)
