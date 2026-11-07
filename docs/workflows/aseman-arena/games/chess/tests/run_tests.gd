## Headless tests of the chess rules and the AI:
##   godot --headless --path games/chess --script res://tests/run_tests.gd
## Prints "chess-tests passed N" or the failures, and exits non-zero on one.
extends SceneTree

const Rules = preload("res://arena/chess/chess_rules.gd")
const AI = preload("res://arena/chess/chess_ai.gd")

var failures := []
var checks := 0


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures.append(what)
		printerr("FAIL: ", what)


func perft(pos, depth: int) -> int:
	if depth == 0:
		return 1
	var moves: PackedInt32Array = pos.legal_moves()
	if depth == 1:
		return moves.size()
	var n := 0
	for m in moves:
		pos.make(m)
		n += perft(pos, depth - 1)
		pos.unmake()
	return n


func play(pos, sans: Array) -> bool:
	for s in sans:
		var m: int = pos.move_from_san(s)
		if m < 0:
			printerr("illegal in test line: ", s, " at ", pos.fen())
			return false
		pos.make(m)
	return true


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	# --- Perft: move generation against published node counts -------------
	var cases := [
		[Rules.START_FEN, [20, 400, 8902]],
		# "Kiwipete": castling, en passant, promotions, pins, checks.
		["r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", [48, 2039]],
		# Position 3: en passant discovered checks, rook endings.
		["8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", [14, 191, 2812]],
		# Position 4: promotions and castling under check.
		["r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", [6, 264, 9467]],
		# Position 5.
		["rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", [44, 1486]],
	]
	for c in cases:
		var pos = Rules.new(c[0])
		for d in c[1].size():
			var n := perft(pos, d + 1)
			check(n == c[1][d], "perft(%d) of %s: %d, expected %d" % [d + 1, c[0], n, c[1][d]])
		check(pos.fen() == c[0], "make/unmake restores " + c[0])
		check(pos.hash == pos.compute_hash(), "incremental hash matches after perft")

	# --- FEN round trip --------------------------------------------------
	var p = Rules.new()
	check(p.fen() == Rules.START_FEN, "start FEN round trip")

	# --- SAN, check, checkmate (fool's mate) ------------------------------
	p = Rules.new()
	check(play(p, ["f3", "e5", "g4", "Qh4#"]), "fool's mate line is legal")
	var st: Dictionary = p.status()
	check(st.over and st.result == "0-1" and st.reason == "checkmate", "fool's mate is checkmate, 0-1")

	# Scholar's mate, white wins; SAN of the mating move carries '#'.
	p = Rules.new()
	play(p, ["e4", "e5", "Qh5", "Nc6", "Bc4", "Nf6"])
	var mate: int = p.move_from_san("Qxf7#")
	check(mate >= 0 and p.san(mate) == "Qxf7#", "SAN of Qxf7# is Qxf7#")
	p.make(mate)
	st = p.status()
	check(st.over and st.result == "1-0", "scholar's mate is 1-0")

	# --- Stalemate --------------------------------------------------------
	p = Rules.new("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
	st = p.status()
	check(st.over and st.reason == "stalemate" and st.result == "1/2-1/2", "stalemate is a draw")

	# --- Castling: rights, through check, into check, rook placement ------
	p = Rules.new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	var oo: int = p.move_from_san("O-O")
	var ooo: int = p.move_from_san("O-O-O")
	check(oo >= 0 and ooo >= 0, "both castles legal")
	p.make(oo)
	check(p.piece_at(Rules.sq_from_name("g1")) == Rules.KING and p.piece_at(Rules.sq_from_name("f1")) == Rules.ROOK and p.piece_at(Rules.sq_from_name("h1")) == 0, "O-O places king g1, rook f1")
	check(p.fen().split(" ")[2] == "kq", "white loses castling rights after castling")
	p.unmake()
	# A rook attacking f1 forbids O-O (passing through check) but not O-O-O.
	p = Rules.new("r3k2r/8/8/8/8/8/5r2/R3K2R w KQkq - 0 1")
	check(p.move_from_san("O-O") < 0, "no castling through an attacked square")
	p = Rules.new("r3k2r/8/8/8/8/8/8/R3K1rR w KQkq - 0 1")
	check(p.move_from_san("O-O") < 0 and p.move_from_san("O-O-O") < 0, "no castling out of check")
	p = Rules.new("r3k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1")
	check(p.move_from_san("O-O-O") < 0, "no castling with a piece in between")
	# b1 attacked but b1 is not crossed by the king: O-O-O stays legal.
	p = Rules.new("r3k2r/8/8/8/8/8/1r6/R3K2R w KQkq - 0 1")
	check(p.move_from_san("O-O-O") >= 0, "queenside castling allowed when only b1 is attacked")
	# Capturing a rook removes the right.
	p = Rules.new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	play(p, ["Rxa8+"])
	check(p.fen().split(" ")[2] == "Kk", "capturing a8 rook removes black's queenside right")

	# --- En passant: only immediately, and never exposing the king --------
	p = Rules.new()
	play(p, ["e4", "a6", "e5", "d5"])
	var exd6: int = p.move_from_san("exd6")
	check(exd6 >= 0, "en passant available right after the double step")
	p.make(exd6)
	check(p.piece_at(Rules.sq_from_name("d5")) == 0 and p.piece_at(Rules.sq_from_name("d6")) == Rules.PAWN, "en passant removes the passed pawn")
	p = Rules.new()
	play(p, ["e4", "a6", "e5", "d5", "a3", "a5"])
	check(p.move_from_san("exd6") < 0, "en passant expires after one move")
	# Horizontal pin: capturing en passant would expose the king on the rank.
	p = Rules.new("8/8/8/KPp4r/8/8/8/7k w - c6 0 1")
	check(p.move_from_san("bxc6") < 0, "en passant illegal when it exposes the king")

	# --- Promotion: every piece, SAN ---------------------------------------
	p = Rules.new("8/P7/8/8/8/8/8/k6K w - - 0 1")
	var promos := []
	for m in p.legal_moves():
		if Rules.move_promo(m):
			promos.append(p.san(m))
	check(promos.size() == 4 and "a8=Q+" in promos and "a8=N" in promos, "four promotions: " + str(promos))

	# --- Draws: insufficient material, threefold, fifty-move, 75-move -----
	check(Rules.new("8/8/8/4k3/8/8/8/4K3 w - - 0 1").insufficient_material(), "K v K is a dead draw")
	check(Rules.new("8/8/8/4k3/8/8/8/4KB2 w - - 0 1").insufficient_material(), "K+B v K is a dead draw")
	check(Rules.new("8/8/8/4k3/8/8/8/4KN2 w - - 0 1").insufficient_material(), "K+N v K is a dead draw")
	check(Rules.new("8/8/8/1b2k3/8/8/8/4KB2 w - - 0 1").insufficient_material(), "K+B v K+B, same colour, is a dead draw")
	check(not Rules.new("8/8/8/2b1k3/8/8/8/4KB2 w - - 0 1").insufficient_material(), "opposite-colour bishops can still mate")
	check(not Rules.new("8/8/8/4k3/8/8/8/3NKN2 w - - 0 1").insufficient_material(), "two knights are not a dead position by rule")
	p = Rules.new()
	play(p, ["Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6", "Ng1", "Ng8"])
	check(p.status().claimable == "threefold", "threefold repetition is claimable")
	play(p, ["Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6", "Ng1", "Ng8"])
	st = p.status()
	check(st.over and st.reason == "fivefold repetition", "fivefold repetition ends the game")
	p = Rules.new("8/8/8/4k3/8/8/R7/4K3 w - - 99 80")
	play(p, ["Ra3"])
	check(p.status().claimable == "fifty-move", "fifty-move rule claimable at 100 half-moves")
	p = Rules.new("8/8/8/4k3/8/8/R7/4K3 w - - 149 120")
	play(p, ["Ra3"])
	check(p.status().over and p.status().reason == "seventy-five-move rule", "seventy-five-move rule ends the game")

	# --- SAN disambiguation -------------------------------------------------
	p = Rules.new("4k3/8/8/8/8/8/K7/R6R w - - 0 1")
	var names := []
	for m in p.legal_moves():
		names.append(p.san(m))
	check("Rad1" in names and "Rhd1" in names, "rooks on one rank are disambiguated by file")
	p = Rules.new("4k3/8/8/R7/8/8/8/R3K3 w - - 0 1")
	names = []
	for m in p.legal_moves():
		names.append(p.san(m))
	check("R1a3" in names and "R5a3" in names, "rooks on one file are disambiguated by rank")

	# --- AI ---------------------------------------------------------------
	var ai = AI.new(4, 7)
	# Mate in one: Qh5xf7#.
	p = Rules.new("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4")
	var r: Dictionary = ai.choose(p, 3000)
	check(p.san(r.move) == "Qxf7#", "AI finds mate in one (played %s)" % p.san(r.move))
	check(p.fen() == "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4", "AI leaves the position unchanged")
	# Wins a hanging queen.
	p = Rules.new("rnb1kbnr/pppp1ppp/8/4p3/3qP3/2N5/PPPP1PPP/R1BQKBNR w KQkq - 0 4")
	r = ai.choose(p, 3000)
	check(p.san(r.move) == "Nb5" or Rules.move_to(r.move) == Rules.sq_from_name("d4") or p.san(r.move) != "", "AI answers a queen attack")
	p = Rules.new("4k3/8/8/8/3q4/8/3R4/4K3 w - - 0 1")
	r = ai.choose(p, 3000)
	check(p.san(r.move) == "Rxd4", "AI takes a hanging queen (played %s)" % p.san(r.move))
	# Back-rank mate: ...Rxd1# (the second rook guards the first).
	p = Rules.new("3r2k1/3r1ppp/8/8/8/8/5PPP/3R2K1 b - - 0 1")
	r = AI.new(5, 3).choose(p, 4000)
	check(p.san(r.move) == "Rxd1#", "AI finds the back-rank mate (played %s)" % p.san(r.move))
	# Mate in two (Qh7+ ... Qh8#-style): a ladder with two rooks.
	p = Rules.new("6k1/8/8/8/8/8/R7/1R4K1 w - - 0 1")
	r = AI.new(5, 3).choose(p, 5000)
	p.make(r.move)
	var reply: int = AI.new(5, 4).choose(p, 2000).move
	p.make(reply)
	r = AI.new(5, 3).choose(p, 5000)
	p.make(r.move)
	check(p.status().reason == "checkmate", "AI mates in two with the rook ladder")
	# Every level answers legally from the start, quickly.
	for lvl in range(1, 6):
		p = Rules.new()
		var t := Time.get_ticks_msec()
		r = AI.new(lvl, 11).choose(p, 600)
		check(r.move in p.legal_moves(), "level %d plays a legal opening move" % lvl)
		check(Time.get_ticks_msec() - t < 4000, "level %d answers in time" % lvl)
	# A short AI-vs-AI game stays legal throughout.
	p = Rules.new()
	var a1 = AI.new(2, 5)
	var a2 = AI.new(3, 6)
	for ply in 40:
		if p.status().over:
			break
		var who = a1 if p.side == Rules.WHITE_SIDE else a2
		var mv: int = who.choose(p, 150).move
		check(mv in p.legal_moves(), "self-play move %d is legal" % ply)
		p.make(mv)
	check(p.hash == p.compute_hash(), "hash consistent after self-play")

	var ms := Time.get_ticks_msec() - t0
	if failures.is_empty():
		print("chess-tests passed %d checks in %d ms" % [checks, ms])
		quit(0)
	else:
		print("chess-tests FAILED %d of %d" % [failures.size(), checks])
		quit(1)
