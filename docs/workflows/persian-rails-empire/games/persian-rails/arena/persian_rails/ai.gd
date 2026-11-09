## Rule-based AI for Persian Rails Empire. Levels 1–3.
extends RefCounted

var level: int = 2
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init(p_level: int = 2) -> void:
	level = clampi(p_level, 1, 3)
	rng.randomize()


func choose(rules) -> Dictionary:
	var acts: Array = rules.legal_actions()
	if acts.is_empty():
		return {"type": "draw_trains"}
	var pi: int = rules.current
	var p: Dictionary = rules.players[pi]
	# Score claim actions by ticket progress and route value
	var claims: Array = []
	for a in acts:
		if str(a.type) != "claim":
			continue
		var route = rules.route_by_id(str(a.route))
		var score := float(rules.route_score(route))
		# ticket synergy
		for t in p.tickets:
			if str(t.from) == str(route.from) or str(t.from) == str(route.to) \
					or str(t.to) == str(route.from) or str(t.to) == str(route.to):
				score += float(t.points) * 0.35
			# prefer edges that sit on incomplete tickets
			if not rules.connected(pi, str(t.from), str(t.to)):
				score += 1.5
		# scarcity / blocking: prefer shorter early at low level
		if level == 1:
			score += rng.randf() * 3.0
			score -= float(route.length) * 0.2
		elif level == 2:
			score += rng.randf() * 1.5
		else:
			score -= float(rules.cost_for_route(route)) * 0.1
			if int(p.wagons) <= 8:
				score += float(rules.route_score(route)) * 0.5
		claims.append({"act": a, "score": score})
	claims.sort_custom(func(a, b): return a.score > b.score)

	var should_claim := false
	if claims.size():
		if level == 1:
			should_claim = rng.randf() < 0.45
		elif level == 2:
			should_claim = rng.randf() < 0.7 or claims[0].score > 6.0
		else:
			should_claim = claims[0].score > 4.0 or int(p.hand.size()) >= 6
	if should_claim and claims.size():
		return claims[0].act

	# draw tickets if few left and pile exists
	for a in acts:
		if str(a.type) == "draw_tickets" and p.tickets.size() < (1 if level == 1 else 2):
			if level >= 2 and rng.randf() < 0.25:
				return {"type": "draw_tickets"}

	# otherwise draw trains — prefer face-up matching ticket colors / needed
	var need: Dictionary = {}
	for r in rules.routes:
		if rules.claimed.has(str(r.id)):
			continue
		var col := str(r.color)
		if col != "gray":
			need[col] = int(need.get(col, 0)) + int(r.length)
	var picks: Array = []
	var used := {}
	for i in range(rules.face_up.size()):
		if picks.size() >= 2:
			break
		var c := str(rules.face_up[i])
		if c == rules.LOCO and level >= 2:
			picks.append(i)
			used[i] = true
			break
		if need.has(c) and not used.has(i):
			picks.append(i)
			used[i] = true
	while picks.size() < 2:
		picks.append("deck")
	return {"type": "draw_trains", "picks": picks}
