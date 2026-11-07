## The complete rules of chess (FIDE Laws of Chess, "basic rules of play"):
## legal move generation for every piece, check, checkmate, stalemate,
## castling (with every condition), en passant, promotion, the fifty-move and
## seventy-five-move rules, threefold and fivefold repetition, insufficient
## material, FEN in and out, SAN in and out.
##
## Pure logic: no nodes, no scene. The 3D game, the AI and the tests all use
## it through preload() (no class_name: the game is loaded as a resource pack
## into other Godot projects, which know nothing of this one's global classes).
extends RefCounted

const EMPTY := 0
const PAWN := 1
const KNIGHT := 2
const BISHOP := 3
const ROOK := 4
const QUEEN := 5
const KING := 6
const BLACK := 8          # colour bit: black piece = type | BLACK

const WHITE_SIDE := 0
const BLACK_SIDE := 1

const CASTLE_WK := 1
const CASTLE_WQ := 2
const CASTLE_BK := 4
const CASTLE_BQ := 8

# Move flags (bits 16..).
const F_CAPTURE := 1
const F_EP := 2
const F_CASTLE := 4
const F_DOUBLE := 8

const START_FEN := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

const KNIGHT_D := [[1, 2], [2, 1], [2, -1], [1, -2], [-1, -2], [-2, -1], [-2, 1], [-1, 2]]
const KING_D := [[1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]]
const BISHOP_D := [[1, 1], [1, -1], [-1, 1], [-1, -1]]
const ROOK_D := [[1, 0], [-1, 0], [0, 1], [0, -1]]

var board: PackedInt32Array = PackedInt32Array()   # 64 squares, a1 = 0, h8 = 63
var side := WHITE_SIDE
var castling := 0
var ep := -1              # en-passant target square, or -1
var halfmove := 0
var fullmove := 1
var hash := 0
var king_sq := PackedInt32Array([4, 60])

var _undo: Array = []     # stack of [move, captured, castling, ep, halfmove, hash, fullmove]
var _history: Array = []  # hashes of the positions before each move, for repetition

# Zobrist keys, deterministic so a hash means the same everywhere.
static var _z_piece: PackedInt64Array
static var _z_side: int
static var _z_castle: PackedInt64Array
static var _z_ep: PackedInt64Array

# Castling rights a move from/to a square keeps (a rook or king moving or
# being captured loses its rights).
static var _castle_mask: PackedInt32Array


static func _init_tables() -> void:
	if _z_piece.size() == 64 * 16:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED_C4E55
	_z_piece = PackedInt64Array()
	_z_piece.resize(64 * 16)
	for i in 64 * 16:
		_z_piece[i] = (rng.randi() << 32) ^ rng.randi()
	_z_side = (rng.randi() << 32) ^ rng.randi()
	_z_castle = PackedInt64Array()
	_z_castle.resize(16)
	for i in 16:
		_z_castle[i] = (rng.randi() << 32) ^ rng.randi()
	_z_ep = PackedInt64Array()
	_z_ep.resize(8)
	for i in 8:
		_z_ep[i] = (rng.randi() << 32) ^ rng.randi()
	_castle_mask = PackedInt32Array()
	_castle_mask.resize(64)
	for i in 64:
		_castle_mask[i] = 15
	_castle_mask[0] = 15 & ~CASTLE_WQ
	_castle_mask[7] = 15 & ~CASTLE_WK
	_castle_mask[4] = 15 & ~(CASTLE_WK | CASTLE_WQ)
	_castle_mask[56] = 15 & ~CASTLE_BQ
	_castle_mask[63] = 15 & ~CASTLE_BK
	_castle_mask[60] = 15 & ~(CASTLE_BK | CASTLE_BQ)


func _init(fen: String = START_FEN) -> void:
	_init_tables()
	load_fen(fen)


# ---------------------------------------------------------------------------
# Squares, pieces, moves
# ---------------------------------------------------------------------------

static func sq(file: int, rank: int) -> int:
	return rank * 8 + file

static func file_of(s: int) -> int:
	return s & 7

static func rank_of(s: int) -> int:
	return s >> 3

static func sq_name(s: int) -> String:
	return "abcdefgh"[s & 7] + str((s >> 3) + 1)

static func sq_from_name(n: String) -> int:
	if n.length() != 2:
		return -1
	var f := "abcdefgh".find(n[0])
	var r := "12345678".find(n[1])
	return -1 if f < 0 or r < 0 else r * 8 + f

static func type_of(p: int) -> int:
	return p & 7

static func color_of(p: int) -> int:
	return BLACK_SIDE if p & BLACK else WHITE_SIDE

static func move_from(m: int) -> int:
	return m & 63

static func move_to(m: int) -> int:
	return (m >> 6) & 63

static func move_promo(m: int) -> int:
	return (m >> 12) & 7

static func move_flags(m: int) -> int:
	return (m >> 16) & 15

static func make_move_code(from: int, to: int, promo: int = 0, flags: int = 0) -> int:
	return from | (to << 6) | (promo << 12) | (flags << 16)

static func uci(m: int) -> String:
	var s := sq_name(move_from(m)) + sq_name(move_to(m))
	var p := move_promo(m)
	if p >= KNIGHT:
		s += ["", "", "n", "b", "r", "q"][p]
	return s

## The legal move a UCI string ("e2e4", "e7e8q") names, or -1.
func move_from_uci(text: String) -> int:
	for m in legal_moves():
		if uci(m) == text:
			return m
	return -1

func piece_at(s: int) -> int:
	return board[s]


# ---------------------------------------------------------------------------
# FEN
# ---------------------------------------------------------------------------

func load_fen(fen: String) -> bool:
	var parts := fen.strip_edges().split(" ", false)
	if parts.size() < 4:
		return false
	board = PackedInt32Array()
	board.resize(64)
	var rank := 7
	var file := 0
	for ch in parts[0]:
		if ch == "/":
			rank -= 1
			file = 0
		elif ch >= "1" and ch <= "8":
			file += int(ch)
		else:
			var t := "pnbrqk".find(ch.to_lower()) + 1
			if t <= 0 or file > 7 or rank < 0:
				return false
			board[sq(file, rank)] = t | (BLACK if ch == ch.to_lower() else 0)
			file += 1
	side = BLACK_SIDE if parts[1] == "b" else WHITE_SIDE
	castling = 0
	if parts[2] != "-":
		for ch in parts[2]:
			castling |= {"K": CASTLE_WK, "Q": CASTLE_WQ, "k": CASTLE_BK, "q": CASTLE_BQ}.get(ch, 0)
	ep = -1 if parts[3] == "-" else sq_from_name(parts[3])
	halfmove = int(parts[4]) if parts.size() > 4 else 0
	fullmove = int(parts[5]) if parts.size() > 5 else 1
	for i in 64:
		if board[i] == KING:
			king_sq[0] = i
		elif board[i] == (KING | BLACK):
			king_sq[1] = i
	_undo.clear()
	_history.clear()
	hash = compute_hash()
	return true


func fen() -> String:
	var out := ""
	for r in range(7, -1, -1):
		var empty := 0
		for f in 8:
			var p := board[sq(f, r)]
			if p == EMPTY:
				empty += 1
				continue
			if empty:
				out += str(empty)
				empty = 0
			var c := "pnbrqk"[type_of(p) - 1]
			out += c if p & BLACK else c.to_upper()
		if empty:
			out += str(empty)
		if r:
			out += "/"
	var c := ""
	if castling & CASTLE_WK: c += "K"
	if castling & CASTLE_WQ: c += "Q"
	if castling & CASTLE_BK: c += "k"
	if castling & CASTLE_BQ: c += "q"
	return "%s %s %s %s %d %d" % [out, "b" if side else "w", c if c else "-",
		sq_name(ep) if ep >= 0 else "-", halfmove, fullmove]


func compute_hash() -> int:
	var h := 0
	for i in 64:
		if board[i]:
			h ^= _z_piece[i * 16 + board[i]]
	if side == BLACK_SIDE:
		h ^= _z_side
	h ^= _z_castle[castling]
	if ep >= 0:
		h ^= _z_ep[file_of(ep)]
	return h


# ---------------------------------------------------------------------------
# Attacks
# ---------------------------------------------------------------------------

## Whether square [s] is attacked by side [by].
func is_attacked(s: int, by: int) -> bool:
	var f := file_of(s)
	var r := rank_of(s)
	var col := BLACK if by == BLACK_SIDE else 0
	# Pawns: a white pawn attacks upwards, so it sits one rank below.
	var pr := r - 1 if by == WHITE_SIDE else r + 1
	if pr >= 0 and pr < 8:
		for df in [-1, 1]:
			var pf: int = f + df
			if pf >= 0 and pf < 8 and board[sq(pf, pr)] == (PAWN | col):
				return true
	for d in KNIGHT_D:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		if nf >= 0 and nf < 8 and nr >= 0 and nr < 8 and board[sq(nf, nr)] == (KNIGHT | col):
			return true
	for d in KING_D:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		if nf >= 0 and nf < 8 and nr >= 0 and nr < 8 and board[sq(nf, nr)] == (KING | col):
			return true
	for d in BISHOP_D:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		while nf >= 0 and nf < 8 and nr >= 0 and nr < 8:
			var p := board[sq(nf, nr)]
			if p:
				if p == (BISHOP | col) or p == (QUEEN | col):
					return true
				break
			nf += d[0]
			nr += d[1]
	for d in ROOK_D:
		var nf: int = f + d[0]
		var nr: int = r + d[1]
		while nf >= 0 and nf < 8 and nr >= 0 and nr < 8:
			var p := board[sq(nf, nr)]
			if p:
				if p == (ROOK | col) or p == (QUEEN | col):
					return true
				break
			nf += d[0]
			nr += d[1]
	return false


func in_check(who: int = -1) -> bool:
	if who < 0:
		who = side
	return is_attacked(king_sq[who], 1 - who)


# ---------------------------------------------------------------------------
# Move generation
# ---------------------------------------------------------------------------

## Every pseudo-legal move of the side to move (may leave its king in check).
## [captures_only] limits it to captures and promotions (quiescence search).
func pseudo_moves(captures_only: bool = false) -> PackedInt32Array:
	var moves := PackedInt32Array()
	var us := side
	var col := BLACK if us == BLACK_SIDE else 0
	for s in 64:
		var p := board[s]
		if p == EMPTY or color_of(p) != us:
			continue
		var t := type_of(p)
		var f := file_of(s)
		var r := rank_of(s)
		match t:
			PAWN:
				var dir := 1 if us == WHITE_SIDE else -1
				var start_rank := 1 if us == WHITE_SIDE else 6
				var promo_rank := 7 if us == WHITE_SIDE else 0
				var nr := r + dir
				if nr >= 0 and nr < 8:
					var one := sq(f, nr)
					if board[one] == EMPTY:
						if nr == promo_rank:
							for pt in [QUEEN, ROOK, BISHOP, KNIGHT]:
								moves.append(make_move_code(s, one, pt))
						elif not captures_only:
							moves.append(make_move_code(s, one))
							if r == start_rank:
								var two := sq(f, r + 2 * dir)
								if board[two] == EMPTY:
									moves.append(make_move_code(s, two, 0, F_DOUBLE))
					for df in [-1, 1]:
						var nf: int = f + df
						if nf < 0 or nf > 7:
							continue
						var to := sq(nf, nr)
						var q := board[to]
						if q != EMPTY and color_of(q) != us:
							if nr == promo_rank:
								for pt in [QUEEN, ROOK, BISHOP, KNIGHT]:
									moves.append(make_move_code(s, to, pt, F_CAPTURE))
							else:
								moves.append(make_move_code(s, to, 0, F_CAPTURE))
						elif to == ep:
							moves.append(make_move_code(s, to, 0, F_CAPTURE | F_EP))
			KNIGHT, KING:
				var dirs: Array = KNIGHT_D if t == KNIGHT else KING_D
				for d in dirs:
					var nf: int = f + d[0]
					var nr: int = r + d[1]
					if nf < 0 or nf > 7 or nr < 0 or nr > 7:
						continue
					var to := sq(nf, nr)
					var q := board[to]
					if q == EMPTY:
						if not captures_only:
							moves.append(make_move_code(s, to))
					elif color_of(q) != us:
						moves.append(make_move_code(s, to, 0, F_CAPTURE))
				if t == KING and not captures_only:
					_castles(moves, s, us)
			_:
				var dirs: Array
				if t == BISHOP:
					dirs = BISHOP_D
				elif t == ROOK:
					dirs = ROOK_D
				else:
					dirs = BISHOP_D + ROOK_D
				for d in dirs:
					var nf: int = f + d[0]
					var nr: int = r + d[1]
					while nf >= 0 and nf < 8 and nr >= 0 and nr < 8:
						var to := sq(nf, nr)
						var q := board[to]
						if q == EMPTY:
							if not captures_only:
								moves.append(make_move_code(s, to))
						else:
							if color_of(q) != us:
								moves.append(make_move_code(s, to, 0, F_CAPTURE))
							break
						nf += d[0]
						nr += d[1]
	return moves


## Castling: the king and rook have not moved (the rights), the squares
## between them are empty, and the king is not in check, does not pass
## through an attacked square and does not land on one.
func _castles(moves: PackedInt32Array, s: int, us: int) -> void:
	var them := 1 - us
	var home := 4 if us == WHITE_SIDE else 60
	if s != home:
		return
	var rook := ROOK | (BLACK if us == BLACK_SIDE else 0)
	var k_right := CASTLE_WK if us == WHITE_SIDE else CASTLE_BK
	var q_right := CASTLE_WQ if us == WHITE_SIDE else CASTLE_BQ
	if castling & (k_right | q_right) == 0 or is_attacked(s, them):
		return
	if castling & k_right and board[s + 1] == EMPTY and board[s + 2] == EMPTY and board[s + 3] == rook:
		if not is_attacked(s + 1, them) and not is_attacked(s + 2, them):
			moves.append(make_move_code(s, s + 2, 0, F_CASTLE))
	if castling & q_right and board[s - 1] == EMPTY and board[s - 2] == EMPTY and board[s - 3] == EMPTY and board[s - 4] == rook:
		if not is_attacked(s - 1, them) and not is_attacked(s - 2, them):
			moves.append(make_move_code(s, s - 2, 0, F_CASTLE))


## Every legal move of the side to move.
func legal_moves(captures_only: bool = false) -> PackedInt32Array:
	var out := PackedInt32Array()
	var us := side
	for m in pseudo_moves(captures_only):
		make(m)
		if not is_attacked(king_sq[us], 1 - us):
			out.append(m)
		unmake()
	return out


## The legal moves of the piece on [from].
func legal_moves_from(from: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for m in legal_moves():
		if move_from(m) == from:
			out.append(m)
	return out


## The legal move from [from] to [to] (with [promo] when it promotes), or -1.
func find_move(from: int, to: int, promo: int = QUEEN) -> int:
	for m in legal_moves():
		if move_from(m) == from and move_to(m) == to:
			if move_promo(m) == 0 or move_promo(m) == promo:
				return m
	return -1


func is_promotion(from: int, to: int) -> bool:
	var p := board[from]
	return type_of(p) == PAWN and (rank_of(to) == 7 or rank_of(to) == 0)


# ---------------------------------------------------------------------------
# Make / unmake
# ---------------------------------------------------------------------------

func _put(s: int, p: int) -> void:
	if board[s]:
		hash ^= _z_piece[s * 16 + board[s]]
	board[s] = p
	if p:
		hash ^= _z_piece[s * 16 + p]


## Plays [m] (pseudo-legal is enough) and records how to undo it.
func make(m: int) -> void:
	var from := move_from(m)
	var to := move_to(m)
	var flags := move_flags(m)
	var p := board[from]
	var captured := board[to]
	var cap_sq := to
	if flags & F_EP:
		cap_sq = to - 8 if side == WHITE_SIDE else to + 8
		captured = board[cap_sq]
	_undo.append([m, captured, castling, ep, halfmove, hash, fullmove])
	_history.append(hash)

	if ep >= 0:
		hash ^= _z_ep[file_of(ep)]
	hash ^= _z_castle[castling]

	if flags & F_EP:
		_put(cap_sq, EMPTY)
	_put(from, EMPTY)
	var promo := move_promo(m)
	_put(to, (promo | (p & BLACK)) if promo else p)
	if type_of(p) == KING:
		king_sq[side] = to
		if flags & F_CASTLE:
			if to > from:
				_put(from + 3, EMPTY)
				_put(from + 1, ROOK | (p & BLACK))
			else:
				_put(from - 4, EMPTY)
				_put(from - 1, ROOK | (p & BLACK))

	castling &= _castle_mask[from] & _castle_mask[to]
	ep = -1
	if flags & F_DOUBLE:
		ep = (from + to) >> 1
	if type_of(p) == PAWN or captured:
		halfmove = 0
	else:
		halfmove += 1
	if side == BLACK_SIDE:
		fullmove += 1
	side = 1 - side
	hash ^= _z_side
	hash ^= _z_castle[castling]
	if ep >= 0:
		hash ^= _z_ep[file_of(ep)]


func unmake() -> void:
	if _undo.is_empty():
		return
	var u: Array = _undo.pop_back()
	_history.pop_back()
	var m: int = u[0]
	var captured: int = u[1]
	side = 1 - side
	var from := move_from(m)
	var to := move_to(m)
	var flags := move_flags(m)
	var p := board[to]
	if move_promo(m):
		p = PAWN | (p & BLACK)
	board[from] = p
	board[to] = EMPTY
	if flags & F_EP:
		board[to - 8 if side == WHITE_SIDE else to + 8] = captured
	else:
		board[to] = captured
	if type_of(p) == KING:
		king_sq[side] = from
		if flags & F_CASTLE:
			if to > from:
				board[from + 1] = EMPTY
				board[from + 3] = ROOK | (p & BLACK)
			else:
				board[from - 1] = EMPTY
				board[from - 4] = ROOK | (p & BLACK)
	castling = u[2]
	ep = u[3]
	halfmove = u[4]
	hash = u[5]
	fullmove = u[6]


## A null move (the side to move passes), for the AI's search only.
func make_null() -> void:
	_undo.append([-1, 0, castling, ep, halfmove, hash, fullmove])
	_history.append(hash)
	if ep >= 0:
		hash ^= _z_ep[file_of(ep)]
	ep = -1
	side = 1 - side
	hash ^= _z_side


func unmake_null() -> void:
	var u: Array = _undo.pop_back()
	_history.pop_back()
	side = 1 - side
	ep = u[3]
	hash = u[5]


func moves_played() -> int:
	return _undo.size()


func last_move() -> int:
	return -1 if _undo.is_empty() else int(_undo[-1][0])


# ---------------------------------------------------------------------------
# Game end
# ---------------------------------------------------------------------------

## How many times the current position has occurred (same placement, side,
## castling rights and en-passant possibility), counting now.
func repetitions() -> int:
	var n := 1
	# Only positions since the last irreversible move can repeat.
	var i := _history.size() - 2
	var stop: int = max(0, _history.size() - halfmove)
	while i >= stop:
		if _history[i] == hash:
			n += 1
		i -= 2
	return n


## Neither side can checkmate by any sequence of legal moves: K v K,
## K+minor v K, K+B v K+B with bishops on the same colour.
func insufficient_material() -> bool:
	var minors := []
	for s in 64:
		var p := board[s]
		var t := type_of(p)
		if p == EMPTY or t == KING:
			continue
		if t == PAWN or t == ROOK or t == QUEEN:
			return false
		minors.append([t, s, color_of(p)])
	if minors.size() <= 1:
		return true
	# Only bishops, all on squares of one colour.
	var colour := -1
	for m in minors:
		if m[0] != BISHOP:
			return false
		var c: int = (file_of(m[1]) + rank_of(m[1])) & 1
		if colour >= 0 and c != colour:
			return false
		colour = c
	return true


## The state of the game:
## {"over": bool, "result": "1-0" | "0-1" | "1/2-1/2" | "*", "reason": String,
##  "check": bool, "claimable": "" | "threefold" | "fifty-move"}
## Automatic draws: stalemate, insufficient material, fivefold repetition,
## the seventy-five-move rule. Threefold and fifty-move are claimable; the
## game claims them for the player (and the AI claims when it is not winning).
func status() -> Dictionary:
	var moves := legal_moves()
	var check := in_check()
	var out := {"over": false, "result": "*", "reason": "", "check": check, "claimable": ""}
	if moves.is_empty():
		out.over = true
		if check:
			out.result = "0-1" if side == WHITE_SIDE else "1-0"
			out.reason = "checkmate"
		else:
			out.result = "1/2-1/2"
			out.reason = "stalemate"
		return out
	if insufficient_material():
		out.over = true
		out.result = "1/2-1/2"
		out.reason = "insufficient material"
		return out
	var reps := repetitions()
	if reps >= 5:
		out.over = true
		out.result = "1/2-1/2"
		out.reason = "fivefold repetition"
		return out
	if halfmove >= 150:
		out.over = true
		out.result = "1/2-1/2"
		out.reason = "seventy-five-move rule"
		return out
	if reps >= 3:
		out.claimable = "threefold"
	elif halfmove >= 100:
		out.claimable = "fifty-move"
	return out


# ---------------------------------------------------------------------------
# SAN
# ---------------------------------------------------------------------------

## Standard algebraic notation of a legal move [m] in the current position.
func san(m: int) -> String:
	var from := move_from(m)
	var to := move_to(m)
	var flags := move_flags(m)
	var p := board[from]
	var t := type_of(p)
	var s := ""
	if flags & F_CASTLE:
		s = "O-O" if to > from else "O-O-O"
	else:
		if t != PAWN:
			s += " NBRQK"[t - 1]
			# Disambiguation.
			var same_file := false
			var same_rank := false
			var ambiguous := false
			for o in legal_moves():
				if o == m or move_to(o) != to or move_from(o) == from:
					continue
				if board[move_from(o)] != p:
					continue
				ambiguous = true
				if file_of(move_from(o)) == file_of(from):
					same_file = true
				if rank_of(move_from(o)) == rank_of(from):
					same_rank = true
			if ambiguous:
				if not same_file:
					s += "abcdefgh"[file_of(from)]
				elif not same_rank:
					s += str(rank_of(from) + 1)
				else:
					s += sq_name(from)
		elif flags & F_CAPTURE:
			s += "abcdefgh"[file_of(from)]
		if flags & F_CAPTURE:
			s += "x"
		s += sq_name(to)
		if move_promo(m):
			s += "=" + " NBRQ"[move_promo(m) - 1]
	make(m)
	if in_check():
		s += "#" if legal_moves().is_empty() else "+"
	unmake()
	return s


## The legal move a SAN string names, or -1.
func move_from_san(text: String) -> int:
	var want := text.strip_edges().replace("+", "").replace("#", "").replace("!", "").replace("?", "").replace("0-0-0", "O-O-O").replace("0-0", "O-O")
	for m in legal_moves():
		if san(m).replace("+", "").replace("#", "") == want:
			return m
	return -1


func clone():
	var c = get_script().new(fen())
	c._history = _history.duplicate()
	return c
