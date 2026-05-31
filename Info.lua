--[[
AI Style Editor — Lightroom Classic plugin manifest.

Describe a look in plain language; the plugin reads the photo + its EXIF, asks a
vision model for slider values, and applies them as a develop preset.
]]

return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = "ai.neuralvoice.aistyleeditor",
	LrPluginName = "AI Style Editor",

	LrPluginInfoUrl = "https://neural-voice.ai",

	LrPluginInfoProvider = "PluginInfoProvider.lua",

	LrExportMenuItems = {
		{
			title = "AI Style Edit\226\128\166", -- "AI Style Edit…"
			file = "AIStyleEditMenuItem.lua",
			enabledWhen = "photosSelected",
		},
	},

	LrLibraryMenuItems = {
		{
			title = "AI Style Edit\226\128\166",
			file = "AIStyleEditMenuItem.lua",
			enabledWhen = "photosSelected",
		},
	},

	VERSION = { major = 0, minor = 1, revision = 0, build = 21 },
}
