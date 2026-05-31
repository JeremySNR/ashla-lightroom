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

local MetadataCollector = require "MetadataCollector"
local ThumbnailExporter = require "ThumbnailExporter"
local OpenAIClient = require "OpenAIClient"
local SettingsMapper = require "SettingsMapper"
local PresetApplier = require "PresetApplier"
local DebugLog = require "DebugLog"
local logger = require "Logger"

local pipelineRunning = false

local function promptForStyle(context)
	local props = LrBinding.makePropertyTable(context)
	props.styleText = ""

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
	}

	local result = LrDialogs.presentModalDialog {
		title = "AI Style Edit",
		contents = contents,
		actionVerb = "Generate Edit",
	}

	if result == "ok" and props.styleText and props.styleText ~= "" then
		return props.styleText
	end
	return nil
end

local function startPipeline(photo, styleText, brief, base64Jpeg)
	pipelineRunning = true
	logger:trace("=== NEW RUN === Style request: " .. styleText)
	logger:trace("mode: build 16 | text+metadata+image | hasImage="
		.. tostring(base64Jpeg ~= nil) .. " | steps: metadata -> openai -> apply")

	LrFunctionContext.postAsyncTaskWithContext("aiStyleEditPipeline", function(context)
		logger:trace("pipeline task; canYield=" .. tostring(LrTasks.canYield()))

		local ok, err = LrTasks.pcall(function()
			MetadataCollector.enrichDevelopSettings(photo, brief)

			logger:trace("openai: requesting edit")
			local edit, aiErr = OpenAIClient.requestEdit(styleText, brief, base64Jpeg)
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

	local styleText = promptForStyle(context)
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
		startPipeline(photo, styleText, brief, b64)
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
