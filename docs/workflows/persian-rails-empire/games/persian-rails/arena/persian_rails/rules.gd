## Pure rules engine for Persian Rails Empire. No UI, no class_name, no autoload.
extends RefCounted

const COLORS := ["red", "blue", "green", "yellow", "black", "white", "orange", "purple"]
const SCORE_BY_LEN := {1: 1, 2: 2, 3: 4, 4: 7, 5: 10, 6: 15}
const LOCO := "locomotive"

var cities: Array = []
var routes: Array = []
var tickets_deck: Array = []
var culture: Array = []
var fa: Dictionary = {}

var players: Array = []  # {id, name, is_ai, color, wagons, score, hand, tickets, routes}
var face_up: Array = []
var deck: Array = []
var discard: Array = []
var ticket_pile: Array = []
var claimed: Dictionary = {}  # route_id -> player_index
var current: int = 0
var last_round: bool = false
var turns_left: int = -1
var over: bool = false
var move_count: int = 0
var started_at: int = 0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func load_data(base: String = "res://arena/persian_rails/data") -> void:
	cities = _load_json(base + "/cities.json")
	routes = _load_json(base + "/routes.json")
	tickets_deck = _load_json(base + "/tickets.json")
	culture = _load_json(base + "/culture.json")
	fa = _load_json(base + "/fa.json")


func _load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return [] if path.ends_with("fa.json") == false else {}
	var txt := f.get_as_text()
	var data = JSON.parse_string(txt)
	return data if data != null else ([] if not path.ends_with("fa.json") else {})


func start(human_name: String, ai_count: int = 1, wagons: int = 45, p_seed: int = 0) -> void:
	if p_seed != 0:
		rng.seed = p_seed
	else:
		rng.randomize()
	players.clear()
	claimed.clear()
	discard.clear()
	over = false
	last_round = false
	turns_left = -1
	move_count = 0
	started_at = Time.get_ticks_msec()
	current = 0
	var palette := ["#c4531f", "#156a87", "#3f8a55", "#9a2a48"]
	var names_ai := ["رخشا ریلی", "پارس‌لاین", "کویر اکسپرس", "خزر کارگو"]
	players.append(_new_player(0, human_name, false, palette[0], wagons))
	for i in range(clampi(ai_count, 1, 3)):
		players.append(_new_player(i + 1, names_ai[i], true, palette[(i + 1) % palette.size()], wagons))
	_build_deck()
	_shuffle(deck)
	ticket_pile = tickets_deck.duplicate(true)
	_shuffle(ticket_pile)
	face_up.clear()
	_refill_face_up()
	for p in players:
		for _i in range(4):
			p.hand.append(_draw_train())
		var offered := _deal_tickets(3)
		# keep 2 initially
		offered.sort_custom(func(a, b): return int(a.points) > int(b.points))
		p.tickets = [offered[0], offered[1]] if offered.size() >= 2 else offered
	# human starts


func _new_player(id: int, name: String, is_ai: bool, color: String, wagons: int) -> Dictionary:
	return {
		"id": id, "name": name, "is_ai": is_ai, "color": color,
		"wagons": wagons, "score": 0, "hand": [], "tickets": [], "routes": [],
	}


func _build_deck() -> void:
	deck.clear()
	for c in COLORS:
		for _i in range(12):
			deck.append(c)
	for _i in range(14):
		deck.append(LOCO)


func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = arr[i]
		arr[i] = arr[j]
		arr[j] = t


func _draw_train() -> String:
	if deck.is_empty():
		if discard.is_empty():
			return ""
		deck = discard.duplicate()
		discard.clear()
		_shuffle(deck)
	return String(deck.pop_back())


func _refill_face_up() -> void:
	while face_up.size() < 5:
		var c := _draw_train()
		if c == "":
			break
		face_up.append(c)
	_replace_triple_locos()


func _replace_triple_locos() -> void:
	var locos := 0
	for c in face_up:
		if c == LOCO:
			locos += 1
	if locos >= 3:
		for c in face_up:
			discard.append(c)
		face_up.clear()
		_refill_face_up()


func _deal_tickets(n: int) -> Array:
	var out: Array = []
	for _i in range(n):
		if ticket_pile.is_empty():
			break
		out.append(ticket_pile.pop_back())
	return out


func route_by_id(id: String) -> Dictionary:
	for r in routes:
		if str(r.id) == id:
			return r
	return {}


func city_by_id(id: String) -> Dictionary:
	for c in cities:
		if str(c.id) == id:
			return c
	return {}


func cost_for_route(route: Dictionary) -> int:
	var n := int(route.get("length", 1))
	var t := str(route.get("terrain", "plain"))
	if t == "mountain" or t == "bridge":
		n += 1
	return n


func route_score(route: Dictionary) -> int:
	var L := int(route.get("length", 1))
	return int(SCORE_BY_LEN.get(L, L * 2))


func can_afford(hand: Array, route: Dictionary) -> Dictionary:
	## Returns {ok, pay: Array of colors to remove} or {ok:false}
	var need := cost_for_route(route)
	var color := str(route.get("color", "gray"))
	var counts := {}
	for c in hand:
		counts[c] = int(counts.get(c, 0)) + 1
	var locos := int(counts.get(LOCO, 0))
	if color == "gray":
		# pay with any single color + locos
		var best := ""
		var best_have := -1
		for col in COLORS:
			var have := int(counts.get(col, 0))
			if have > best_have:
				best_have = have
				best = col
		var use_col := mini(best_have, need)
		var use_loco := need - use_col
		if use_loco > locos:
			return {"ok": false}
		var pay: Array = []
		for _i in range(use_col):
			pay.append(best)
		for _i in range(use_loco):
			pay.append(LOCO)
		return {"ok": true, "pay": pay}
	var have := int(counts.get(color, 0))
	var use_col := mini(have, need)
	var use_loco := need - use_col
	if use_loco > locos:
		return {"ok": false}
	var pay2: Array = []
	for _i in range(use_col):
		pay2.append(color)
	for _i in range(use_loco):
		pay2.append(LOCO)
	return {"ok": true, "pay": pay2}


func remove_from_hand(hand: Array, pay: Array) -> void:
	for c in pay:
		var i := hand.find(c)
		if i >= 0:
			hand.remove_at(i)
			discard.append(c)


func legal_actions(pi: int = -1) -> Array:
	if over:
		return []
	if pi < 0:
		pi = current
	var p: Dictionary = players[pi]
	var acts: Array = [{"type": "draw_trains"}]
	for r in routes:
		var rid := str(r.id)
		if claimed.has(rid):
			continue
		if int(p.wagons) < cost_for_route(r):
			continue
		var aff := can_afford(p.hand, r)
		if aff.get("ok", false):
			acts.append({"type": "claim", "route": rid, "pay": aff.pay})
	if not ticket_pile.is_empty():
		acts.append({"type": "draw_tickets"})
	return acts


func apply(action: Dictionary, pi: int = -1) -> Dictionary:
	## Apply an action for the current (or given) player. Returns event dict.
	if over:
		return {"ok": false, "error": "game_over"}
	if pi < 0:
		pi = current
	if pi != current:
		return {"ok": false, "error": "not_your_turn"}
	var p: Dictionary = players[pi]
	var typ := str(action.get("type", ""))
	var ev := {"ok": true, "type": "move", "player": pi, "action": typ, "move": move_count}
	match typ:
		"draw_trains":
			var picks: Array = action.get("picks", [])
			var got: Array = []
			if picks.is_empty():
				# default: two from deck
				for _i in range(2):
					var c := _draw_train()
					if c != "":
						p.hand.append(c)
						got.append(c)
			else:
				var taken := 0
				for pick in picks:
					if taken >= 2:
						break
					if str(pick) == "deck":
						var c2 := _draw_train()
						if c2 != "":
							p.hand.append(c2)
							got.append(c2)
							taken += 1
					else:
						var idx := int(pick)
						if idx < 0 or idx >= face_up.size():
							continue
						var card := String(face_up[idx])
						# locomotive face-up costs the whole draw
						face_up.remove_at(idx)
						p.hand.append(card)
						got.append(card)
						taken += 1
						if card == LOCO:
							taken = 2
						_refill_face_up()
				while taken < 2:
					var c3 := _draw_train()
					if c3 == "":
						break
					p.hand.append(c3)
					got.append(c3)
					taken += 1
			ev["cards"] = got
		"claim":
			var rid := str(action.get("route", ""))
			var route := route_by_id(rid)
			if route.is_empty() or claimed.has(rid):
				return {"ok": false, "error": "route_unavailable"}
			var need := cost_for_route(route)
			if int(p.wagons) < need:
				return {"ok": false, "error": "no_wagons"}
			var aff := can_afford(p.hand, route)
			if not aff.get("ok", false):
				return {"ok": false, "error": "need_cards"}
			var pay: Array = action.get("pay", aff.pay)
			remove_from_hand(p.hand, pay)
			p.wagons = int(p.wagons) - need
			p.score = int(p.score) + route_score(route)
			p.routes.append(rid)
			claimed[rid] = pi
			ev["route"] = rid
			ev["points"] = route_score(route)
			if int(p.wagons) <= 2 and not last_round:
				last_round = true
				turns_left = players.size()
		"draw_tickets":
			var offered := _deal_tickets(3)
			var keep: Array = action.get("keep", [])
			if keep.is_empty():
				# keep the highest-value one
				offered.sort_custom(func(a, b): return int(a.points) > int(b.points))
				keep = [offered[0]] if offered.size() else []
				for i in range(1, offered.size()):
					ticket_pile.append(offered[i])
			else:
				var keep_ids := {}
				for k in keep:
					keep_ids[str(k)] = true
				var kept: Array = []
				for t in offered:
					if keep_ids.has(str(t.id)):
						kept.append(t)
					else:
						ticket_pile.append(t)
				if kept.is_empty() and offered.size():
					kept.append(offered[0])
				keep = kept
			for t in keep:
				p.tickets.append(t)
			ev["tickets"] = keep.size()
		_:
			return {"ok": false, "error": "bad_action"}
	move_count += 1
	_advance_turn()
	ev["next"] = current
	ev["over"] = over
	return ev


func _advance_turn() -> void:
	if last_round:
		turns_left -= 1
		if turns_left <= 0:
			_finalize()
			return
	current = (current + 1) % players.size()


func connected(pi: int, a: String, b: String) -> bool:
	var mine: Dictionary = {}
	for rid in players[pi].routes:
		mine[rid] = true
	var graph: Dictionary = {}
	for r in routes:
		if not mine.has(str(r.id)):
			continue
		var u := str(r.from)
		var v := str(r.to)
		if not graph.has(u):
			graph[u] = []
		if not graph.has(v):
			graph[v] = []
		graph[u].append(v)
		graph[v].append(u)
	if not graph.has(a):
		return false
	var seen := {}
	var stack := [a]
	while stack.size():
		var n = stack.pop_back()
		if n == b:
			return true
		if seen.has(n):
			continue
		seen[n] = true
		for m in graph.get(n, []):
			if not seen.has(m):
				stack.append(m)
	return false


func longest_path_len(pi: int) -> int:
	var mine: Dictionary = {}
	for rid in players[pi].routes:
		mine[rid] = true
	var graph: Dictionary = {}
	var edge_w: Dictionary = {}
	for r in routes:
		if not mine.has(str(r.id)):
			continue
		var u := str(r.from)
		var v := str(r.to)
		var w := int(r.length)
		if not graph.has(u):
			graph[u] = []
		if not graph.has(v):
			graph[v] = []
		graph[u].append(v)
		graph[v].append(u)
		edge_w[u + ">" + v] = w
		edge_w[v + ">" + u] = w
	var best := 0
	for start in graph.keys():
		best = maxi(best, _dfs_longest(start, graph, edge_w, {}, 0))
	return best


func _dfs_longest(node: String, graph: Dictionary, edge_w: Dictionary, used: Dictionary, acc: int) -> int:
	var best := acc
	for nxt_v in graph.get(node, []):
		var nxt: String = str(nxt_v)
		var e1: String = node + ">" + nxt
		var e2: String = nxt + ">" + node
		if used.has(e1) or used.has(e2):
			continue
		used[e1] = true
		used[e2] = true
		best = maxi(best, _dfs_longest(nxt, graph, edge_w, used, acc + int(edge_w.get(e1, 1))))
		used.erase(e1)
		used.erase(e2)
	return best


func _finalize() -> void:
	over = true
	var lengths: Array = []
	for i in range(players.size()):
		lengths.append(longest_path_len(i))
	var max_len := 0
	for L in lengths:
		max_len = maxi(max_len, int(L))
	for i in range(players.size()):
		var p: Dictionary = players[i]
		for t in p.tickets:
			if connected(i, str(t.from), str(t.to)):
				p.score = int(p.score) + int(t.points)
			else:
				p.score = int(p.score) - int(t.points)
		if int(lengths[i]) == max_len and max_len > 0:
			p.score = int(p.score) + 10
		players[i] = p


func final_result() -> Dictionary:
	var human: Dictionary = players[0] as Dictionary
	var best_ai := -9999
	for i in range(1, players.size()):
		best_ai = maxi(best_ai, int(players[i].score))
	var hs := int(human.score)
	var outcome := "draw"
	if hs > best_ai:
		outcome = "win"
	elif hs < best_ai:
		outcome = "loss"
	return {
		"type": "result",
		"game": "persian-rails",
		"outcome": outcome,
		"score": hs,
		"ai_score": best_ai,
		"duration_s": int((Time.get_ticks_msec() - started_at) / 1000.0),
		"moves": move_count,
		"players": players.map(func(p): return {"name": p.name, "score": p.score, "is_ai": p.is_ai}),
	}


func snapshot() -> Dictionary:
	return {
		"current": current,
		"over": over,
		"last_round": last_round,
		"face_up": face_up.duplicate(),
		"claimed": claimed.duplicate(),
		"players": players.duplicate(true),
		"move_count": move_count,
	}
