<div align="center">

# ✦ A S H L A ✦

### *The light side of Lightroom Classic.*

**Speak a look. Ashla bends the light to match.**

![Lightroom Classic](https://img.shields.io/badge/Lightroom-Classic-31A8FF?style=for-the-badge)
![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72?style=for-the-badge)
![Vision](https://img.shields.io/badge/vision-enabled-3FB950?style=for-the-badge)
![Version](https://img.shields.io/badge/v0.1.0-build_21-FFD166?style=for-the-badge)

</div>

---

> In the old tongue, **Ashla** is *the light* — the bright half of the Force.
> This is where your photographs come to find theirs.

Ashla is an AI color-grading plugin for **Adobe Lightroom Classic**. Describe a mood
in plain language — or hand it a reference frame, or simply say *surprise me* — and it
**looks at your photo**, reads its metadata, and renders a full set of develop settings
as a one-click preset. No sliders to wrestle. No presets to hoard. Just light, tuned to
your words.

```
                 you ──▶  "Kodak Gold 200, warm skin, lifted matte blacks"
                              │
                       ✦ ASHLA reads the frame ✦
                              │
   exposure · contrast · tone curve · HSL · color grade · grain · (optional crop)
                              │
                 photo ◀──  a finished, professional edit
```

---

## Three ways to ask for light

| Mode | You give it | Ashla does |
|------|-------------|------------|
| **Describe** | A look in words — film stock, mood, palette, subject | Interprets your intent and grades to it |
| **Reference** | An example image of a look you love | Diagnoses *that* grade and reproduces it on your photo — matching the **style**, not the subject |
| **I'm Feeling Lucky** | Nothing at all | Studies the photo, diagnoses what it needs, and makes the best edit it can — unprompted |

> Reference matching and Lucky mode both lean on the same thing: Ashla **sees the pixels**.
> A JPEG preview of your photo (and your reference, if you give one) rides along with every request.

---

## The craft

Ashla isn't a one-click filter dressed up in robes. The model carries a working knowledge of
how a top retoucher actually thinks:

- **Foundation first.** White balance, exposure, a full tonal range, highlight and shadow
  recovery, believable skin — *before* any creative flavor goes on top.
- **Sliders as a system.** It knows whites/blacks set the range while highlights/shadows recover
  within it; that clarity, texture, and dehaze fight at different radii; that vibrance protects skin
  where saturation won't; that the tone curve and HSL can crossover color the way film does.
- **Color grading with restraint.** It understands split-toning, complementary palettes, and how
  a grade *adds* color where HSL only bends what's there — and it uses that knowledge sparingly.

> **The whole philosophy in one line:** *pros under-edit.* The best grade is the one you don't
> notice as a grade. Ashla aims for "a senior editor would sign off on this," not "obvious one-click look."

---

## Cropping (optional, off by default)

Tick one box and Ashla may also **recompose** — level a tilted horizon, trim dead edge space,
tighten to the subject, nudge the frame toward a stronger third. It only crops when it genuinely
improves the shot, never cuts through faces or important content, and leaves your framing untouched
the rest of the time. Coordinates are validated before they ever reach the catalog, so a bad crop
can't mangle your photo.

---

## How it runs

```
UI thread
  ├─ Describe / Reference / Lucky   → your request
  ├─ read EXIF · lens · ISO · keywords · current develop settings
  └─ capture a JPEG preview          (UI-thread only — the one reliable path)
        │
async task
  └─ ✦ send words + metadata + preview (+ reference) to the vision model
        ├─ model returns develop settings as structured JSON
        ├─ map → clamp every value to a safe range
        └─ apply as a plugin develop preset  →  done
```

Full threading rationale lives in [`THREADING.md`](THREADING.md).

---

## Setup

1. **File → Plug-in Manager → Add**, select the `ai-style-editor.lrplugin` folder.
2. Open **Ashla** in the manager and enter your **OpenAI API key** (stored in the OS keychain — never on disk).
3. Set your **Model** (default `gpt-5.5`) and **Reasoning effort** if you like.
4. **Reload** after code updates; restart Lightroom once if anything seems cached.

## Run it

1. In **Library**, select **one** photo.
2. Launch **Ashla**:
   - right-click the photo → **Ashla…**, or
   - **File → Plug-in Extras → Ashla…**
3. Type a look and hit **Generate Edit** — *or* attach a reference — *or* click **I'm Feeling Lucky**.
4. Ashla returns settings, applies the preset, and shows you its reasoning.

---

## Getting the best out of it

- **Be specific.** Film stock, mood, subject, light: *"Portra 400, soft warm skin, creamy roll-off"*
  beats *"make it nice."*
- **Feed it context.** Richer catalog metadata — keywords, captions, lens, ISO — sharpens the read.
- **Show, don't only tell.** A reference frame is often worth a paragraph of description.
- **Peek behind the curtain.** Every run is logged so you can see exactly what the model returned.

## Logs (on your Desktop)

| File | Contents |
|------|----------|
| `ai-style-editor.log` | Timestamped trace of the run |
| `ai-style-editor-last.json` | Last run: your prompt, the metadata brief, the model's JSON, the mapped settings |

## Troubleshooting

| Problem | Try |
|---------|-----|
| No API key | Plug-in Manager → Ashla → enter your key |
| Model error | Switch to a model your account supports (e.g. `gpt-4o`) |
| `Network error contacting OpenAI` | Check connection, key, and model name |
| Menu missing | Plug-in Manager → Add/Reload; be in Library with a photo selected |
| Edit already in progress | Wait for the current run to finish |

---

## Under the hood

| File | Role |
|------|------|
| `Info.lua` | Manifest, menu registration, version |
| `AIStyleEditMenuItem.lua` | Entry point + pipeline orchestration |
| `MetadataCollector.lua` | EXIF / develop settings → brief |
| `OpenAIClient.lua` | Builds the request, calls OpenAI, parses the JSON — home of the editing brain |
| `SettingsMapper.lua` | Model JSON → clamped develop settings (incl. crop) |
| `PresetApplier.lua` | Creates and applies the develop preset |
| `Logger.lua` / `LogPaths.lua` | Desktop trace log |
| `DebugLog.lua` | Last-run JSON |
| `PluginInfoProvider.lua` | Plug-in Manager settings panel |
| `json.lua` / `Base64.lua` | Utilities |

<div align="center">

---

*May the light be with you.*

</div>
