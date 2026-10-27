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
| Jump / handbrake | Space | Space (drift) |
| Enter / exit / steal | **F** (or E) near a driver's door | **F** |
| Horn | — | H |
| Headlights | — | L |
| Look | Mouse / right stick | Mouse / right stick |
| Reset camera | C | C |
| Free / recapture mouse | Esc / click | Esc / click |

Gamepads work too: left stick, triggers, A (jump/handbrake), Y (enter/exit),
LB (horn), D-pad up (lights).

## Vehicles

| Vehicle | Type | Feel | Top speed |
|---|---|---|---|
| **Petit Taxi** | Red city hatch with a lit white "PETIT TAXI" roof sign and its licence number on the doors | Nimble, quick off the line; the horn you'll hear all over Casablanca | 150 km/h |
| **Mobylette** | The 2-stroke moped of Moroccan streets, with a visible rider | Buzzy, light, leans into corners, squeezes through gaps | 60 km/h |
| **Medina Sedan** | Everyday family saloon in everyday colours | Balanced, front-wheel drive | 165 km/h |
| **Grand Taxi** | Old cream intercity saloon with roof rack and luggage | Heavy, soft and wallowy; rear-wheel drive, old diesel rattle and bleat | 135 km/h |
| **Atlas Royale** | Luxury limousine with chrome trim | Fast, planted, rear-wheel drive with a V8 burble | 230 km/h |

Each type is a scene in `scenes/vehicles/` running the same scripts with its
own tuning. Select its root node to tweak engine, steering, grip, camera and
paint in the inspector.

**Handling** (`scripts/vehicles/vehicle.gd`) is Godot's `VehicleBody3D` with
arcade helpers on top:
- **Engine:** a punchy pull off the line that tapers toward top speed.
- **Grip assist:** removes most sideways sliding. The handbrake relaxes it and
  loosens the rear wheels for drifts.
- **Stability:** downforce at speed and an upright torque against rollovers.
  If you do end up on the roof, the vehicle flips back after 2 s.
- **Scooters** ride on four narrow hidden wheels for stability and lean visually
  into turns.

**Components**: each vehicle scene has three child nodes:
- `Lights` (`vehicle_lights.gd`): headlights with real spotlights, tail lights
  that brighten when braking, the taxi roof sign, and alarm flashing.
- `Sounds` (`vehicle_sounds.gd`): engine and horn, synthesised in code by
  `sound_synth.gd` (no audio files). The engine pitch climbs through fake gears.
- `Damage` (`vehicle_damage.gd`): visual only. Crashes are detected from sudden
  velocity changes. The bodywork nearest the hit gets dented and the paint
  dirtier. Hard hits crack windows and break headlights, and the engine smokes
  below 50% condition (black smoke below 20%). The HUD shows the condition.

**Stealing**: `VehicleSpawner` (`ParkedVehicles` in `main.tscn`) parks
random vehicles on the streets as map chunks stream in and removes them when
the chunk streams out. Taxis and mobylettes are the most common. About 40% are
locked: press F and the player spends a moment breaking in, then the alarm
goes off (horn and lamps pulse) and you drive away. The last vehicle you drove
is never removed. One of each type also waits next to the spawn point.

The camera glides to each vehicle's own framing when you get in. The scooter
sits close and low, the limousine further back. The FOV widens with speed.

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
  face the nearest sea. Five starter spots are picked on nearby streets, on the
  right-hand side of the road.
- **Parking spots**: one every 45 m along car roads, kerb side, stored per
  chunk for `VehicleSpawner`.

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
  vehicles/*.tscn           Petit Taxi, Mobylette, Medina Sedan, Grand Taxi, Atlas Royale
  camera/camera_rig.tscn    Third-person orbit camera with SpringArm3D
  ui/hud.tscn               Hint, district, speedometer, controls, credits
scripts/
  autoload/input_setup.gd   Registers all input actions at startup
  main.gd                   Wiring + spawn, respawn-from-sea, car freezing
  player/player.gd          Walk / run / jump, enter & exit vehicles
  vehicles/vehicle.gd       Arcade driving, enter/exit, locks, alarm
  vehicles/vehicle_lights.gd   Headlights, brake lights, taxi sign
  vehicles/vehicle_sounds.gd   Engine + horn players
  vehicles/sound_synth.gd      Generates horn/engine sounds in code
  vehicles/vehicle_damage.gd   Visual damage: dents, smoke, cracked glass
  vehicles/vehicle_spawner.gd  Parks stealable vehicles around the streamed map
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

- **New vehicle type**: duplicate the closest scene in `scenes/vehicles/`,
  change its meshes and tuning, then add it to `vehicle_scenes` and `weights`
  on the `ParkedVehicles` node. Naming conventions under `Body`: `Paint*` meshes
  get the paint colour, `Headlight*`/`Taillight*`/`TaxiSign*` meshes glow,
  `HeadlightBeam*` spotlights light the road, `Glass*` meshes can crack, and
  `Rider` is shown while driven. The vehicles under `Vehicles` in `main.tscn`
  are moved to the importer's starter spots near the spawn.
- **Different spawn or districts**: edit `tools/osm/osm_config.gd`, then re-import.
- **Rebinding keys**: define an action in *Project Settings → Input Map* and it
  replaces the defaults from `input_setup.gd`.
