# GTA CASA

An open-world driving sandbox set in Casablanca, built with **Godot 4.3+** and GDScript.

## Run it

1. Open Godot 4.3 (or newer) → **Import** → pick this folder's `project.godot`.
2. Press **Play** (F5). The main scene is `scenes/main.tscn`.
3. To play in the real Casablanca instead of the placeholder city, import the
   OpenStreetMap data once (see below).

## Controls

| Action | On foot | In vehicle |
|---|---|---|
| Move / drive | WASD or arrows | W throttle, S brake/reverse, A/D steer |
| Run | Shift | — |
| Jump / handbrake | Space | Space |
| Enter / exit vehicle | E (or F) near a driver's door | E |
| Look | Mouse / right stick | Mouse / right stick |
| Reset camera | C | C |
| Free / recapture mouse | Esc / click | Esc / click |

Gamepads work too (left stick, triggers, A, Y).

## The map: real Casablanca from OpenStreetMap

The world is built from [OpenStreetMap](https://www.openstreetmap.org) data and
streamed in 200 m chunks around the player. It covers five districts:

| District | What's there |
|---|---|
| Hassan II Mosque | The mosque, its esplanade and the 210 m minaret. **You spawn here, facing the ocean.** |
| Corniche - Ain Diab | The seafront boulevard, beaches and beach clubs |
| Twin Center - Maarif | The Twin Center towers and the busy Maarif grid |
| Old Medina | Dense low-rise lanes next to the port |
| Downtown (Art Deco) | Boulevard Mohammed V, Place Mohammed V, Marché Central |

Roads and coastline are fetched for the box enclosing all five, so you can
drive between districts.

**Until you import the data, the game runs on the procedural placeholder city**
and shows a notice at the top of the screen.

### Importing the OSM data (one time)

You need the Godot 4.3+ executable. Below it is called `godot`; on Windows use
the `Godot_v4.x-stable_win64_console.exe` that ships next to the normal exe.
Run the commands from this project folder.

```sh
# 1. Download from the Overpass API into data/osm/raw/.
godot --headless --path . --script res://tools/osm/fetch_osm.gd

# 2. Convert to game chunks in maps/casablanca_osm/ (manifest, skyline, chunks/).
godot --headless --path . --script res://tools/osm/import_osm.gd
```

3. Open the project in the editor (or refocus it so it rescans files) and press Play.

Commit `maps/casablanca_osm/` if you want teammates to skip the download. The raw
files are git-ignored.

**If the download fails** (Overpass is busy, or a firewall blocks it), get the
files by hand:

```sh
godot --headless --path . --script res://tools/osm/fetch_osm.gd -- --print-queries
```

This prints each query and the file name to save it as. Either paste a query into
<https://overpass-turbo.eu>, press *Run*, then *Export → raw data directly from
Overpass API*, or use curl:

```sh
curl -o data/osm/raw/roads_coast.json --data-urlencode "data@query.txt" https://overpass-api.de/api/interpreter
```

Any `*.json` in Overpass `out geom` format placed in `data/osm/raw/` gets
imported. Then run step 2. Behind a proxy, set `HTTPS_PROXY` and the fetch tool
will use it.

### How the import works

`tools/osm/import_osm.gd`:

- **Projection**: lat/lon becomes local metres around the Hassan II Mosque
  (+X east, -Z north).
- **Buildings**: footprints are extruded to a height taken from, in order: the
  `height` tag, then `building:levels` × 3.2 m, then known names (Twin Center
  115 m...), then the building type, then a stable random value in the district's
  typical range (Medina 5-10 m, Downtown 14-24 m...). Tall `building:part`s
  such as minarets are kept. If the minaret is missing from OSM, a 210 m
  stand-in is added.
- **Roads**: each `highway=*` becomes a flat ribbon with collision, sized by type
  (or the `width`/`lanes` tags). Car roads are asphalt; footways and plazas are
  lighter paving. Tunnels are skipped.
- **Land and sea**: the coastline is rasterised at 10 m into a land mask. Land
  becomes walkable ground with collision; the rest is open sea. Driving or
  falling into the sea respawns you at your last spot on dry ground.
- **Parks, beaches, plazas** are drawn as coloured ground.
- **Chunks**: features are sorted into 200 m tiles. Buildings 60 m or taller
  go into `skyline.json`, which is always loaded so landmarks stay visible.
- **Spawn**: the configured point is snapped to the nearest road and turned to
  face the nearest sea. Three parking spots are picked on nearby streets, on the
  right-hand side of the road.

Everything you'd want to tweak (areas, spawn, heights, road widths, chunk size)
is in `tools/osm/osm_config.gd`. Change it and re-run step 2 (and step 1 if you
changed the areas).

### Streaming at runtime

`scripts/world/osm/chunk_streamer.gd` keeps chunks within 500 m of the player
loaded and frees them past 700 m:

- Files are read and turned into geometry on worker threads, then added two per
  frame, so there are no big hitches.
- Each chunk is a single mesh (one draw call) plus one static trimesh collider.
- While the area around the spawn loads, the player is held in place.
- Parked cars stay frozen until the ground under them exists.

Tune `load_radius`, `unload_radius` and `max_chunks_per_frame` on the
`ChunkStreamer` node in `maps/casablanca.tscn`.

### Exporting a build

The chunks are plain `.json` files. In *Project → Export → Resources*, add
`maps/casablanca_osm/*` to *Filters to export non-resource files/folders*.

### Licence

Map data © OpenStreetMap contributors, available under the
[Open Database Licence](https://www.openstreetmap.org/copyright). The credit is
shown in the bottom-right corner of the HUD. Keep it there if you ship the game.

## Project layout

```
project.godot
scenes/
  main.tscn                 Game root: map + player + cars + camera + HUD
  player/player.tscn        CharacterBody3D on-foot character
  vehicles/vehicle.tscn     VehicleBody3D car (4 raycast wheels)
  camera/camera_rig.tscn    Third-person orbit camera with SpringArm3D
  ui/hud.tscn               Hint, district, speedometer, controls, credits
scripts/
  autoload/input_setup.gd   Registers all input actions at startup
  main.gd                   Wiring + spawn, respawn-from-sea, car freezing
  player/player.gd          Walk / run / jump, enter & exit vehicles
  vehicles/vehicle.gd       Driving, braking, speed-sensitive steering, exit spot
  camera/camera_rig.gd      Orbit, collision, per-mode framing, auto-recentre
  ui/hud.gd
  world/osm/chunk_streamer.gd  Loads/unloads map chunks around the player
  world/osm/chunk_builder.gd   Chunk JSON -> mesh + collision (thread-safe)
  world/city_generator.gd      Procedural placeholder city (fallback)
tools/osm/
  osm_config.gd             Areas, spawn, heights, widths: all import settings
  fetch_osm.gd              Downloads OSM data from Overpass
  import_osm.gd             Builds maps/casablanca_osm/ from the raw data
maps/
  casablanca.tscn           Sky, sun, sea and the ChunkStreamer
  placeholder_city.tscn     Fallback city used when no OSM data is imported
  casablanca_osm/           Generated by import_osm.gd (manifest, skyline, chunks)
data/osm/raw/               Raw Overpass downloads (git-ignored)
assets/                     models/, textures/, audio/, fonts/ (empty for now)
```

## How the pieces talk

- `Player` emits `vehicle_entered`, `vehicle_exited` and `interaction_hint_changed`.
  `main.gd` routes them to the `CameraRig` and `HUD`, so those scenes stay independent.
- Vehicles join the `vehicles` group. The player looks for the closest free one
  within `vehicle_reach` of its `DoorExit` marker.
- While driving, the player node is hidden, collision-free and paused, and the
  vehicle keeps it positioned at the `Seat` marker. On exit the vehicle checks
  the driver door, then the passenger side, then the roof for free space.
- `ChunkStreamer` follows the player node, which works in a car too because the
  hidden player rides along in the seat. It emits `initial_area_ready` once the
  spawn area has loaded.
- Physics layers: 1 = world, 2 = player, 3 = vehicles.

## Adding things

- **New car**: instance `scenes/vehicles/vehicle.tscn` and set `display_name`,
  `paint_color`, and the engine/steering exports in the inspector. The first
  three cars under `Vehicles` are moved to the importer's parking spots.
- **Different spawn or districts**: edit `tools/osm/osm_config.gd`, then re-import.
- **Rebinding keys**: define an action in *Project Settings → Input Map* and it
  replaces the defaults from `input_setup.gd`.
