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
`addRenditionsForPhotos: must not call on main UI task`, so thumbnail and histogram
export were dropped. `HistogramAnalyzer.lua` / `ThumbnailExporter.lua` remain in the
folder but are unused by the main path.

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
