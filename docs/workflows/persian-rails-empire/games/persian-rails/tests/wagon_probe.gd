extends SceneTree
const Models = preload("res://arena/persian_rails/models.gd")
func _init():
	call_deferred("run")
func run():
	var m = Models.new()
	var w = m.wagon_for_player(0, Color("2980b9"))
	root.add_child(w)
	await process_frame
	var aabb = _aabb(w)
	print("WAGON_TYPE=", w.get_class(), " name=", w.name, " scale=", w.scale)
	print("WAGON_AABB size=", aabb.size, " pos=", aabb.position)
	print("children=", w.get_child_count())
	_dump(w,0)
	quit(0)
func _dump(n,d):
	if d>3: return
	var extra=""
	if n is MeshInstance3D:
		var mi=n as MeshInstance3D
		if mi.mesh: extra=" mesh="+mi.mesh.get_class()
		extra+=" scale="+str(n.scale)+" pos="+str(n.position)
	print("  ".repeat(d), n.name, " (", n.get_class(), ")", extra)
	for c in n.get_children(): _dump(c,d+1)
func _aabb(n: Node3D) -> AABB:
	var a := AABB()
	var first=true
	for c in n.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null: continue
		var la = mi.get_aabb()
		var gt = mi.global_transform
		# rough
		var corners = [la.position, la.position+la.size]
		for p in [la.position, la.position+Vector3(la.size.x,0,0), la.position+Vector3(0,la.size.y,0), la.position+Vector3(0,0,la.size.z), la.end]:
			var wp = gt * p
			if first:
				a = AABB(wp, Vector3.ZERO); first=false
			else:
				a = a.expand(wp)
	return a
