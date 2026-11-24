class_name HUD
extends CanvasLayer
## On-screen overlay: interaction hint, speedometer, vehicle condition and a
## controls cheat sheet.

@onready var _hint: Label = $Hint
@onready var _speedo: Label = $Speedometer
@onready var _vehicle_info: Label = $VehicleInfo
@onready var _controls: Label = $Controls
@onready var _district: Label = $District
@onready var _notice: Label = $Notice
@onready var _attribution: Label = $Attribution
@onready var minimap: Minimap = $Minimap
@onready var wanted_stars: WantedStars = $WantedStars
@onready var _clock: Label = $Clock
@onready var _radio: Label = $Radio

var _radio_timer := 0.0
@onready var _money: Label = $Money
@onready var _money_popup: Label = $MoneyPopup
@onready var _objective: Label = $Objective
@onready var _subtitle: Label = $Subtitle
@onready var _timer: Label = $Timer
@onready var _banner: Label = $Banner
@onready var _banner_sub: Label = $BannerSub
var _popup_time := 0.0
var _subtitle_time := 0.0
var _banner_time := 0.0

var _notice_timer := 0.0

## Vehicle shown on the speedometer, or null when on foot.
var _vehicle: Vehicle = null

const FOOT_CONTROLS := "WASD move  ·  Shift run  ·  Space jump  ·  F enter / steal vehicle\nMouse look  ·  C reset camera  ·  Esc free mouse"
const CAR_CONTROLS := "W/S throttle & brake  ·  A/D steer  ·  Space handbrake  ·  H horn  ·  L lights\nR / Q radio  ·  J taxi fares  ·  F get out  ·  Mouse look  ·  C reset camera  ·  hold T: fast time"


func _ready() -> void:
	set_hint("")
	show_vehicle(null)
	set_district("")
	set_notice("")
	set_attribution("")
	set_objective("")
	set_timer(-1.0)
	_subtitle.visible = false
	_banner.modulate.a = 0.0
	_banner_sub.modulate.a = 0.0
	_money_popup.modulate.a = 0.0


func _process(delta: float) -> void:
	_popup_time -= delta
	_money_popup.modulate.a = clampf(_popup_time, 0.0, 1.0)
	_subtitle_time -= delta
	_subtitle.visible = _subtitle_time > 0.0
	_banner_time -= delta
	_banner.modulate.a = clampf(_banner_time, 0.0, 1.0)
	_banner_sub.modulate.a = _banner.modulate.a
	if DayNightCycle.current:
		_clock.text = DayNightCycle.current.clock_text()
	if _radio_timer > 0.0:
		_radio_timer -= delta
		_radio.modulate.a = clampf(_radio_timer, 0.0, 1.0)
	if _notice_timer > 0.0:
		_notice_timer -= delta
		if _notice_timer <= 0.0:
			set_notice("")
	if _vehicle:
		_speedo.text = "%d km/h" % roundi(_vehicle.get_speed_kmh())
		var damage := _vehicle.get_node_or_null("Damage") as VehicleDamage
		var condition := "" if damage == null else "  ·  condition %d%%" % roundi(damage.condition)
		_vehicle_info.text = _vehicle.display_name + condition


func set_hint(text: String) -> void:
	_hint.text = text
	_hint.visible = text != ""


## Switches the HUD between on-foot and driving layouts.
func show_vehicle(vehicle: Vehicle) -> void:
	_vehicle = vehicle
	_speedo.visible = vehicle != null
	_vehicle_info.visible = vehicle != null
	_controls.text = CAR_CONTROLS if vehicle else FOOT_CONTROLS


## Current neighbourhood ("Old Medina", ...). Empty hides it.
func set_district(text: String) -> void:
	_district.text = text


## Centre-top message, e.g. while the map loads.
func set_notice(text: String) -> void:
	_notice.text = text
	_notice.visible = text != ""


## Data credit. OpenStreetMap's licence (ODbL) requires showing it.
func set_attribution(text: String) -> void:
	_attribution.text = text


## Shows a centre message for `seconds`, then hides it ("BUSTED", ...).
func flash_notice(text: String, seconds: float) -> void:
	set_notice(text)
	_notice_timer = seconds


## Radio station / song name, shown for a few seconds.
func show_radio(text: String) -> void:
	_radio.text = text
	_radio_timer = 4.0


## Wallet changed: show the total and a short "+400 DH" / "-150 DH" popup.
func set_money(total: int, delta: int, reason: String) -> void:
	_money.text = Wallet.format(total)
	if delta != 0:
		_money_popup.text = ("+" if delta > 0 else "") + Wallet.format(delta) + ("  " + reason if reason != "" else "")
		_money_popup.modulate = Color(0.5, 1, 0.55) if delta > 0 else Color(1, 0.45, 0.4)
		_popup_time = 3.0


## Current mission objective, bottom centre ("" hides it).
func set_objective(text: String) -> void:
	_objective.text = text
	_objective.visible = text != ""


## Countdown for timed objectives; negative hides it.
func set_timer(seconds: float) -> void:
	_timer.visible = seconds >= 0.0
	if seconds >= 0.0:
		_timer.text = "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]
		_timer.modulate = Color(1, 0.35, 0.3) if seconds < 10.0 else Color.WHITE


## Dialogue line for `seconds`.
func show_subtitle(text: String, seconds: float) -> void:
	_subtitle.text = text
	_subtitle_time = seconds


## Big centre title: mission names, "MISSION PASSED", "BUSTED"...
func show_banner(title: String, sub := "") -> void:
	_banner.text = title
	_banner_sub.text = sub
	_banner_time = 4.0
