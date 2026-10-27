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

## City life: traffic, pedestrians, traffic lights

`scripts/traffic/` brings the streets to life around the player.

**AI traffic** (`traffic_car.gd`) follows the real road network. It drives on
the right, respects one-way streets, picks turns at junctions (preferring main
roads) and slows for corners and for anything ahead. State machine:
- `DRIVE`: normal driving.
- `WAIT_LIGHT`: stopped at a red light.
- `BLOCKED`: something is in the way. If it's you, the driver leans on the horn
  after 1.5 s.
- `PANIC`: you rammed it. It honks, then speeds off ignoring lights for 6 s.

Press **F** at an AI car's door to **carjack** it. The car becomes a normal
drivable vehicle and its driver jumps out and runs.

**Pedestrians** (`pedestrian.gd`) walk the pavements beside roads and the
middle of footways, pausing now and then. State machine:
- `WALK` and `IDLE`: normal walking and pausing.
- `SIDESTEP`: you walked into them.
- `FLEE`: a car is coming at them; they dive aside.
- `KNOCKED` and `GET_UP`: hit by your car. They fall over, get up and run, and
  people nearby scatter too.

About a third wear djellabas.

**Traffic lights** (`road_graph.gd`) go on OSM's tagged `traffic_signals`
junctions, or on crossings of main roads when the data has none. Each junction
splits its roads into two groups running a 33 s cycle (green 12 s, amber 3 s,
all-red 1.5 s, then the other group). Posts are built only within 220 m of the
player.

**Density** follows the district (`traffic` / `pedestrians` in
`OsmConfig.AREAS`):

| District | Traffic | Pedestrians |
|---|---|---|
| Corniche - Ain Diab | 1.6× | 1.4× |
| Downtown (Art Deco) | 1.6× | 1.3× |
| Twin Center - Maarif | 1.3× | 1.1× |
| Hassan II Mosque | 1.0× | 1.2× |
| Old Medina | 0.35× (narrow lanes) | 1.6× |

**Performance**:
- One `TrafficManager` loop moves every agent. Decisions run 10 times a second
  per agent, spread evenly across frames.
- AI cars are kinematic bodies with no wheel physics, each a single pre-baked,
  vertex-coloured mesh (one draw call instead of about 30). Pedestrians have no
  physics at all, and their limbs only animate within 60 m.
- Agents exist only in a ring around the player. Cars spawn 90–240 m away and
  are recycled past 300 m; pedestrians spawn 45–130 m away and are recycled
  past 160 m.
- "What's ahead?" checks use a 12 m spatial grid rebuilt once per frame.
- Light states are a pure function of time.
- Parked cars spawn a few per frame instead of all at once.

In testing, the traffic system cost about 0.6 ms per physics frame on average
with 34 cars and 50 pedestrians.

Tune `max_cars`, `max_pedestrians`, the spawn rings and `light_radius` on the
`Traffic` node in `main.tscn`. Parked cars sit half on the pavement, Casablanca
style, so they stay out of the traffic lanes.

> Traffic needs `maps/casablanca_osm/traffic.json`, written by the importer.
> If you imported before this feature, re-run both OSM steps (the fetch now
> also downloads traffic lights). The placeholder city has traffic built in.

## Wanted level and police

`scripts/police/` adds a 1–5 star wanted system, shown as stars in the top
right.

**Crimes** add "heat" measured in stars (`wanted_system.gd`):

| Crime | Heat | Minimum |
|---|---|---|
| Hitting another car (only if you drove into it) | +0.35 | — |
| Knocking down a pedestrian | +1 | 1★ |
| Ramming a police car | +1 | 2★ |
| Carjacking an AI driver | +0.6 | — |
| Breaking into a locked car | +0.3 | — |
| Shooting (`report_crime("shooting", pos)`, for later) | +1 | 1★ |

Crimes count double when police see them. A chase in plain sight slowly adds
heat on its own. Heat below one star fades away.

**Escaping**: police need line of sight, checked with raycasts against
buildings, within 85 m plus 15 m per star. Once nobody can see you, the stars
flash, and after 10 s + 4 s per star you lose **one** star. Stay hidden to
keep dropping.

**Police** (`police_manager.gd`) dispatch 2/3/4/5/7 cars for 1–5 stars. They
spawn out of sight on the road network and drive real physics cars (white with
blue stripes, red/blue light bar, two-tone siren), so they can ram you and you
can ram them. AI traffic pulls over to the kerb when a siren comes up behind.

- **Pathfinding**: a single Dijkstra "flow field" over the road graph spreads
  out from your junction and is refreshed every second. Every unit follows its
  junction's "next road" pointer, so one search serves the whole force. Police
  ignore one-way streets.
- **States**:
  - `RESPOND`: follow the roads toward you.
  - `PURSUE`: within 55 m, drive at your predicted position and shadow your car.
  - `RAM` (5★): wider pursuit range, much faster, aims to hit you, handbrakes
    round corners.
  - `ARREST`: you're on foot, so they pull up beside you.
  - `REVERSE`: stuck, so back up and turn.
  - `LEAVE`: you're clear, so siren off, drive away, despawn.
- **Busted**: stay (nearly) still for 3 s with an officer right next to you
  while wanted. You lose the car and the stars, and wake up at the spawn point.

## Minimap

Bottom left (`scripts/ui/minimap.gd`). It rotates with the camera and draws the
real road network: main roads thicker, footways faint. It shows:
- **you:** an arrow;
- **drivable vehicles:** grey squares;
- **AI traffic:** pale dots;
- **police:** flashing red/blue dots, pinned to the rim when out of range.

It zooms out as you speed up, and the rim flashes red/blue while you're wanted.

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
- **Parking spots**: one every 45 m along car roads, half on the pavement,
  stored per chunk for `VehicleSpawner`.
- **Road graph** (`traffic.json`): roads split at shared OSM nodes into
  junctions and edges, with width, class, one-way and pedestrian-only flags,
  plus the traffic-light junctions.

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
  vehicles/*.tscn           Petit Taxi, Mobylette, Medina Sedan, Grand Taxi, Atlas Royale, Police
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
  traffic/traffic_manager.gd   Spawns/updates AI cars, pedestrians, light posts
  traffic/traffic_car.gd       AI car: lane following + state machine
  traffic/pedestrian.gd        Pedestrian: pavement walking + state machine
  traffic/road_graph.gd        Road network, lanes, junction choices, light timing
  traffic/npc_visuals.gd       Baked NPC meshes (cars, people, light posts)
  police/wanted_system.gd      Stars, crimes, line of sight, escaping
  police/police_manager.gd     Dispatch, road flow field, chase state machine, busted
  ui/minimap.gd                Rotating radar with roads, vehicles, police
  ui/wanted_stars.gd           The five stars
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
  casablanca_osm/           Generated by import_osm.gd (manifest, skyline, traffic, chunks)
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
