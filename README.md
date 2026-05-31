# AI Style Editor (Lightroom Classic)

Describe a look in plain language; the plugin reads the selected photo's metadata,
asks OpenAI for Lightroom develop settings, and applies them as a plugin preset.

**Version:** 0.1.0.15 — **working / stable**

> Edits are generated from your description + the photo's metadata (camera, lens, ISO,
> keywords, current develop settings, etc.). The image pixels are **not** sent —
> Lightroom's image-export API (`LrExportSession`) is unreliable from plugin menus, so
> it was removed for stability.

## Current working state (build 15)

| Stage | Status | Notes |
|-------|--------|-------|
| Menu registration (Library + Plug-in Extras) | ✅ Working | Both point to the same script |
| Style prompt dialog | ✅ Working | Modal on the UI thread |
| Metadata collection (EXIF, lens, ISO, keywords) | ✅ Working | UI thread; `getRawMetadata` / `getFormattedMetadata` |
| Current develop settings | ✅ Working | Read in the async task via `getDevelopSettings` |
| OpenAI request (text + metadata) | ✅ Working | `LrHttp.post`, no image attached |
| Map model JSON → develop settings | ✅ Working | `SettingsMapper`, all values clamped |
| Apply as develop preset | ✅ Working | `addDevelopPresetForPlugin` + catalog write |
| In-progress guard (no double runs) | ✅ Working | `pipelineRunning` flag |
| Thumbnail/JPEG export | ❌ Removed | `LrExportSession` → "must not call on main UI task" |
| Histogram analysis | ❌ Removed | Same `LrExportSession` limitation |
| Progress bar (`LrProgressScope`) | ❌ Removed | Broke `LrHttp.post` (Lua 5.1 yield boundary) |

## How it runs (pipeline)

```
UI thread (callWithContext)
  ├─ promptForStyle            → style description
  └─ MetadataCollector.collect → EXIF / lens / keywords
postAsyncTaskWithContext  (canYield = true)
  └─ LrTasks.pcall            → yield-safe error handling
       ├─ enrichDevelopSettings → current sliders
       ├─ OpenAIClient.requestEdit (text + metadata JSON)
       ├─ SettingsMapper.toDevelopSettings
       └─ PresetApplier.apply  → preset applied to photo
```

Full threading rationale: **`THREADING.md`**.

## Setup

1. **File → Plug-in Manager → Add** and select the `ai-style-editor.lrplugin` folder.
2. Select **AI Style Editor** → enter your **OpenAI API key** (stored in the OS keychain).
3. Set **Model** (default `gpt-5.5`) and **Reasoning effort** if needed.
4. **Reload** after code updates; **restart Lightroom** once if behavior seems cached.

## How to run

1. In **Library**, select **one** photo.
2. Run **AI Style Edit…**:
   - **Library** → right-click photo → **AI Style Edit…**, or
   - **File → Plug-in Extras → AI Style Edit…**
3. Enter a style description → **Generate Edit**.
4. The model returns settings; the preset is applied and a summary dialog shows its rationale.

## Logs (on your Desktop)

| File | Contents |
|------|----------|
| `ai-style-editor.log` | Timestamped trace log |
| `ai-style-editor-last.json` | Last run: prompt, metadata brief, model JSON, mapped settings |

A successful run logs exactly this sequence:

```
collecting metadata on UI thread; canYield=false
metadata collected
=== NEW RUN === Style request: <your text>
pipeline task; canYield=true
openai: requesting edit
Posting to OpenAI, model=gpt-5.5
openai: ok
apply: starting
Applied AI Style Edit preset
apply: ok
```

## Getting the best edits

- Be specific: film stock, mood, subject (portrait, landscape).
- Examples: *"Kodak Gold 200, warm skin, lifted matte blacks"* or *"moody cinematic, teal shadows"*.
- The model styles from your words + the photo's metadata (it does not see the pixels),
  so richer catalog metadata (keywords, captions, lens, ISO) improves results.
- Review `ai-style-editor-last.json` to see exactly what the model returned.

## Troubleshooting

| Problem | What to try |
|---------|-------------|
| No API key | Plug-in Manager → AI Style Editor → enter key |
| OpenAI model error | Change model to one your account supports (e.g. `gpt-4o`) |
| `Network error contacting OpenAI` | Check connection / key / model name |
| Menu missing | Plug-in Manager → Add/Reload; be in Library with a photo selected |
| Edit already in progress | Wait for the current run to finish |
| Plugin not in list | Add the `ai-style-editor.lrplugin` folder in Plug-in Manager |

## Files

| File | Role |
|------|------|
| `Info.lua` | Plugin manifest, menu registration, version |
| `AIStyleEditMenuItem.lua` | Entry point + pipeline orchestration |
| `MetadataCollector.lua` | EXIF / develop-settings → brief |
| `OpenAIClient.lua` | Builds request, calls OpenAI, parses JSON |
| `SettingsMapper.lua` | Model JSON → clamped develop settings |
| `PresetApplier.lua` | Creates + applies the develop preset |
| `Logger.lua` / `LogPaths.lua` | Desktop trace log |
| `DebugLog.lua` | Writes last-run JSON |
| `PluginInfoProvider.lua` | Plug-in Manager settings panel |
| `json.lua` / `Base64.lua` | Utilities |
| `HistogramAnalyzer.lua` / `ThumbnailExporter.lua` | **Unused** (LrExportSession; kept for reference) |

## Developer notes

Threading rules and the full debugging history: **`THREADING.md`**.
