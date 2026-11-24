class_name SaveGame
extends RefCounted
## A tiny JSON save file in the user data folder (user://gta_casa_save.json).
##
## Systems merge their own keys in with store() and read them with
## load_data(). Delete the file to start over.

const PATH := "user://gta_casa_save.json"

## Set to false in tests or tools that must not touch the player's save.
static var enabled := true
static var _cache: Dictionary = {}
static var _loaded := false


static func load_data() -> Dictionary:
	if not _loaded:
		_loaded = true
		if enabled and FileAccess.file_exists(PATH):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(PATH))
			if typeof(parsed) == TYPE_DICTIONARY:
				_cache = parsed
	return _cache


## Merges `values` into the save and writes it.
static func store(values: Dictionary) -> void:
	load_data()
	_cache.merge(values, true)
	if not enabled:
		return
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_cache, "\t"))


## Forgets everything (new game).
static func reset() -> void:
	_cache = {}
	_loaded = true
	if enabled and FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
