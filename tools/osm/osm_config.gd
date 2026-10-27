class_name OsmConfig
extends RefCounted
## Settings shared by the OSM fetch and import tools.
##
## Everything about *which* part of Casablanca we build lives here: the focus
## areas, the spawn point, chunk size and how tall buildings should be when OSM
## doesn't say. Change a value, re-run the import, and the game picks it up.
##
## Bounding boxes are [south, west, north, east] in degrees (Overpass order).

## World origin. Local (0, 0, 0) is this lat/lon; +X = east, -Z = north.
## Placed on the Hassan II Mosque so the landmark sits at the centre of the map.
const ORIGIN_LAT := 33.6083
const ORIGIN_LON := -7.6325

## Where the player starts. The importer snaps this to the nearest road or
## pedestrian way and turns the player to face the nearest sea.
const SPAWN_LAT := 33.6066
const SPAWN_LON := -7.6330

## Key areas. Buildings are fetched for each box; roads and coastline for the
## box enclosing all of them, so you can drive between areas.
## `heights` = [min, max] metres used when OSM has no height for a building.
## `palette` = facade colours picked per building in that area.
## `traffic` / `pedestrians` = density multipliers for AI cars and walkers
## (1.0 = normal): busy Corniche and downtown, narrow car-free Medina lanes
## full of people.
const AREAS := [
	{
		"name": "Hassan II Mosque",
		"traffic": 1.0, "pedestrians": 1.2,
		"bbox": [33.600, -7.645, 33.614, -7.620],
		"heights": [8.0, 18.0],
		"palette": [Color(0.96, 0.95, 0.92), Color(0.93, 0.90, 0.84), Color(0.88, 0.84, 0.76)],
	},
	{
		"name": "Corniche - Ain Diab",
		"traffic": 1.6, "pedestrians": 1.4,
		"bbox": [33.585, -7.705, 33.610, -7.645],
		"heights": [6.0, 15.0],
		"palette": [Color(0.97, 0.96, 0.94), Color(0.92, 0.88, 0.80), Color(0.82, 0.88, 0.92)],
	},
	{
		"name": "Twin Center - Maarif",
		"traffic": 1.3, "pedestrians": 1.1,
		"bbox": [33.578, -7.645, 33.594, -7.622],
		"heights": [12.0, 30.0],
		"palette": [Color(0.90, 0.90, 0.88), Color(0.80, 0.82, 0.84), Color(0.94, 0.92, 0.86)],
	},
	{
		"name": "Old Medina",
		"traffic": 0.35, "pedestrians": 1.6,
		"bbox": [33.598, -7.626, 33.608, -7.610],
		"heights": [5.0, 10.0],
		"palette": [Color(0.97, 0.96, 0.93), Color(0.90, 0.82, 0.68), Color(0.86, 0.76, 0.60)],
	},
	{
		"name": "Downtown (Art Deco)",
		"traffic": 1.6, "pedestrians": 1.3,
		"bbox": [33.586, -7.626, 33.600, -7.605],
		"heights": [14.0, 24.0],
		"palette": [Color(0.95, 0.93, 0.86), Color(0.92, 0.88, 0.78), Color(0.98, 0.97, 0.94)],
	},
]

## Default height range / palette for buildings outside every area (only used
## with FETCH_BUILDINGS_EVERYWHERE).
const DEFAULT_HEIGHTS := [8.0, 18.0]
const DEFAULT_PALETTE := [Color(0.94, 0.92, 0.88), Color(0.88, 0.85, 0.78)]

## true = fetch buildings for the whole enclosing box, not only the areas.
## Fills the gaps between districts but makes the download ~2x bigger.
const FETCH_BUILDINGS_EVERYWHERE := false

## Typical heights (m) per OSM building=* value, used before the area range.
const TYPE_HEIGHTS := {
	"house": 7.0, "detached": 7.0, "villa": 8.0, "residential": 12.0,
	"apartments": 18.0, "commercial": 12.0, "retail": 6.0, "office": 24.0,
	"hotel": 22.0, "industrial": 9.0, "warehouse": 9.0, "mosque": 16.0,
	"school": 10.0, "university": 14.0, "hospital": 16.0, "church": 18.0,
	"garage": 3.0, "garages": 3.0, "shed": 3.0, "roof": 4.0, "kiosk": 3.0,
	"hut": 3.0, "service": 4.0, "train_station": 12.0, "stadium": 20.0,
}
const LEVEL_HEIGHT := 3.2      ## Metres per floor for building:levels.

## Buildings whose OSM data often lacks a height. Matched by name (substring,
## case-insensitive) and only applied when OSM gives no height itself.
const NAME_HEIGHT_OVERRIDES := {
	"twin center": 115.0,
	"hassan ii": 30.0,      # Prayer hall; the minaret is handled below.
	"casablanca finance city tower": 122.0,
}

## Landmarks added if OSM doesn't already contain a building that tall nearby.
## The Hassan II minaret (210 m) is usually a building:part in OSM; if your
## extract lacks it, this box stands in. Footprint size is in metres.
const LANDMARK_FALLBACKS := [
	{"name": "Hassan II Minaret", "lat": 33.6079, "lon": -7.6320,
		"size": 25.0, "height": 210.0, "color": Color(0.93, 0.90, 0.84)},
]

## Parked-car spots: one every PARKING_SPACING metres along car roads, on the
## kerb side. VehicleSpawner fills some of them as chunks stream in.
const PARKING_SPACING := 45.0
## How many vehicles to line up near the player spawn (one of each type).
const STARTER_VEHICLES := 5

## Traffic lights: OSM traffic_signals nodes are snapped to the nearest
## junction within this distance. Without any in the data, crossroads where
## main roads (primary/secondary/tertiary) cross or meet get lights instead,
## at least 1.8 x SIGNAL_MIN_SPACING apart.
const SIGNAL_SNAP := 25.0
const SIGNAL_MIN_SPACING := 45.0   ## Merge clusters (dual carriageways).

## Streaming grid. Each chunk is CHUNK_SIZE x CHUNK_SIZE metres.
const CHUNK_SIZE := 200.0
## Land/sea mask resolution in metres (coastline -> walkable ground).
const LAND_CELL := 10.0
## Buildings at least this tall go into the always-loaded skyline file so they
## stay visible from far away.
const SKYLINE_MIN_HEIGHT := 60.0

## Road widths (m) per highway=* value. Values not listed are skipped.
const ROAD_WIDTHS := {
	"motorway": 16.0, "motorway_link": 8.0, "trunk": 14.0, "trunk_link": 7.0,
	"primary": 12.0, "primary_link": 7.0, "secondary": 10.0, "secondary_link": 6.0,
	"tertiary": 8.0, "tertiary_link": 5.0, "unclassified": 6.0, "residential": 6.0,
	"living_street": 5.0, "service": 4.0, "road": 6.0,
	"pedestrian": 6.0, "footway": 2.5, "path": 2.0, "cycleway": 2.0, "track": 3.0,
}
## Road kinds cars are meant to use (others are drawn lighter, as paving).
const CAR_ROADS := [
	"motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
	"secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
	"residential", "living_street", "service", "road",
]

## Where raw Overpass downloads go and where the game reads imported chunks.
const RAW_DIR := "res://data/osm/raw"
const OUT_DIR := "res://maps/casablanca_osm"

## Overpass servers tried in order by the fetch tool.
const OVERPASS_URLS := [
	"https://overpass-api.de/api/interpreter",
	"https://overpass.kumi.systems/api/interpreter",
]


## Box enclosing every area, [s, w, n, e].
static func union_bbox() -> Array:
	var b: Array = AREAS[0]["bbox"].duplicate()
	for area in AREAS:
		var a: Array = area["bbox"]
		b = [minf(b[0], a[0]), minf(b[1], a[1]), maxf(b[2], a[2]), maxf(b[3], a[3])]
	return b


## Lat/lon -> local metres (equirectangular around the origin; accurate to
## centimetres over a city this size).
static func project(lat: float, lon: float) -> Vector2:
	var x := (lon - ORIGIN_LON) * 111320.0 * cos(deg_to_rad(ORIGIN_LAT))
	var z := -(lat - ORIGIN_LAT) * 110574.0
	return Vector2(x, z)
