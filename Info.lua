--[[
Ashla — the light side of Lightroom Classic.

Describe a look in plain language; the plugin looks at the photo + its EXIF, asks a
vision model for slider values, and applies them as a develop preset.

Note: LrToolkitIdentifier stays "ai.neuralvoice.aistyleeditor" deliberately — the saved
OpenAI API key is stored in the keychain under this identifier, so renaming it would
orphan the key. The display name and menus are "Ashla".
]]

return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = "ai.neuralvoice.aistyleeditor",
	LrPluginName = "Ashla",

	LrPluginInfoUrl = "https://neural-voice.ai",

	LrPluginInfoProvider = "PluginInfoProvider.lua",

	LrExportMenuItems = {
		{
			title = "Ashla\226\128\166", -- "Ashla…"
			file = "AIStyleEditMenuItem.lua",
			enabledWhen = "photosSelected",
		},
	},

	LrLibraryMenuItems = {
		{
			title = "Ashla\226\128\166",
			file = "AIStyleEditMenuItem.lua",
			enabledWhen = "photosSelected",
		},
	},

	VERSION = { major = 0, minor = 1, revision = 0, build = 30 },
}
