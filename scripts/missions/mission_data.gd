class_name MissionData
extends RefCounted
## The story missions, as data. MissionManager runs them step by step.
##
## Locations are described, not hard-coded, so missions work on the real OSM
## map and on the placeholder city alike:
##   {"at": "garage"}                       Youssef's garage (set at game start)
##   {"at": "point", "key": "pickup"}       a point an earlier step saved
##   {"at": "near", "of": "garage", "min": 80, "max": 160}
##                                          a spot on a road that far from
##                                          "garage" / "player" / a saved point
##   {"at": "area", "name": "Old Medina"}   inside an OSM district (falls back
##                                          to a spot 250-500 m away)
##   {"at": "coast"}                        the road closest to the sea
##
## Step types (see MissionManager._start_step):
##   talk           lines of dialogue, shown as subtitles
##   spawn_vehicle  park a mission vehicle (spawned once the player is close)
##   enter_vehicle  get in that vehicle (id) or any vehicle of a type
##   goto           reach a place (optionally in the mission vehicle)
##   pickup/dropoff a passenger waits at a place / gets out at a place
##   wait           pause (loading cargo...)
##   add_wanted     police get involved
##   lose_wanted    escape the police
##   race           drive through generated checkpoints against the clock
## Mission-wide rules: "min_condition" (vehicle damage limit), "keep_vehicle"
## (fail if you abandon the mission vehicle).
##
## Dialogue mixes Darija (transliterated) with translations in brackets.

const CONTACTS := {
	"youssef": {"name": "Youssef", "letter": "Y", "loc": {"at": "garage"}},
	"hajj": {"name": "L'Hajj Abdelkader", "letter": "H", "loc": {"at": "area", "name": "Old Medina"}},
	"rachid": {"name": "Rachid", "letter": "R", "loc": {"at": "coast"}},
}

const MISSIONS := [
	{
		"id": "welcome",
		"title": "Mrehba f Casa",
		"contact": "youssef",
		"requires": [],
		"reward": 300,
		"steps": [
			{"type": "talk", "lines": [
				"Youssef: Mrehba bik a khouya! (Welcome, brother!) Casa missed you.",
				"Youssef: My old Petit Taxi is parked down the street. Bring it back to the garage.",
				"Youssef: B-chwiya, eh? (Easy does it.) It's older than both of us.",
			]},
			{"type": "spawn_vehicle", "id": "taxi", "scene": "petit_taxi", "loc": {"at": "near", "of": "garage", "min": 70, "max": 150}},
			{"type": "enter_vehicle", "id": "taxi", "text": "Get in Youssef's Petit Taxi"},
			{"type": "goto", "loc": {"at": "garage"}, "vehicle": "taxi", "text": "Drive the taxi back to Youssef's garage"},
			{"type": "talk", "lines": ["Youssef: Tbarkallah 3lik! (Well done!) Here, for the petrol."]},
		],
	},
	{
		"id": "taxi_rouge",
		"title": "Taxi Rouge",
		"contact": "youssef",
		"requires": ["welcome"],
		"reward": 400,
		"steps": [
			{"type": "talk", "lines": [
				"Youssef: A regular of mine needs a ride and I'm stuck under a Mercedes.",
				"Youssef: Take the taxi, pick her up, and don't keep her waiting. Yallah!",
			]},
			{"type": "spawn_vehicle", "id": "taxi", "scene": "petit_taxi", "loc": {"at": "near", "of": "garage", "min": 8, "max": 30}},
			{"type": "enter_vehicle", "id": "taxi", "text": "Get in the Petit Taxi"},
			{"type": "pickup", "loc": {"at": "near", "of": "garage", "min": 150, "max": 280}, "save_as": "pickup",
				"text": "Pick up the passenger"},
			{"type": "talk", "lines": ["Passenger: Salam! Downtown please, and vite, I'm late!"]},
			{"type": "dropoff", "loc": {"at": "near", "of": "pickup", "min": 250, "max": 450}, "timed": true,
				"text": "Drive the passenger to her stop"},
			{"type": "talk", "lines": ["Passenger: Bsahtek! (Good for you!) Fastest taxi in Casa."]},
		],
	},
	{
		"id": "colis_fragile",
		"title": "Colis fragile",
		"contact": "hajj",
		"requires": ["welcome"],
		"reward": 600,
		"min_condition": 60.0,
		"keep_vehicle": "moby",
		"steps": [
			{"type": "talk", "lines": [
				"L'Hajj: Ah, Youssef's cousin. I have pottery from Fès for a shop in Maarif.",
				"L'Hajj: Take my mobylette. If one plate breaks, hchouma 3lik! (Shame on you!)",
			]},
			{"type": "spawn_vehicle", "id": "moby", "scene": "mobylette", "loc": {"at": "near", "of": "player", "min": 6, "max": 25}},
			{"type": "enter_vehicle", "id": "moby", "text": "Get on L'Hajj's mobylette"},
			{"type": "goto", "loc": {"at": "near", "of": "player", "min": 120, "max": 220}, "vehicle": "moby", "save_as": "potter",
				"text": "Collect the pottery"},
			{"type": "wait", "seconds": 3.0, "text": "Loading the pottery..."},
			{"type": "goto", "loc": {"at": "area", "name": "Twin Center - Maarif"}, "vehicle": "moby",
				"text": "Deliver the pottery to Maarif. Don't crash!"},
			{"type": "talk", "lines": ["Shopkeeper: Kolchi mzyan! (All good!) Not a single crack. Tell L'Hajj thanks."]},
		],
	},
	{
		"id": "hajj_car",
		"title": "Tomobil dyal L'Hajj",
		"contact": "hajj",
		"requires": ["colis_fragile"],
		"reward": 1500,
		"keep_vehicle": "royale",
		"steps": [
			{"type": "talk", "lines": [
				"L'Hajj: A man owes me money and drives around in MY Atlas Royale.",
				"L'Hajj: Bring it to Youssef's garage. The neighbours will call the police, so be quick.",
			]},
			{"type": "spawn_vehicle", "id": "royale", "scene": "atlas_royale", "locked": true,
				"loc": {"at": "near", "of": "player", "min": 220, "max": 420}},
			{"type": "enter_vehicle", "id": "royale", "text": "Take back L'Hajj's Atlas Royale"},
			{"type": "add_wanted", "stars": 2},
			{"type": "lose_wanted", "text": "Lose the police"},
			{"type": "goto", "loc": {"at": "garage"}, "vehicle": "royale", "text": "Deliver the car to Youssef's garage"},
			{"type": "talk", "lines": ["Youssef: Wah! L'Hajj's car? Safi, safi, I didn't see anything."]},
		],
	},
	{
		"id": "corniche_race",
		"title": "Course de la Corniche",
		"contact": "rachid",
		"requires": ["taxi_rouge"],
		"reward": 1000,
		"steps": [
			{"type": "talk", "lines": [
				"Rachid: They say you drive like a petit taxi on a Friday afternoon.",
				"Rachid: Beat my time through the checkpoints and the money's yours. Zid!",
			]},
			{"type": "spawn_vehicle", "id": "racer", "scene": "medina_sedan", "loc": {"at": "near", "of": "player", "min": 6, "max": 25}},
			{"type": "enter_vehicle", "id": "racer", "any_vehicle": true, "text": "Get in a car"},
			{"type": "race", "checkpoints": 8, "spacing": 90.0, "text": "Race through the checkpoints"},
			{"type": "talk", "lines": ["Rachid: Ma3lich... (Never mind...) You're faster than you look."]},
		],
	},
]


static func get_mission(id: String) -> Dictionary:
	for m in MISSIONS:
		if m["id"] == id:
			return m
	return {}
