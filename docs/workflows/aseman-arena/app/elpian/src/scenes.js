/* The 3D scenes (Scene3D on the embedded Godot engine): the person's garage
 * or lab, furnished with Poly Haven's CC0 models; each room's venue in its
 * theme, with the game's stage and the members standing around it; and a
 * game, mounted from its resource pack.
 *
 * Pure functions from data to the scene DSL, so the same scene is built for
 * the same data (the Scene3D only rebuilds when its scene changes). */

var ROBOT_SCALE = 0.4;          // Quaternius' robot is ~4.4 units tall: 1.75 m
var MODEL_VERSION = "1";

function modelSrc(base, file) { return base + "assets/models/" + file; }

function v3(a, b, c) { return [a, b, c]; }

function label3d(text, pos, color, size) {
  return { type: "Label3D", position: pos, props: { text: text, font_size: size || 48, pixel_size: 0.004, billboard: 1,
    modulate: color || "#ffffff", outline_size: 10, outline_modulate: "#000000cc", no_depth_test: false } };
}

function shellNodes(shell) {
  var w = shell.size[0], h = shell.size[1], d = shell.size[2];
  return [
    { type: "mesh", shape: "box", id: "floor", size: [w, 0.1, d], position: [0, -0.05, 0], color: shell.floor, roughness: 0.85 },
    { type: "mesh", shape: "box", id: "wall_back", size: [w, h, 0.12], position: [0, h / 2, -d / 2], color: shell.walls, roughness: 0.95 },
    { type: "mesh", shape: "box", id: "wall_left", size: [0.12, h, d], position: [-w / 2, h / 2, 0], color: shell.walls, roughness: 0.95 },
    { type: "mesh", shape: "box", id: "wall_right", size: [0.12, h, d], position: [w / 2, h / 2, 0], color: shell.walls, roughness: 0.95 },
    { type: "mesh", shape: "box", id: "skirting", size: [w, 0.14, 0.14], position: [0, 0.07, -d / 2 + 0.08], color: shell.trim },
    { type: "mesh", shape: "box", id: "beam1", size: [w, 0.18, 0.22], position: [0, h - 0.09, -d / 4], color: shell.trim },
    { type: "mesh", shape: "box", id: "beam2", size: [w, 0.18, 0.22], position: [0, h - 0.09, d / 4], color: shell.trim },
    // The accent light strip along the back wall.
    { type: "mesh", shape: "box", id: "neon", size: [w - 0.6, 0.05, 0.05], position: [0, h - 0.35, -d / 2 + 0.1], color: shell.accent, emission: shell.accent, emissionEnergy: 3.0 },
  ];
}

function lightNodes(list) {
  return list.map(function (l) {
    return { type: l.type, position: l.position, rotation: l.rotation, range: l.range, energy: l.energy, color: l.color, shadow: l.shadow };
  });
}

/* The person's 3D home. trophies: unlocked achievements; games: the store's
 * games, shown as arcade cabinets along the wall. */
function garageScene(garage, games) {
  var L = garage.layout, base = assetBase() || garage.asset_base || "", me = garage.me || {}, sh = L.shell;
  var nodes = shellNodes(sh);
  L.items.forEach(function (it) {
    nodes.push({ type: "model", id: it.id, src: modelSrc(base, it.file), version: MODEL_VERSION, position: it.position, rotation: it.rotation, scale: it.scale });
  });
  // The person, as their robot, with their name above.
  var a = L.spots.avatar;
  nodes.push({ type: "model", id: "avatar", src: modelSrc(base, "robot.glb"), version: MODEL_VERSION, position: a, rotation: [0, L.spots.avatar_turn || 180, 0], scale: ROBOT_SCALE });
  nodes.push(label3d(me.name || "You", [a[0], 2.05, a[2]], hex(me.color, "#ffffff"), 40));
  nodes.push(label3d("Level " + ((me.progress || {}).level || 1), [a[0], 1.86, a[2]], "#d0d6e4", 26));
  // Trophies on the shelf: one glowing token per achievement.
  var t = L.spots.trophies, trophies = garage.trophies || [];
  trophies.slice(0, 12).forEach(function (tr, i) {
    var row = Math.floor(i / 6), col = i % 6;
    var p = [t[0], t[1] + row * 0.42, t[2] - 0.75 + col * 0.3];
    nodes.push({ type: "mesh", shape: "cylinder", id: "trophy_base_" + i, radius: 0.07, height: 0.05, position: [p[0], p[1], p[2]], color: "#2b2b2b" });
    nodes.push({ type: "mesh", shape: "torus", id: "trophy_" + i, innerRadius: 0.035, outerRadius: 0.075, position: [p[0], p[1] + 0.12, p[2]], rotation: [0, 0, 90], color: sh.accent, emission: sh.accent, emissionEnergy: 1.6, metallic: 0.8, roughness: 0.2 });
  });
  // Arcade cabinets for the store's games, along the right of the room.
  (games || []).slice(0, 3).forEach(function (g, i) {
    var x = 0.9 + i * 1.05, z = -3.35, acc = hex(g.accent, sh.accent);
    nodes.push({ type: "node", id: "cab_" + i, position: [x, 0, z], children: [
      { type: "mesh", shape: "box", size: [0.78, 1.7, 0.6], position: [0, 0.85, 0], color: "#16181f", roughness: 0.4 },
      { type: "mesh", shape: "box", size: [0.62, 0.48, 0.04], position: [0, 1.28, 0.31], color: acc, emission: acc, emissionEnergy: 1.8 },
      { type: "mesh", shape: "box", size: [0.7, 0.08, 0.3], position: [0, 0.95, 0.38], color: "#2c2f3a" },
      { type: "mesh", shape: "box", size: [0.78, 0.12, 0.62], position: [0, 1.76, 0], color: acc, emission: acc, emissionEnergy: 0.8 },
    ] });
    nodes.push(label3d(g.title, [x, 2.05, z + 0.2], acc, 30));
  });
  return {
    environment: { bg: sh.bg, ambient: sh.ambient, ambientEnergy: 0.55 },
    camera: L.camera,
    lights: lightNodes(L.lights),
    nodes: nodes,
  };
}

/* A room's venue: the theme's space, the game's stage in the middle, the
 * members standing in a ring around it (online ones lit). */
function roomScene(room, base) {
  var th = room.theme_info || {}, acc = hex(room.game_accent, th.accent || "#6aa8ff");
  var nodes = [
    { type: "mesh", shape: "cylinder", id: "floor", radius: 7.5, height: 0.1, position: [0, -0.05, 0], color: th.floor || "#1b2236", roughness: 0.6, metallic: 0.2 },
    { type: "mesh", shape: "torus", id: "ring_outer", innerRadius: 6.9, outerRadius: 7.1, position: [0, 0.02, 0], color: th.accent, emission: th.accent, emissionEnergy: 2.2 },
    { type: "mesh", shape: "cylinder", id: "stage", radius: 1.6, height: 0.5, position: [0, 0.25, 0], color: "#151821", roughness: 0.3, metallic: 0.6 },
    { type: "mesh", shape: "torus", id: "stage_ring", innerRadius: 1.55, outerRadius: 1.68, position: [0, 0.52, 0], color: acc, emission: acc, emissionEnergy: 2.6 },
    { type: "mesh", shape: "cylinder", id: "beam", radius: 0.9, height: 3.2, position: [0, 2.1, 0], color: acc + "40", emission: acc, emissionEnergy: 0.35, transparency: true },
    { type: "mesh", shape: "torus", id: "holo1", innerRadius: 0.75, outerRadius: 0.85, position: [0, 1.6, 0], rotation: [70, 0, 0], color: acc, emission: acc, emissionEnergy: 2.0 },
    { type: "mesh", shape: "torus", id: "holo2", innerRadius: 0.5, outerRadius: 0.58, position: [0, 2.3, 0], rotation: [70, 40, 0], color: acc, emission: acc, emissionEnergy: 2.0 },
    label3d(room.game_title || "", [0, 4.3, -1.0], acc, 80),
    label3d(room.name || "", [0, 3.8, -1.0], "#ffffff", 44),
  ];
  // Pillars of light around the far edge, in the theme's colour (none
  // between the camera and the stage).
  for (var k = 0; k < 8; k++) {
    var ang = k / 8 * Math.PI * 2;
    if (Math.sin(ang) > 0.1) continue;
    nodes.push({ type: "mesh", shape: "box", id: "pillar_" + k, size: [0.25, 4.5, 0.25], position: [Math.cos(ang) * 7.6, 2.25, Math.sin(ang) * 7.6], color: "#0f121a", roughness: 0.3 });
    nodes.push({ type: "mesh", shape: "box", id: "pillar_glow_" + k, size: [0.08, 4.2, 0.08], position: [Math.cos(ang) * 7.45, 2.25, Math.sin(ang) * 7.45], color: th.accent, emission: th.accent, emissionEnergy: 2.4 });
  }
  if (room.theme === "garage" || room.theme === "lab") {
    nodes.push({ type: "model", id: "decor_a", src: modelSrc(base, room.theme === "lab" ? "chemistry_set.glb" : "covered_car.glb"), version: MODEL_VERSION, position: [-4.6, 0, -3.2], rotation: [0, 35, 0], scale: 1 });
    nodes.push({ type: "model", id: "decor_b", src: modelSrc(base, room.theme === "lab" ? "microscope.glb" : "tool_chest.glb"), version: MODEL_VERSION, position: [4.4, 0, -3.6], rotation: [0, -40, 0], scale: 1 });
  }
  // The members stand in an arc behind the stage, facing the camera.
  var members = (room.member_list || []).slice(0, 12);
  members.forEach(function (m, i) {
    var ang = -Math.PI / 2 + (i - (members.length - 1) / 2) * 0.36;
    var r = 3.6, x = Math.cos(ang) * r, z = Math.sin(ang) * r;
    nodes.push({ type: "model", id: "member_" + i, src: modelSrc(base, "robot.glb"), version: MODEL_VERSION, position: [x, 0, z], rotation: [0, -x * 6, 0], scale: ROBOT_SCALE });
    nodes.push(label3d((m.online ? "● " : "") + m.handle, [x, 2.0, z], m.online ? hex(m.color, "#ffffff") : "#8a90a0", 32));
  });
  return {
    environment: { bg: th.bg || "#0b1020", ambient: th.light || "#8894b0", ambientEnergy: 0.5 },
    camera: { position: [0, 4.6, 9.5], rotation: [-20, 0, 0], fov: 55 },
    lights: [
      { type: "omni", position: [0, 4.2, 0], range: 11, energy: 1.6, color: acc },
      { type: "omni", position: [0, 3.0, 5.0], range: 9, energy: 1.1, color: th.light || "#ffffff" },
      { type: "directional", rotation: [-60, 25, 0], energy: 0.45, shadow: true },
    ],
    nodes: nodes,
  };
}

/* A game, mounted from its pack and started with its launch parameters.
 * A client without the 3D engine (the web client) runs the game's browser
 * build (`web`) in its place; its events come back the same way. */
function gameScene(launch, base) {
  var src = base && launch.pack_path ? base + launch.pack_path : launch.pack;
  var pack = { type: "pack", id: "game", src: src, scene: launch.scene, version: launch.version, params: launch.params };
  if (launch.embed && base) pack.web = base + launch.embed;
  return { nodes: [pack] };
}
