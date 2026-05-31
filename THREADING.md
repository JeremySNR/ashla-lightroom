# AI Style Editor — Lightroom threading

Lightroom Classic runs plugin code on different task types. Mixing them causes the errors this plugin hit during development.

## Task types

| Context | `LrTasks.canYield()` | Use for |
|---------|---------------------|---------|
| Menu / UI thread | `false` | Modal dialogs, `callWithContext` |
| `postAsyncTaskWithContext` | `true` | `LrExportSession`, HTTP, catalog writes |
| After `LrProgressScope` is created | often `false` | UI progress only — **not** export |

## Rules (do not break)

1. **Schedule work after the style dialog** with `LrFunctionContext.postAsyncTaskWithContext`, not a bare `startAsyncTask` from the menu alone.
2. **Run all `LrExportSession` work before** creating `LrProgressScope`.
3. **Do not nest `startAsyncTask` for export** — nested tasks often report `canYield=true` at entry but `canYield=false` inside export (see log: `export task entered` vs `exportPhotoData`).
4. **Do not use `requestJpegThumbnail` on background tasks** — returns `error loading thumb`. Use JPEG export on the async host instead.
5. **Only call `LrTasks.yield()` when `LrTasks.canYield()` is true.**
6. **Reload the plugin** after Lua changes; **restart Lightroom** once if `require()` seems to serve old modules.

## Pipeline layout (build 15+)

```
callWithContext (UI)
  ├─ promptForStyle
  └─ MetadataCollector.collect (EXIF only)
postAsyncTaskWithContext
  └─ LrTasks.pcall:
       ├─ enrichDevelopSettings (getDevelopSettings)
       ├─ OpenAIClient.requestEdit (LrHttp.post, text + metadata, no image)
       └─ PresetApplier.apply
```

`LrExportSession` is **removed**. Every threading variant (UI task, postAsync,
nested startAsyncTask, with/without pcall) still hit
`addRenditionsForPhotos: must not call on main UI task`, so export-based thumbnail and
histogram capture were dropped.

**Build 16 — vision via `requestJpegThumbnail` (UI thread only).** Rule #4 says
`requestJpegThumbnail` fails on *background* tasks. The inverse is the fix: call it from
the UI thread inside `callWithContext` (where the style dialog and metadata already run),
then launch the async pipeline from its callback with the base64 JPEG. Notes:
- The callback can fire more than once (cached thumb, then full render). A one-shot guard
  starts the pipeline on the first usable payload.
- A `LrTasks.startAsyncTask` + `LrTasks.sleep(6)` fallback launches text-only if no
  thumbnail arrives, so a missing preview can't stall the run.
- `HistogramAnalyzer.lua` still depends on `LrExportSession` and remains unused.

Do **not** use `LrProgressScope` before `LrHttp.post`.

Use **`LrTasks.pcall`**, never standard `pcall`, around yielding work (Lua 5.1 C-boundary).

## Lua 5.1 yield boundary (the real root cause)

Lightroom runs Lua 5.1, which **cannot yield across a C-call boundary**. Standard
`pcall` is a C function, so any yielding SDK call (`LrExportSession`, `LrHttp.post`,
`getDevelopSettings`) fails inside a normal `pcall` with `canYield=false` or
`"Yielding is not allowed within a C or metamethod call"`.

- Use **`LrTasks.pcall`** (yield-safe) instead of `pcall` around yielding work.
- `LrProgressScope` has the same effect and must not wrap yielding calls.

## References

- [Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic/)
- SDK modules: `LrTasks`, `LrFunctionContext`, `LrProgressScope`, `LrExportSession`
