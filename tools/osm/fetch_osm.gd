extends SceneTree
## Downloads the OpenStreetMap data for GTA CASA from the Overpass API.
##
## Run from the project folder (Godot 4.3+ executable on your PATH as `godot`):
##
##   godot --headless --script res://tools/osm/fetch_osm.gd
##
## Optional arguments after `--`:
##   --print-queries   Only print the Overpass queries (to paste into
##                     https://overpass-turbo.eu and export manually).
##   --area=N          Only fetch area number N (0-based) plus roads/coast.
##
## Output: one JSON file per request in data/osm/raw/. Then run import_osm.gd.
##
## Data © OpenStreetMap contributors, ODbL. Please keep requests modest: the
## script runs them one at a time, as Overpass asks.

const TIMEOUT_S := 300


func _initialize() -> void:
	_run()


func _run() -> void:
	# Nodes (HTTPRequest) only work once the tree is running.
	await process_frame
	var args := _parse_args()
	var jobs := _build_jobs(args)

	if args.has("print-queries"):
		for job in jobs:
			print("\n# --- %s (save as %s) ---\n%s" % [job.label, job.file, job.query])
		quit()
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OsmConfig.RAW_DIR))
	var failed := 0
	for job in jobs:
		var ok: bool = await _download(job)
		if not ok:
			failed += 1
	if failed:
		printerr("%d download(s) failed. Re-run, or fetch them by hand (--print-queries)." % failed)
	else:
		print("All downloads done. Next: godot --headless --script res://tools/osm/import_osm.gd")
	quit(1 if failed else 0)


## One request for roads + coastline over the whole map, one per area for
## buildings and green spaces.
func _build_jobs(args: Dictionary) -> Array:
	var jobs := []
	var u := OsmConfig.union_bbox()
	# Coastline gets ~1 km of margin so the land/sea mask is right at the edges.
	var coast := [u[0] - 0.01, u[1] - 0.012, u[2] + 0.01, u[3] + 0.012]
	jobs.append({
		"label": "roads, traffic lights + coastline",
		"file": "roads_coast.json",
		"query": "[out:json][timeout:%d];\n(\n  way[\"highway\"](%s);\n  node[\"highway\"=\"traffic_signals\"](%s);\n  way[\"natural\"=\"coastline\"](%s);\n);\nout geom;"
			% [TIMEOUT_S, _bbox_str(u), _bbox_str(u), _bbox_str(coast)],
	})

	var boxes := []
	if OsmConfig.FETCH_BUILDINGS_EVERYWHERE:
		boxes.append({"name": "all", "bbox": u})
	else:
		for i in OsmConfig.AREAS.size():
			if args.has("area") and int(args["area"]) != i:
				continue
			boxes.append(OsmConfig.AREAS[i])

	for i in boxes.size():
		var b: String = _bbox_str(boxes[i]["bbox"])
		jobs.append({
			"label": "buildings: %s" % boxes[i]["name"],
			"file": "buildings_%s.json" % _slug(boxes[i]["name"]),
			"query": ("[out:json][timeout:%d][bbox:%s];\n(\n  way[\"building\"];\n"
				+ "  relation[\"building\"][\"type\"=\"multipolygon\"];\n"
				+ "  way[\"building:part\"];\n"
				+ "  way[\"leisure\"~\"^(park|garden|pitch)$\"];\n"
				+ "  way[\"landuse\"~\"^(grass|recreation_ground|village_green)$\"];\n"
				+ "  way[\"natural\"=\"beach\"];\n);\nout geom;") % [TIMEOUT_S, b],
		})
	return jobs


func _download(job: Dictionary) -> bool:
	var path := ProjectSettings.globalize_path(OsmConfig.RAW_DIR.path_join(job.file))
	for url: String in OsmConfig.OVERPASS_URLS:
		print("Fetching %s from %s ..." % [job.label, url])
		var http := HTTPRequest.new()
		http.timeout = TIMEOUT_S + 30
		http.download_file = path
		_apply_proxy(http)
		root.add_child(http)
		var headers := [
			"Content-Type: application/x-www-form-urlencoded",
			"User-Agent: GTA-CASA-osm-import/1.0 (Godot)",
		]
		var err := http.request(url, headers, HTTPClient.METHOD_POST, "data=" + job.query.uri_encode())
		if err != OK:
			printerr("  could not start request (error %d)" % err)
			http.queue_free()
			continue
		var result: Array = await http.request_completed
		http.queue_free()
		var code: int = result[1]
		if result[0] == HTTPRequest.RESULT_SUCCESS and code == 200:
			var size := FileAccess.get_file_as_bytes(path).size()
			print("  saved %s (%.1f MB)" % [job.file, size / 1048576.0])
			return true
		printerr("  failed: result %d, HTTP %d" % [result[0], code])
		DirAccess.remove_absolute(path)   # Don't leave a half-written file behind.
	return false


## Godot doesn't read proxy settings from the environment by itself; honour
## HTTPS_PROXY (e.g. "http://proxy.example:3128") if it is set.
func _apply_proxy(http: HTTPRequest) -> void:
	var proxy := OS.get_environment("HTTPS_PROXY")
	if proxy.is_empty():
		proxy = OS.get_environment("https_proxy")
	if proxy.is_empty():
		return
	var host_port := proxy.trim_prefix("http://").trim_prefix("https://").split("/")[0]
	host_port = host_port.get_slice("@", host_port.count("@"))   # Drop user:pass@.
	var port := int(host_port.get_slice(":", 1)) if host_port.contains(":") else 80
	http.set_https_proxy(host_port.get_slice(":", 0), port)


func _bbox_str(b: Array) -> String:
	return "%.5f,%.5f,%.5f,%.5f" % [b[0], b[1], b[2], b[3]]


func _slug(s: String) -> String:
	var out := ""
	for c in s.to_lower():
		out += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	return out.trim_suffix("_")


func _parse_args() -> Dictionary:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else true
	return args
