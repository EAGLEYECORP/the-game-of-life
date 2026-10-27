extends Node3D
## Root of the game. Wires the player, camera and HUD together.
##
## The player only announces what happens (entered a car, hint changed...);
## this script decides who reacts. Keeping that wiring here means Player,
## Vehicle and CameraRig don't need to know about each other's scenes.

@onready var _player: Player = $Player
@onready var _camera: CameraRig = $CameraRig
@onready var _hud: HUD = $HUD


func _ready() -> void:
	_player.vehicle_entered.connect(_on_vehicle_entered)
	_player.vehicle_exited.connect(_on_vehicle_exited)
	_player.interaction_hint_changed.connect(_hud.set_hint)

	_camera.follow_player(_player)
	# Start right behind the player instead of swinging in from the origin.
	_camera.global_position = _player.global_position


func _on_vehicle_entered(vehicle: Vehicle) -> void:
	_camera.follow_vehicle(vehicle)
	_hud.show_vehicle(vehicle)


func _on_vehicle_exited(_vehicle: Vehicle) -> void:
	_camera.follow_player(_player)
	_hud.show_vehicle(null)
