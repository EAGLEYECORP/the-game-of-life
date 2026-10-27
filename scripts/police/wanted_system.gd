class_name WantedSystem
extends Node
## The player's wanted level: 0 to 5 stars.
##
## Crimes add "heat", measured in stars (heat 1.6 = 1 star, 60% of the way to
## the second). Witnessing police make crimes count double. While police can
## see you, a long chase slowly escalates on its own. Once nobody has seen you
## for a while, you lose one star at a time, and the HUD stars flash meanwhile.
##
## Anything can report a crime with report_crime(); main.gd wires up the
## player, traffic and vehicle damage signals.

signal stars_changed(stars: int)
## true while some officer can see the player; false = they're searching.
signal seen_changed(seen: bool)

const MAX_STARS := 5

## Heat (in stars) each crime adds, and the minimum level it forces.
const CRIMES := {
	"hit_car": {"heat": 0.35, "min": 0},
	"hit_pedestrian": {"heat": 1.0, "min": 1},
	"ram_police": {"heat": 1.0, "min": 2},
	"carjack": {"heat": 0.6, "min": 0},
	"break_in": {"heat": 0.3, "min": 0},
	"shooting": {"heat": 1.0, "min": 1},    # Hook for when weapons exist.
}

## Seconds unseen before losing a star: base + per_star * current stars.
@export var escape_base := 10.0
@export var escape_per_star := 4.0
## Extra heat per second while police are chasing you in plain sight.
@export var chase_escalation := 0.012
## Police see this far (m), plus a bit more per star (helicopters, radios...).
@export var sight_range := 85.0
@export var sight_per_star := 15.0

var heat := 0.0
var stars := 0
var seen := false
## Seconds since police last saw the player (counts toward losing a star).
var unseen_time := 0.0

## Set by main.gd: answers "can any officer see this spot?"
var police: PoliceManager


## Reports a crime at `pos`. `witnessed` = police saw it happen.
func report_crime(kind: String, pos: Vector3) -> void:
	var crime: Dictionary = CRIMES.get(kind, {"heat": 0.5, "min": 0})
	var witnessed := police != null and police.can_see(pos, current_sight_range())
	heat += crime["heat"] * (2.0 if witnessed else 1.0)
	heat = maxf(heat, crime["min"])
	heat = minf(heat, MAX_STARS + 0.99)
	# A fresh crime means they know where you are.
	unseen_time = 0.0
	_update_stars()


## Clears everything (busted, cheats, story events).
func clear() -> void:
	heat = 0.0
	unseen_time = 0.0
	_update_stars()


func current_sight_range() -> float:
	return sight_range + sight_per_star * stars


## Seconds of hiding needed to drop the current star.
func escape_time() -> float:
	return escape_base + escape_per_star * stars


func _physics_process(delta: float) -> void:
	if stars == 0:
		# Minor offences below one star are forgotten after a while.
		heat = maxf(heat - 0.03 * delta, 0.0)
		return
	var now_seen := police != null and police.sees_player(current_sight_range())
	if now_seen != seen:
		seen = now_seen
		seen_changed.emit(seen)
	if seen:
		unseen_time = 0.0
		heat = minf(heat + chase_escalation * delta, MAX_STARS + 0.99)
	else:
		unseen_time += delta
		if unseen_time >= escape_time():
			# Lost them: drop one star and start the clock again.
			unseen_time = 0.0
			heat = float(stars - 1)
	_update_stars()


func _update_stars() -> void:
	var s := clampi(int(heat), 0, MAX_STARS)
	if s != stars:
		stars = s
		if stars == 0:
			heat = 0.0
			seen = false
		stars_changed.emit(stars)
