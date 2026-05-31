-- Settings panel shown in Plug-in Manager: enter/store the OpenAI API key.
local LrView = import "LrView"
local LrPasswords = import "LrPasswords"
local LrPrefs = import "LrPrefs"
local LrDialogs = import "LrDialogs"

local KEY_ACCOUNT = "openai_api_key"

local function persist(propertyTable)
	local prefs = LrPrefs.prefsForPlugin()
	LrPasswords.store(KEY_ACCOUNT, propertyTable.apiKey or "")
	local model = propertyTable.model
	if not model or model == "" then model = "gpt-5.5" end
	prefs.model = model
	local effort = propertyTable.reasoningEffort
	if not effort or effort == "" then effort = "medium" end
	prefs.reasoningEffort = effort
end

local function sectionsForTopOfDialog(viewFactory, propertyTable)
	local prefs = LrPrefs.prefsForPlugin()
	propertyTable.apiKey = LrPasswords.retrieve(KEY_ACCOUNT) or ""
	propertyTable.model = prefs.model or "gpt-5.5"
	propertyTable.reasoningEffort = prefs.reasoningEffort or "medium"

	-- Persist on every keystroke (immediate fields) as well as explicit Save.
	propertyTable:addObserver("apiKey", function() persist(propertyTable) end)
	propertyTable:addObserver("model", function() persist(propertyTable) end)
	propertyTable:addObserver("reasoningEffort", function() persist(propertyTable) end)

	local f = viewFactory
	return {
		{
			title = "AI Style Editor",
			f:row {
				f:static_text { title = "OpenAI API key:", width = 120 },
				f:password_field {
					value = LrView.bind { key = "apiKey", object = propertyTable },
					width_in_chars = 48,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = "Model:", width = 120 },
				f:edit_field {
					value = LrView.bind { key = "model", object = propertyTable },
					width_in_chars = 24,
					immediate = true,
				},
			},
			f:row {
				f:static_text { title = "Reasoning effort:", width = 120 },
				f:popup_menu {
					value = LrView.bind { key = "reasoningEffort", object = propertyTable },
					items = {
						{ title = "Off (no reasoning)", value = "off" },
						{ title = "Minimal", value = "minimal" },
						{ title = "Low", value = "low" },
						{ title = "Medium", value = "medium" },
						{ title = "High", value = "high" },
					},
				},
			},
			f:row {
				f:push_button {
					title = "Save key",
					action = function()
						persist(propertyTable)
						local check = LrPasswords.retrieve(KEY_ACCOUNT) or ""
						LrDialogs.message(
							check ~= "" and "API key saved" or "Nothing to save",
							check ~= "" and ("Stored a key of length " .. #check .. ".")
								or "The key field was empty.",
							check ~= "" and "info" or "warning"
						)
					end,
				},
				f:static_text {
					title = "Stored securely via the OS keychain. Default model: gpt-5.5",
					text_color = import("LrColor")(0.5, 0.5, 0.5),
				},
			},
		},
	}
end

return {
	sectionsForTopOfDialog = sectionsForTopOfDialog,
	KEY_ACCOUNT = KEY_ACCOUNT,
}
