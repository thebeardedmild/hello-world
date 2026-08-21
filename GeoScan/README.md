# GeoScan

An iPhone app that turns the camera, the IMU and the LiDAR sensor into a
**GPS-referenced, colourised point cloud** you can measure off, annotate with
tagged stills, and export to the tools you already use.

Built for iOS 17+, SwiftUI + ARKit + Metal, no third-party dependencies.
Requires a LiDAR device (iPhone 12 Pro and later Pro/Pro Max, iPad Pro 2020+).

---

## What it does

**Scan.** Walk a site with the camera pointed at what matters. The LiDAR depth map
is unprojected on the GPU every frame, coloured from the wide camera, and
accumulated into a single world-space cloud you watch build up in real time.

**Georeference.** GPS fixes are collected throughout the scan and paired with the
AR trajectory. At the end, a least-squares fit solves the four unknowns that tie
the scan to the earth — latitude, longitude, height and a yaw to true north.

**Measure.** Tap two points, in AR while scanning or later in the reviewer.
Distances, paths, areas and heights, each with a real one-sigma error bar derived
from the points that were averaged to place it.

**Photograph and tag.** Hit the shutter mid-scan and the note editor opens
immediately. Each still stores its full camera pose and intrinsics, so it can be
projected back into the model — and tapping a detail *in the photo* drops a
marker on that detail *in the cloud*.

**Export.** PLY, LAS 1.4, OBJ, GeoJSON and CSV, in your choice of coordinate
frame, packaged with a README that states exactly what frame the numbers are in.

---

## How the interesting parts work

### Colourised unprojection (`Render/Shaders.metal`, `Capture/PointCloudAccumulator.swift`)

One GPU thread per depth pixel. Each thread gates on confidence and range,
unprojects through the camera intrinsics rescaled to the depth map's resolution,
transforms to world space, and samples colour from the wide camera at the
matching normalised coordinate — the depth map and the captured image share a
field of view, so no rectification is needed.

Points are 16 bytes (`GSPoint`: three floats plus RGB and confidence), not the 48
a naive `{float3, float3, float}` would cost. The buffer is shared storage, so
the same memory the shader appends to is what the CPU picks, filters and exports
from — no copies anywhere in the pipeline.

### Georeferencing (`Geo/GeoReferencer.swift`)

ARKit's world is gravity-aligned, which leaves only four unknowns: the geodetic
position of the origin, and a yaw about the up axis.

- **Position** comes from an accuracy-weighted least-squares fit over every fix.
- **Yaw** comes from a weighted 2-D Procrustes fit of the walked path against the
  GPS track — no scale term, because both are already metric. Once you have
  walked a few metres this beats the magnetometer comfortably, especially
  indoors and near steel.
- **Fallback**: too little movement for a stable fit, and it uses the compass
  heading captured at session start, and says so in the UI and the export.

Every fix is stored with the scan, so the fit can be re-run later — the cloud
itself is never touched. Scanner-local coordinates stay canonical; ENU and UTM
are computed on the way out.

### Measurement (`Processing/PointCloudPicker.swift`)

A raw nearest-point pick inherits the full sensor noise of a single sample —
about 1% of range, so ~3 cm at 3 m, and it will not repeat. Instead:

1. Walk the spatial hash grid along the ray to find the first cluster it pierces.
2. Fit a plane through the local neighbourhood by PCA (Jacobi eigendecomposition
   of the covariance).
3. Intersect the ray with that plane.

Averaging *n* samples pulls noise down by √n, and the fit residual gives an
honest error bar — which is what the `± mm` next to every measurement is.

### Photo correlation (`Processing/PhotoCorrelator.swift`)

Storing pose + intrinsics with each still buys both directions:

- **world → pixel**: "which of my photos show this corner, and where in them?"
  Occlusion is tested by using the cloud itself as a depth buffer.
- **pixel → world**: tap a crack in a photo, the ray is intersected with the
  cloud, and the marker becomes a 3-D annotation that exports as a GeoJSON point.

Stills are written in *sensor* orientation with an EXIF orientation tag, never
rotated. Rotating the pixels without rotating the intrinsics is how photo-to-model
correlation quietly breaks.

### IMU use (`Geo/MotionLogger.swift`)

ARKit already fuses the IMU for pose, so this reads it for the two things ARKit
does not hand back:

- A **shake gate**. Above ~1 rad/s the rolling shutter smears the frame enough to
  paint colour onto the wrong geometry. Those frames are skipped. It is the
  single biggest lever on colour quality.
- A **barometric altitude trace**, far steadier than GPS altitude over a few
  minutes, recorded alongside every fix.

---

## Accuracy, honestly

| | Typical | Set by |
|---|---|---|
| Relative (point to point inside a scan) | ~1 cm at 2 m | LiDAR noise, ~1% of range |
| Measurement repeatability | 3–10 mm | plane-fit averaging over the neighbourhood |
| Absolute position | 3–10 m | consumer GPS — nothing in software fixes this |
| Bearing to true north | 1–3° with a GPS track fit | walked baseline length |
| | 5–15° on compass fallback | magnetometer, worse indoors |

**Measure freely inside a scan; do not treat the absolute coordinates as
survey-grade.** The exported README repeats this, with the actual numbers for
that scan. Heights are ellipsoidal (WGS84), not orthometric — no geoid model is
applied.

---

## Export formats

| File | What it is |
|---|---|
| `cloud.ply` | Binary little-endian, XYZ + RGB + a `confidence` property |
| `cloud.las` | LAS 1.4, point format 2, millimetre-scaled, OGC WKT CRS in a VLR, confidence in the user-data byte |
| `mesh.obj` | ARKit's scene reconstruction, re-expressed in the chosen frame |
| `photos/` | The stills, EXIF-geotagged |
| `photos.geojson` | Photo pins and resolved markers, WGS84 |
| `measurements.geojson` | Lines and polygons with lengths, areas and sigmas |
| `measurements.csv` | The measurement schedule, for a report |
| `photos.csv` | Photo log with notes, tags and bearings |
| `scan.json` | Everything: settings, statistics, GPS fixes, full camera poses |
| `README.txt` | The coordinate frame, the georeference quality, the caveats |

Three coordinate frames are offered: **scanner-local** (no GPS needed),
**local ENU** (metres east/north/up from the scan origin, true north), and
**UTM** (WGS84, auto-zoned, with a stated offset so the values still fit in
32-bit floats). GeoJSON is always WGS84 lat/lon, per its specification.

---

## Building

```
open GeoScan/GeoScan.xcodeproj
```

Requires **Xcode 16 or later** — the project uses file-system synchronized
groups, so new source files are picked up without editing the project file.

Then:

1. Select your team under Signing & Capabilities (the bundle id is
   `com.example.geoscan`; change it to your own).
2. Build to a LiDAR device. **The simulator cannot run this** — there is no
   `sceneDepth` and no camera feed.
3. Allow camera and location access when prompted. Location is optional; without
   it you still get a fully measurable, un-georeferenced scan.

## Source layout

```
GeoScan/
├── App/          entry point, bridging header
├── Capture/      ARSession control, GPU accumulation, stills, mesh
├── Geo/          WGS84 geodesy, UTM, GPS/AR fitting, CoreLocation, CoreMotion
├── Model/        Project, PhotoNote, SiteMeasurement, point cloud + spatial index
├── Processing/   voxel and outlier filters, ray picking, photo correlation
├── Render/       Metal renderer, shaders, orbit camera, SwiftUI bridge
├── Storage/      on-disk project format
├── Export/       PLY, LAS, OBJ, GeoJSON, CSV, bundle assembly
└── UI/           SwiftUI screens
```

## Field notes

- Keep surfaces **0.5–4 m** away. Beyond about 5 m the sensor's error grows
  faster than its usefulness, which is why the default range gate stops there.
- **Walk at least 10 m** during a scan if you care about true north. That is what
  gives the track fit enough baseline to beat the compass.
- **Move slowly.** Skipped frames are shown live in the HUD.
- Switch the cloud to **Confidence** colouring to find the areas worth
  re-scanning before you leave the site.
- The point buffer holds 6M points by default. When it fills, auto-compact
  voxel-filters it in place, so a long scan loses resolution rather than
  stopping.

## Known limitations

- No loop closure. ARKit drift accumulates over long walks and nothing here
  corrects it; a fifty-metre corridor will not close perfectly.
- No geoid model, so heights are ellipsoidal.
- UTM zones use the plain 6° rule; the Norway and Svalbard exceptions are not
  applied.
- The occlusion test for "which photos see this point" uses the cloud as a depth
  buffer, so it is approximate in sparsely scanned areas.
- Exports are built in the temporary directory and shared as a zip; very large
  scans need free space roughly equal to the export size.
