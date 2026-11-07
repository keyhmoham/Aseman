## The AI opponent: iterative-deepening negamax with alpha-beta pruning,
## principal-variation search, a transposition table, null-move pruning,
## quiescence search over captures, MVV-LVA / killer / history move ordering,
## and a tapered (middlegame/endgame) evaluation with piece-square tables
## (PeSTO-style values), mobility-free so it stays fast in GDScript.
##
## Difficulty 1..5 sets the thinking time and depth, and how much the AI
## blurs its choice among near-best moves, so a beginner can beat level 1
## and level 5 plays a solid club game.
extends RefCounted

const Rules = preload("res://arena/chess/chess_rules.gd")

const INF := 1000000
const MATE := 100000

const MG_VALUE := [0, 82, 337, 365, 477, 1025, 0]
const EG_VALUE := [0, 94, 281, 297, 512, 936, 0]
const PHASE_INC := [0, 0, 1, 1, 2, 4, 0]

# Piece-square tables from white's point of view, a8..h8 first row
# (index = (7 - rank) * 8 + file), as printed in PeSTO.
const MG_PST := {
	1: [0, 0, 0, 0, 0, 0, 0, 0,
		98, 134, 61, 95, 68, 126, 34, -11,
		-6, 7, 26, 31, 65, 56, 25, -20,
		-14, 13, 6, 21, 23, 12, 17, -23,
		-27, -2, -5, 12, 17, 6, 10, -25,
		-26, -4, -4, -10, 3, 3, 33, -12,
		-35, -1, -20, -23, -15, 24, 38, -22,
		0, 0, 0, 0, 0, 0, 0, 0],
	2: [-167, -89, -34, -49, 61, -97, -15, -107,
		-73, -41, 72, 36, 23, 62, 7, -17,
		-47, 60, 37, 65, 84, 129, 73, 44,
		-9, 17, 19, 53, 37, 69, 18, 22,
		-13, 4, 16, 13, 28, 19, 21, -8,
		-23, -9, 12, 10, 19, 17, 25, -16,
		-29, -53, -12, -3, -1, 18, -14, -19,
		-105, -21, -58, -33, -17, -28, -19, -23],
	3: [-29, 4, -82, -37, -25, -42, 7, -8,
		-26, 16, -18, -13, 30, 59, 18, -47,
		-16, 37, 43, 40, 35, 50, 37, -2,
		-4, 5, 19, 50, 37, 37, 7, -2,
		-6, 13, 13, 26, 34, 12, 10, 4,
		0, 15, 15, 15, 14, 27, 18, 10,
		4, 15, 16, 0, 7, 21, 33, 1,
		-33, -3, -14, -21, -13, -12, -39, -21],
	4: [32, 42, 32, 51, 63, 9, 31, 43,
		27, 32, 58, 62, 80, 67, 26, 44,
		-5, 19, 26, 36, 17, 45, 61, 16,
		-24, -11, 7, 26, 24, 35, -8, -20,
		-36, -26, -12, -1, 9, -7, 6, -23,
		-45, -25, -16, -17, 3, 0, -5, -33,
		-44, -16, -20, -9, -1, 11, -6, -71,
		-19, -13, 1, 17, 16, 7, -37, -26],
	5: [-28, 0, 29, 12, 59, 44, 43, 45,
		-24, -39, -5, 1, -16, 57, 28, 54,
		-13, -17, 7, 8, 29, 56, 47, 57,
		-27, -27, -16, -16, -1, 17, -2, 1,
		-9, -26, -9, -10, -2, -4, 3, -3,
		-14, 2, -11, -2, -5, 2, 14, 5,
		-35, -8, 11, 2, 8, 15, -3, 1,
		-1, -18, -9, 10, -15, -25, -31, -50],
	6: [-65, 23, 16, -15, -56, -34, 2, 13,
		29, -1, -20, -7, -8, -4, -38, -29,
		-9, 24, 2, -16, -20, 6, 22, -22,
		-17, -20, -12, -27, -30, -25, -14, -36,
		-49, -1, -27, -39, -46, -44, -33, -51,
		-14, -14, -22, -46, -44, -30, -15, -27,
		1, 7, -8, -64, -43, -16, 9, 8,
		-15, 36, 12, -54, 8, -28, 24, 14],
}

const EG_PST := {
	1: [0, 0, 0, 0, 0, 0, 0, 0,
		178, 173, 158, 134, 147, 132, 165, 187,
		94, 100, 85, 67, 56, 53, 82, 84,
		32, 24, 13, 5, -2, 4, 17, 17,
		13, 9, -3, -7, -7, -8, 3, -1,
		4, 7, -6, 1, 0, -5, -1, -8,
		13, 8, 8, 10, 13, 0, 2, -7,
		0, 0, 0, 0, 0, 0, 0, 0],
	2: [-58, -38, -13, -28, -31, -27, -63, -99,
		-25, -8, -25, -2, -9, -25, -24, -52,
		-24, -20, 10, 9, -1, -9, -19, -41,
		-17, 3, 22, 22, 22, 11, 8, -18,
		-18, -6, 16, 25, 16, 17, 4, -18,
		-23, -3, -1, 15, 10, -3, -20, -22,
		-42, -20, -10, -5, -2, -20, -23, -44,
		-29, -51, -23, -15, -22, -18, -50, -64],
	3: [-14, -21, -11, -8, -7, -9, -17, -24,
		-8, -4, 7, -12, -3, -13, -4, -14,
		2, -8, 0, -1, -2, 6, 0, 4,
		-3, 9, 12, 9, 14, 10, 3, 2,
		-6, 3, 13, 19, 7, 10, -3, -9,
		-12, -3, 8, 10, 13, 3, -7, -15,
		-14, -18, -7, -1, 4, -9, -15, -27,
		-23, -9, -23, -5, -9, -16, -5, -17],
	4: [13, 10, 18, 15, 12, 12, 8, 5,
		11, 13, 13, 11, -3, 3, 8, 3,
		7, 7, 7, 5, 4, -3, -5, -3,
		4, 3, 13, 1, 2, 1, -1, 2,
		3, 5, 8, 4, -5, -6, -8, -11,
		-4, 0, -5, -1, -7, -12, -8, -16,
		-6, -6, 0, 2, -9, -9, -11, -3,
		-9, 2, 3, -1, -5, -13, 4, -20],
	5: [-9, 22, 22, 27, 27, 19, 10, 20,
		-17, 20, 32, 41, 58, 25, 30, 0,
		-20, 6, 9, 49, 47, 35, 19, 9,
		3, 22, 24, 45, 57, 40, 57, 36,
		-18, 28, 19, 47, 31, 34, 39, 23,
		-16, -27, 15, 6, 9, 17, 10, 5,
		-22, -23, -30, -16, -16, -23, -36, -32,
		-33, -28, -22, -43, -5, -32, -20, -41],
	6: [-74, -35, -18, -18, -11, 15, 4, -17,
		-12, 17, 14, 17, 17, 38, 23, 11,
		10, 17, 23, 15, 20, 45, 44, 13,
		-8, 22, 24, 27, 26, 33, 26, 3,
		-18, -4, 21, 24, 27, 23, 9, -11,
		-19, -3, 11, 21, 23, 16, 7, -9,
		-27, -11, 4, 13, 14, 4, -5, -17,
		-53, -34, -21, -11, -28, -14, -24, -43],
}

## Per level: [max depth, think time (ms), blur (centipawns)].
const LEVELS := {
	1: [1, 250, 220],
	2: [2, 500, 120],
	3: [3, 900, 50],
	4: [5, 1800, 15],
	5: [64, 3500, 0],
}

var level := 3
var nodes := 0
var _deadline := 0
var _stopped := false
var _tt := {}
var _killers: Array = []
var _history_h := {}
var _rng := RandomNumberGenerator.new()

# Precomputed [piece][square] → (mg, eg) from that piece's colour.
static var _mg: Array = []
static var _eg: Array = []


static func _init_tables() -> void:
	if not _mg.is_empty():
		return
	_mg.resize(16)
	_eg.resize(16)
	for p in 16:
		var mg := PackedInt32Array()
		var eg := PackedInt32Array()
		mg.resize(64)
		eg.resize(64)
		var t := p & 7
		if t >= 1 and t <= 6:
			var black := (p & 8) != 0
			for s in 64:
				var f := s & 7
				var r := s >> 3
				# White reads the table bottom-up; black mirrors the ranks.
				var idx := (7 - r) * 8 + f if not black else r * 8 + f
				mg[s] = MG_VALUE[t] + MG_PST[t][idx]
				eg[s] = EG_VALUE[t] + EG_PST[t][idx]
		_mg[p] = mg
		_eg[p] = eg


func _init(lvl: int = 3, seed: int = 0) -> void:
	_init_tables()
	level = clampi(lvl, 1, 5)
	if seed:
		_rng.seed = seed
	else:
		_rng.randomize()


## Static evaluation, from the point of view of the side to move.
func evaluate(pos) -> int:
	var mg := [0, 0]
	var eg := [0, 0]
	var phase := 0
	var bishops := [0, 0]
	var b: PackedInt32Array = pos.board
	for s in 64:
		var p := b[s]
		if p == 0:
			continue
		var c := 1 if p & 8 else 0
		mg[c] += _mg[p][s]
		eg[c] += _eg[p][s]
		var t := p & 7
		phase += PHASE_INC[t]
		if t == Rules.BISHOP:
			bishops[c] += 1
	for c in 2:
		if bishops[c] >= 2:
			mg[c] += 30
			eg[c] += 50
	var us: int = pos.side
	var mg_score: int = mg[us] - mg[1 - us]
	var eg_score: int = eg[us] - eg[1 - us]
	var ph: int = min(phase, 24)
	return (mg_score * ph + eg_score * (24 - ph)) / 24 + 10   # +10: the move


func _victim_value(pos, m: int) -> int:
	var flags := Rules.move_flags(m)
	if flags & Rules.F_EP:
		return 100
	return MG_VALUE[pos.board[Rules.move_to(m)] & 7]


func _order(pos, moves: PackedInt32Array, best: int, ply: int) -> Array:
	var scored := []
	for m in moves:
		var score := 0
		if m == best:
			score = 10000000
		elif Rules.move_flags(m) & Rules.F_CAPTURE:
			score = 1000000 + _victim_value(pos, m) * 10 - MG_VALUE[pos.board[Rules.move_from(m)] & 7] / 10
		elif Rules.move_promo(m):
			score = 900000 + Rules.move_promo(m)
		elif ply < _killers.size() and (_killers[ply][0] == m or _killers[ply][1] == m):
			score = 800000
		else:
			score = _history_h.get(m & 0xFFF, 0)
		scored.append([score, m])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	return scored


func _time_up() -> bool:
	if _stopped:
		return true
	if (nodes & 1023) == 0 and Time.get_ticks_msec() >= _deadline:
		_stopped = true
	return _stopped


func _quiesce(pos, alpha: int, beta: int, ply: int) -> int:
	nodes += 1
	if _time_up():
		return 0
	var stand := evaluate(pos)
	if stand >= beta:
		return beta
	if stand > alpha:
		alpha = stand
	if ply > 40:
		return stand
	var us: int = pos.side
	for entry in _order(pos, pos.pseudo_moves(true), -1, ply):
		var m: int = entry[1]
		# Delta pruning: even winning this piece cannot lift alpha.
		if Rules.move_promo(m) == 0 and stand + _victim_value(pos, m) + 200 < alpha:
			continue
		pos.make(m)
		if pos.is_attacked(pos.king_sq[us], 1 - us):
			pos.unmake()
			continue
		var score := -_quiesce(pos, -beta, -alpha, ply + 1)
		pos.unmake()
		if _stopped:
			return 0
		if score >= beta:
			return beta
		if score > alpha:
			alpha = score
	return alpha


func _search(pos, depth: int, alpha: int, beta: int, ply: int, allow_null: bool) -> int:
	if depth <= 0:
		return _quiesce(pos, alpha, beta, ply)
	nodes += 1
	if _time_up():
		return 0
	if ply > 0:
		if pos.halfmove >= 100 or pos.repetitions() >= 2 or pos.insufficient_material():
			return 0
	var key: int = pos.hash
	var tt_move := -1
	var tt = _tt.get(key)
	if tt != null:
		tt_move = tt[3]
		if tt[0] >= depth and ply > 0:
			var v: int = tt[1]
			match tt[2]:
				0:
					return v
				1:
					if v >= beta:
						return v
				2:
					if v <= alpha:
						return v
	var us: int = pos.side
	var checked: bool = pos.is_attacked(pos.king_sq[us], 1 - us)
	if checked:
		depth += 1   # check extension
	# Null move: if passing still beats beta, this line is too good to be true.
	if allow_null and not checked and depth >= 3 and ply > 0 and _has_pieces(pos, us):
		pos.make_null()
		var score := -_search(pos, depth - 3, -beta, -beta + 1, ply + 1, false)
		pos.unmake_null()
		if _stopped:
			return 0
		if score >= beta:
			return beta
	var orig_alpha := alpha
	var best := -INF
	var best_move := -1
	var legal := 0
	while _killers.size() <= ply:
		_killers.append([-1, -1])
	for entry in _order(pos, pos.pseudo_moves(), tt_move, ply):
		var m: int = entry[1]
		pos.make(m)
		if pos.is_attacked(pos.king_sq[us], 1 - us):
			pos.unmake()
			continue
		legal += 1
		var score: int
		if legal == 1:
			score = -_search(pos, depth - 1, -beta, -alpha, ply + 1, true)
		else:
			# Late quiet moves get a reduced, null-window look first.
			var r := 1 if legal > 4 and depth >= 3 and not checked and not (Rules.move_flags(m) & Rules.F_CAPTURE) and Rules.move_promo(m) == 0 else 0
			score = -_search(pos, depth - 1 - r, -alpha - 1, -alpha, ply + 1, true)
			if score > alpha and not _stopped:
				score = -_search(pos, depth - 1, -beta, -alpha, ply + 1, true)
		pos.unmake()
		if _stopped:
			return 0
		if score > best:
			best = score
			best_move = m
		if score > alpha:
			alpha = score
		if alpha >= beta:
			if not (Rules.move_flags(m) & Rules.F_CAPTURE):
				if _killers[ply][0] != m:
					_killers[ply][1] = _killers[ply][0]
					_killers[ply][0] = m
				_history_h[m & 0xFFF] = _history_h.get(m & 0xFFF, 0) + depth * depth
			break
	if legal == 0:
		return -MATE + ply if checked else 0
	var flag := 0
	if best <= orig_alpha:
		flag = 2
	elif best >= beta:
		flag = 1
	if _tt.size() > 200000:
		_tt.clear()
	_tt[key] = [depth, best, flag, best_move]
	return best


func _has_pieces(pos, who: int) -> bool:
	var col := 8 if who == 1 else 0
	for s in 64:
		var p: int = pos.board[s]
		if p and (p & 8) == col and (p & 7) != Rules.PAWN and (p & 7) != Rules.KING:
			return true
	return false


## Chooses a move for the side to move in [pos] (which it leaves unchanged).
## Returns {"move": int, "score": int, "depth": int, "nodes": int, "pv": String}.
func choose(pos, max_ms: int = -1) -> Dictionary:
	var cfg: Array = LEVELS[level]
	var max_depth: int = cfg[0]
	var think: int = cfg[1] if max_ms < 0 else max_ms
	var blur: int = cfg[2]
	nodes = 0
	_stopped = false
	_deadline = Time.get_ticks_msec() + think
	_killers.clear()
	_history_h.clear()
	var work = pos.clone()
	var root_moves: PackedInt32Array = work.legal_moves()
	if root_moves.is_empty():
		return {"move": -1, "score": 0, "depth": 0, "nodes": 0}
	if root_moves.size() == 1:
		return {"move": root_moves[0], "score": 0, "depth": 0, "nodes": 0}
	var best_move := root_moves[0]
	var best_score := -INF
	var scores := {}
	var reached := 0
	for depth in range(1, max_depth + 1):
		var alpha := -INF
		var beta := INF
		var iter_best := -1
		var iter_score := -INF
		var iter_scores := {}
		var ordered := _order(work, root_moves, best_move, 0)
		for entry in ordered:
			var m: int = entry[1]
			work.make(m)
			var score: int
			if iter_best < 0 or blur > 0:
				# Blurred levels need every root move's true score to choose
				# among the near-best, so they search each with a full window.
				score = -_search(work, depth - 1, -beta, -(alpha if blur == 0 else -INF), 1, true)
			else:
				score = -_search(work, depth - 1, -alpha - 1, -alpha, 1, true)
				if score > alpha and not _stopped:
					score = -_search(work, depth - 1, -beta, -alpha, 1, true)
			work.unmake()
			if _stopped:
				break
			iter_scores[m] = score
			if score > iter_score:
				iter_score = score
				iter_best = m
			if score > alpha:
				alpha = score
		if _stopped and iter_best < 0:
			break
		if iter_best >= 0 and (not _stopped or iter_score > best_score):
			best_move = iter_best
			best_score = iter_score
			scores = iter_scores
			reached = depth
		if _stopped or best_score > MATE - 100:
			break
	# Blur: pick randomly among moves within [blur] of the best (weaker levels).
	if blur > 0 and scores.size() > 1:
		var near := []
		for m in scores:
			if scores[m] >= best_score - blur and abs(scores[m]) < MATE - 100:
				near.append(m)
		if near.size() > 1 and best_score < MATE - 100:
			best_move = near[_rng.randi_range(0, near.size() - 1)]
	return {"move": best_move, "score": best_score, "depth": reached, "nodes": nodes,
		"uci": Rules.uci(best_move)}
