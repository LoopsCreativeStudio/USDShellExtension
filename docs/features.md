# Features

Supported formats: `.usd` `.usda` `.usdc` `.usdz`

## Explorer Integration

| Feature | Description |
|---------|-------------|
| Thumbnails | Auto-generated 3D thumbnails rendered via Hydra (Storm), square 256×256 px, front-facing view; auto-framed from the world bounding box when no camera is authored in the stage; cached by Windows |
| Preview pane | Live Hydra viewport in the Explorer preview pane, with prim path bar and animation timeline |
| Windows Search | USD metadata (frame range, frame rate, format, custom layer data, documentation) indexed and searchable |
| File type icons | Custom icons and friendly type names for each USD format |

## Context Menu

Right-clicking any USD file shows a **USD Tools** submenu. The commands below are available depending on the file format and selection count.

---

### View

Opens the file in [usdview](https://openusd.org/release/toolset.html#usdview), the interactive USD scene viewer with a full Hydra renderer, scenegraph browser, and attribute inspector.

<!-- image -->

---

### Edit

Exports the file as a temporary `.usda` (ASCII) copy, opens it in the configured text editor, and re-imports any changes back into the original file on save. Works transparently on binary formats (`.usdc`, `.usdz`).

<!-- image -->

---

### Crate

Converts a `.usd` or `.usda` file to [USDC binary (Crate)](https://openusd.org/release/glossary.html#crate-file-format) format. The Crate format is significantly smaller and faster to load than ASCII.

<!-- image -->

---

### Uncrate

Converts a `.usdc` binary file back to [USDA ASCII](https://openusd.org/release/glossary.html#usda) text. Useful for inspection, version control diffs, or editing in a text editor.

<!-- image -->

---

### Flatten

[Flattens](https://openusd.org/release/glossary.html#flatten) the full USD composition into a single layer. All sublayer, reference, and payload opinions are baked into one file; the original is overwritten in place.

<!-- image -->

---

### Package as USDZ / Package as ARKit USDZ

Packs the USD file and all its dependencies into a self-contained [USDZ](https://openusd.org/release/spec_usdz.html) archive. The ARKit variant additionally validates and normalizes the output for [Apple ARKit compatibility](https://openusd.org/release/spec_usdz.html).

<!-- image -->

---

### Unpackage

Extracts the contents of a `.usdz` archive to a folder with the same name next to the original file (e.g. `scene.usdz` to `scene/`). All constituent files are written to disk with their subdirectory structure preserved.

<!-- image -->

---

### Stitch Layers

Select 2 or more USD files, then choose **Stitch Layers** to merge their time samples using [usdstitch](https://openusd.org/release/toolset.html#usdstitch). The result is written to `<first_file>_stitched.usd` in the same folder. Useful for combining per-frame or per-chunk exports into a single animated layer.

<!-- image -->

---

### Validate

Runs [usdchecker](https://openusd.org/release/toolset.html#usdchecker) on the file and displays the compliance report in a console window. Checks for schema violations, missing references, and ARKit compatibility issues.

<!-- image -->

---

### Fix Schemas

Runs [usdfixbrokenpixarschemas](https://openusd.org/release/toolset.html#usdfixbrokenpixarschemas) to automatically repair outdated or malformed Pixar schema entries. Useful after upgrading between USD versions.

<!-- image -->

---

### Layer Stack

Displays the [layer stack](https://openusd.org/release/glossary.html#layerstack) of the stage: all layers contributing to the composition, ordered by strength. Also lists all referenced and payload layers.

<!-- image -->

---

### Refresh Thumbnail

Forces Windows to regenerate the cached thumbnail for the file by re-running `usdrecord`.

<!-- image -->

---

### Stage Statistics

Computes and displays USD stage statistics (prim count, mesh count, instance count, memory usage, and more) based on `UsdUtils.ComputeUsdStageStats`.

<!-- image -->

---

### USD Shell Logs

Opens the Windows Event Viewer filtered to the **USD Shell Extension** source, where all errors and diagnostics from the extension are recorded.

<!-- image -->
