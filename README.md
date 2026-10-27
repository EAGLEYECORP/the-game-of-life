# GTA CASA

An open-world driving sandbox set in Casablanca, built with **Godot 4.3+** and GDScript.

## Run it

1. Open Godot 4.3 (or newer) → **Import** → pick this folder's `project.godot`.
2. Press **Play** (F5). The main scene is `scenes/main.tscn`.

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

## Project layout

```
project.godot
scenes/
  main.tscn                 Game root: map + player + cars + camera + HUD
  player/player.tscn        CharacterBody3D on-foot character
  vehicles/vehicle.tscn     VehicleBody3D car (4 raycast wheels)
  camera/camera_rig.tscn    Third-person orbit camera with SpringArm3D
  ui/hud.tscn               Hint, speedometer, controls
scripts/
  autoload/input_setup.gd   Registers all input actions at startup
  main.gd                   Wires player ↔ camera ↔ HUD via signals
  player/player.gd          Walk / run / jump, enter & exit vehicles
  vehicles/vehicle.gd       Driving, braking, speed-sensitive steering, exit spot
  camera/camera_rig.gd      Orbit, collision, per-mode framing, auto-recentre
  ui/hud.gd
  world/city_generator.gd   Procedural placeholder Casablanca (@tool)
maps/
  casablanca.tscn           Sky, sun, and the generated city
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
- Physics layers: 1 = world, 2 = player, 3 = vehicles.

## Adding things

- **New car**: instance `scenes/vehicles/vehicle.tscn` and set `display_name`,
  `paint_color`, and the engine/steering exports in the inspector.
- **City**: tweak the exports on the `City` node in `maps/casablanca.tscn` (seed,
  block count, road width, park chance) and tick *regenerate* to preview the
  result in the editor. Origin (0, 0) is always a road intersection.
- **Rebinding keys**: define an action in *Project Settings → Input Map* and it
  replaces the defaults from `input_setup.gd`.
