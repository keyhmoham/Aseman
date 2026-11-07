"""The rules of the arena: ratings, experience and levels, achievements,
what a believable match result looks like, room themes and chat hygiene.
Pure functions, no I/O — the server and the tests share them."""

import math
import re

# The AI opponents' ratings, by level, for Elo (chess) and for weighting.
AI_RATING = {1: 800, 2: 1100, 3: 1400, 4: 1650, 5: 1900}
START_RATING = 1200
K_FACTOR = 32

ROOM_THEMES = {
    "arena": {"title": "Neon Arena", "accent": "#6aa8ff", "bg": "#0b1020", "floor": "#1b2236", "light": "#7fb2ff"},
    "rooftop": {"title": "City Rooftop", "accent": "#ff9a5c", "bg": "#1d1a2a", "floor": "#3a3a42", "light": "#ffc48a"},
    "lab": {"title": "Research Lab", "accent": "#5ce1c2", "bg": "#0e1a1c", "floor": "#e4e8ea", "light": "#d8fff4"},
    "garage": {"title": "Workshop Garage", "accent": "#ffd166", "bg": "#15130f", "floor": "#4a4740", "light": "#ffe2a6"},
    "lounge": {"title": "Midnight Lounge", "accent": "#c38bff", "bg": "#120d1c", "floor": "#2a1f3a", "light": "#e0c2ff"},
}
GARAGE_THEMES = ("garage", "lab")
VISIBILITY = ("public", "friends", "private")

HANDLE = re.compile(r"^[a-z0-9][a-z0-9_.-]{1,30}$")
SLUG = re.compile(r"^[a-z][a-z0-9-]{2,40}$")
COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")

ACHIEVEMENTS = {
    "first_match": {"title": "Rookie", "desc": "Play your first match", "icon": "sports_esports", "xp": 50},
    "first_win": {"title": "First Blood", "desc": "Win your first match", "icon": "emoji_events", "xp": 100},
    "chess_checkmate": {"title": "Checkmate", "desc": "Win a chess game by checkmate", "icon": "extension", "xp": 100},
    "chess_master": {"title": "Grandmaster's Bane", "desc": "Beat the chess AI at level 5", "icon": "military_tech", "xp": 500},
    "chess_rated_1500": {"title": "Club Player", "desc": "Reach a chess rating of 1500", "icon": "trending_up", "xp": 250},
    "city_secured": {"title": "City Secured", "desc": "Clear every wave in City Strike", "icon": "shield", "xp": 150},
    "city_sharpshooter": {"title": "Sharpshooter", "desc": "Win City Strike with 50% accuracy or better", "icon": "my_location", "xp": 250},
    "city_headhunter": {"title": "Headhunter", "desc": "10 headshots in one City Strike match", "icon": "center_focus_strong", "xp": 200},
    "city_veteran": {"title": "Veteran", "desc": "Win City Strike at difficulty 5", "icon": "workspace_premium", "xp": 500},
    "streak_3": {"title": "On Fire", "desc": "Win three matches in a row", "icon": "local_fire_department", "xp": 200},
    "social_5": {"title": "Squad Up", "desc": "Have five friends", "icon": "group", "xp": 100},
    "host_3": {"title": "Host", "desc": "Open three rooms", "icon": "groups", "xp": 100},
    "creator": {"title": "Creator", "desc": "Publish a game made with the Forge", "icon": "construction", "xp": 500},
}

# What a game may plausibly report (anti-tamper bounds on results).
LIMITS = {
    "arena-chess": {"min_duration": 3, "max_score": 600},
    "city-strike": {"min_duration": 10, "max_score_per_s": 400, "max_kills": 14 * 6},
}

_BAD = re.compile(r"\b(fuck|shit|bitch|cunt|nigg\w*|fagg\w*|retard)\b", re.I)


def clean_text(text, limit=500):
    """Chat text as it is stored: trimmed, bounded, control characters
    removed, slurs and the worst words masked."""
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", str(text or "")).strip()[:limit]
    return _BAD.sub(lambda m: m.group(0)[0] + "*" * (len(m.group(0)) - 1), text)


def expected(ra, rb):
    return 1.0 / (1.0 + 10 ** ((rb - ra) / 400.0))


def elo(rating, opponent, outcome, games_played=0):
    """The new rating after one game. Provisional players (fewer than 10
    games) move faster."""
    s = {"win": 1.0, "draw": 0.5, "loss": 0.0}[outcome]
    k = K_FACTOR * (1.5 if games_played < 10 else 1.0)
    return int(round(rating + k * (s - expected(rating, opponent))))


def level_for(xp):
    """Levels grow with the square root of experience: 100 XP for level 2,
    400 for 3, 900 for 4, …"""
    return int(math.sqrt(max(0, xp) / 100.0)) + 1


def level_progress(xp):
    lv = level_for(xp)
    lo, hi = 100 * (lv - 1) ** 2, 100 * lv ** 2
    return {"level": lv, "xp": xp, "into": xp - lo, "span": hi - lo, "next_at": hi}


def match_xp(game, result):
    """Experience for a finished match."""
    base = {"win": 120, "draw": 60, "loss": 25}.get(result.get("outcome"), 0)
    diff = int(result.get("level") or result.get("difficulty") or 3)
    return base + diff * 10 + min(int(result.get("score") or 0) // 50, 200)


def plausible(game, result, duration_server_s):
    """Problems with a reported result, or []: it must say how it ended,
    fit the game's bounds and not claim more time than has passed."""
    problems = []
    if result.get("outcome") not in ("win", "loss", "draw"):
        problems.append("outcome must be win, loss or draw")
    lim = LIMITS.get(game, {})
    score = result.get("score", 0)
    if not isinstance(score, (int, float)) or score < 0:
        problems.append("score must be a number ≥ 0")
        score = 0
    dur = result.get("duration_s", duration_server_s)
    if not isinstance(dur, (int, float)) or dur < 0:
        problems.append("duration_s must be a number")
        dur = duration_server_s
    if dur > duration_server_s + 30:
        problems.append("the match claims more time than has passed")
    if result.get("outcome") == "win" and duration_server_s < lim.get("min_duration", 0):
        problems.append("a win this fast is not believable")
    if "max_score" in lim and score > lim["max_score"]:
        problems.append("score above the game's maximum")
    if "max_score_per_s" in lim and score > lim["max_score_per_s"] * max(duration_server_s, 1) + 2000:
        problems.append("score too high for the time played")
    if "max_kills" in lim and int(result.get("kills") or 0) > lim["max_kills"]:
        problems.append("more kills than the game has enemies")
    acc = result.get("accuracy")
    if acc is not None and not (isinstance(acc, (int, float)) and 0 <= acc <= 1):
        problems.append("accuracy must be between 0 and 1")
    return problems


def earned(game, result, stats):
    """Achievement ids a result earns, given the player's stats after it
    ({"matches", "wins", "streak", "friends", "rooms", "rating:<game>",
    "published"})."""
    out = []
    win = result.get("outcome") == "win"
    if stats.get("matches", 0) >= 1:
        out.append("first_match")
    if stats.get("wins", 0) >= 1:
        out.append("first_win")
    if stats.get("streak", 0) >= 3:
        out.append("streak_3")
    if game == "arena-chess":
        if win and result.get("reason") == "checkmate":
            out.append("chess_checkmate")
        if win and int(result.get("level") or 0) >= 5:
            out.append("chess_master")
        if stats.get("rating:arena-chess", 0) >= 1500:
            out.append("chess_rated_1500")
    if game == "city-strike":
        if win:
            out.append("city_secured")
            if (result.get("accuracy") or 0) >= 0.5:
                out.append("city_sharpshooter")
            if int(result.get("difficulty") or 0) >= 5:
                out.append("city_veteran")
        if int(result.get("headshots") or 0) >= 10:
            out.append("city_headhunter")
    return out


def social_achievements(stats):
    out = []
    if stats.get("friends", 0) >= 5:
        out.append("social_5")
    if stats.get("rooms", 0) >= 3:
        out.append("host_3")
    if stats.get("published", 0) >= 1:
        out.append("creator")
    return out


def validate_manifest(m):
    """Problems with a game's store manifest (game.json), or []. Every game
    on the platform is single-player against AI participants."""
    problems = []
    if not isinstance(m, dict):
        return ["the manifest must be a JSON object"]
    if not SLUG.match(str(m.get("slug", ""))):
        problems.append("slug: lowercase letters, digits and dashes, 3–41 characters, starting with a letter")
    for k in ("title", "tagline", "description", "version", "scene", "pack"):
        if not str(m.get(k, "")).strip():
            problems.append("%s is required" % k)
    if not str(m.get("scene", "")).startswith("res://"):
        problems.append("scene must be a res:// path in the pack")
    players = m.get("players") or {}
    if players.get("humans") != 1:
        problems.append("games here are single-player: players.humans must be 1")
    if not players.get("ai"):
        problems.append("the AI opponent(s) must be declared in players.ai")
    if "vs AI" not in str(m.get("mode", "")):
        problems.append('mode must say "single-player vs AI"')
    if m.get("engine") and not str(m.get("engine")).startswith("godot-4.3"):
        problems.append("engine must be godot-4.3 (the engine the client embeds)")
    if len(str(m.get("title", ""))) > 40:
        problems.append("title: at most 40 characters")
    return problems
