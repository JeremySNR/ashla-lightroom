<div align="center">

# Ashla

### AI color grading for Adobe Lightroom Classic

**Describe the look you want, and Ashla grades the photo to match.**

![Lightroom Classic](https://img.shields.io/badge/Lightroom-Classic-31A8FF?style=for-the-badge)
![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72?style=for-the-badge)
![Vision](https://img.shields.io/badge/vision-enabled-3FB950?style=for-the-badge)
![Version](https://img.shields.io/badge/v0.1.0-build_22-FFD166?style=for-the-badge)

</div>

---

Ashla is named after the old word for the light side of the Force, which felt fitting for a tool that is all about light and color.

It is an AI color grading plugin for Adobe Lightroom Classic. You describe a mood in plain language, or hand it a reference photo, or just ask it to surprise you. Ashla looks at your image, reads its metadata, and returns a full set of develop settings that it applies as a one click preset. There are no sliders to wrestle with and no preset packs to buy. You say what you want, and it does the editing.

```
  you:    "Kodak Gold 200, warm skin, lifted matte blacks"
            |
          Ashla looks at the photo
            |
  exposure, contrast, tone curve, HSL, color grade, grain, optional crop
            |
  result: a finished, professional edit
```

## Three ways to ask for a look

| Mode | You give it | What Ashla does |
|------|-------------|-----------------|
| **Describe** | A look in words: film stock, mood, palette, subject | Reads your intent and grades to it |
| **Reference** | An example image of a look you love | Works out how that image was graded and reproduces the style on your photo, not its subject |
| **I'm Feeling Lucky** | Nothing at all | Studies the photo, decides what it needs, and makes the best edit it can on its own |

Reference matching and Lucky mode both rely on the same thing: Ashla actually sees the pixels. A JPEG preview of your photo travels with every request, along with your reference image if you provide one.

## How it edits

Ashla is not a one click filter with a fancy name. The model has a working knowledge of how a good retoucher actually thinks.

It does the fundamentals first. White balance, exposure, a full tonal range, highlight and shadow recovery, and believable skin all come before any creative styling goes on top.

It treats the sliders as a system rather than in isolation. It knows that whites and blacks set the range while highlights and shadows recover within it, that clarity, texture, and dehaze each work at a different scale, that vibrance protects skin where saturation does not, and that the tone curve and HSL can shift color the way film does.

It uses color grading with restraint. It understands split toning, complementary palettes, and the fact that a grade adds color where HSL only bends what is already there, and it leans on that knowledge sparingly.

The whole idea in one sentence: good editors tend to under edit. The best grade is the one you do not notice as a grade. Ashla aims for something a senior editor would happily sign off on, not an obvious filter.

## Cropping (optional, off by default)

Turn on one checkbox and Ashla can also recompose the frame. It can level a tilted horizon, trim dead space at the edges, tighten in on the subject, or nudge things toward a stronger composition. It only crops when doing so genuinely helps, it never cuts through faces or important content, and it leaves your framing alone the rest of the time. Every crop is validated before it reaches the catalog, so a bad one cannot mangle your photo.

## How it runs

```
On the UI thread:
  - you choose Describe, Reference, or Lucky
  - it reads EXIF, lens, ISO, keywords, and current develop settings
  - it captures a JPEG preview (the one reliable way to do this)

On a background task:
  - it sends your words, the metadata, and the preview (plus any reference) to the vision model
  - the model returns develop settings as structured JSON
  - every value is clamped to a safe range
  - the settings are applied as a develop preset
```

The full threading rationale lives in [THREADING.md](THREADING.md).

## Setup

1. Open **File > Plug-in Manager > Add** and select the `ai-style-editor.lrplugin` folder.
2. Open **Ashla** in the manager and enter your OpenAI API key. It is stored securely in your operating system keychain, never on disk and never in this repo.
3. Set your model (the default is `gpt-5.5`) and reasoning effort if you want.
4. Reload after any code updates, and restart Lightroom once if something seems cached.

## Running it

1. In the **Library**, select a single photo.
2. Launch Ashla by right clicking the photo and choosing **Ashla**, or from **File > Plug-in Extras > Ashla**.
3. Type a look and press **Generate Edit**, or attach a reference image, or click **I'm Feeling Lucky**.
4. Ashla returns the settings, applies the preset, and shows you a short note explaining its choices.

## Getting the best out of it

Be specific. Something like "Portra 400, soft warm skin, creamy highlight roll off" gives much better results than "make it nice."

Give it context. The richer your catalog metadata is, with keywords, captions, lens, and ISO, the better the read.

Show as well as tell. A reference frame is often worth a paragraph of description.

Check its work. Every run is logged so you can see exactly what the model returned.

## Logs

Both files are written to your Desktop, outside this repo:

| File | Contents |
|------|----------|
| `ai-style-editor.log` | A timestamped trace of the run |
| `ai-style-editor-last.json` | The last run: your prompt, the metadata, the model output, and the mapped settings |

## Troubleshooting

| Problem | What to try |
|---------|-------------|
| No API key | Plug-in Manager, open Ashla, and enter your key |
| Model error | Switch to a model your account supports, such as `gpt-4o` |
| Network error contacting OpenAI | Check your connection, key, and model name |
| Menu missing | Plug-in Manager, then Add or Reload, and make sure you are in the Library with a photo selected |
| Edit already in progress | Wait for the current run to finish |

## Under the hood

| File | Role |
|------|------|
| `Info.lua` | Manifest, menu registration, version |
| `AIStyleEditMenuItem.lua` | Entry point and pipeline orchestration |
| `MetadataCollector.lua` | Turns EXIF and develop settings into a brief |
| `OpenAIClient.lua` | Builds the request, calls OpenAI, parses the result. This is where the editing brain lives |
| `SettingsMapper.lua` | Maps the model JSON to clamped develop settings, including crop |
| `PresetApplier.lua` | Creates and applies the develop preset |
| `Logger.lua` and `LogPaths.lua` | The Desktop trace log |
| `DebugLog.lua` | The last run JSON |
| `PluginInfoProvider.lua` | The Plug-in Manager settings panel |
| `json.lua` and `Base64.lua` | Utilities |

<div align="center">

May the light be with you.

</div>
