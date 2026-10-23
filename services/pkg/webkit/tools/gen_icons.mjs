// Generates src/00_icons.js: the Material icons (round style, Apache-2.0,
// from the @material-design-icons/svg package) the app's icon names map to,
// plus common ones, as SVG path data.
//
//   npm pack @material-design-icons/svg@0.14.15 && tar xzf *.tgz
//   node tools/gen_icons.mjs <extracted package dir> <map.txt> <used.txt>
//
// map.txt: "<app name> <material name>" lines (Elpian, Surface Spec and kit names);
// used.txt: material names the Flutter app uses.
import fs from 'node:fs';
import path from 'node:path';

const [pkg, mapFile, usedFile] = process.argv.slice(2);
const extra = `add remove edit delete search settings home menu close check refresh info warning error help star star_border star_half
favorite favorite_border share download upload filter_list sort more_vert more_horiz expand_more expand_less chevron_left chevron_right
arrow_back arrow_forward arrow_upward arrow_downward arrow_drop_up arrow_drop_down north south east west north_east south_east
account_circle person person_add group groups notifications notifications_off mail phone call calendar_today calendar_month schedule
event alarm timer hourglass_empty history update attach_money account_balance account_balance_wallet trending_up trending_down
trending_flat show_chart bar_chart stacked_bar_chart pie_chart donut_large candlestick_chart insights analytics query_stats leaderboard
currency_bitcoin currency_exchange paid payments payment credit_card savings receipt receipt_long shopping_cart shopping_bag sell
local_offer bolt flash_on cloud cloud_upload cloud_download wb_sunny water_drop air thermostat ac_unit umbrella public language link
link_off code terminal data_object storage dns memory hub account_tree timeline speed flag bookmark bookmark_border label visibility
visibility_off lock lock_open key vpn_key security verified verified_user shield gpp_good play_arrow pause stop skip_next skip_previous
fast_forward fast_rewind replay volume_up volume_down volume_off volume_mute mic mic_off videocam photo image camera_alt collections
folder folder_open description article note_add content_copy content_paste content_cut save send chat chat_bubble forum comment
smart_toy psychology auto_awesome rocket_launch swap_horiz swap_vert sync sync_alt open_in_new open_in_full close_fullscreen launch
logout login dashboard apps grid_view view_list view_module table_chart table_rows tune build construction bug_report science school
work place location_on map explore directions flight local_shipping inventory inventory_2 category done done_all check_circle
check_circle_outline cancel add_circle add_circle_outline remove_circle remove_circle_outline radio_button_checked
radio_button_unchecked check_box check_box_outline_blank indeterminate_check_box toggle_on toggle_off light_mode dark_mode palette
brush format_bold format_italic format_list_bulleted format_list_numbered format_quote title text_fields drag_indicator drag_handle
push_pin attach_file print qr_code fingerprint face emoji_emotions thumb_up thumb_down whatshot local_fire_department
emoji_events workspace_premium military_tech diamond token toll stars grade circle radio_button_off square crop_square change_history
lens fiber_manual_record pending pending_actions task_alt rule fact_check list checklist menu_open first_page last_page unfold_more
unfold_less zoom_in zoom_out fullscreen fullscreen_exit crop rotate_right rotate_left flip undo redo highlight_off report
report_problem new_releases campaign announcement priority_high error_outline warning_amber info_outline help_outline
notifications_active notifications_none mark_email_unread inbox outbox drafts archive unarchive delete_outline delete_forever
restore_from_trash cached autorenew loop shuffle repeat playlist_add queue_music library_books menu_book import_contacts
store storefront business apartment domain factory engineering handyman precision_manufacturing electric_bolt battery_full
battery_charging_full power power_settings_new wifi signal_cellular_alt bluetooth devices computer laptop smartphone tablet tv
watch keyboard mouse headphones speaker router cast sensors satellite_alt rss_feed podcasts newspaper feed dynamic_feed
travel_explore manage_search saved_search youtube_searched_for filter_alt filter_alt_off calculate functions percent
exposure_plus_1 exposure_neg_1 plus_one numbers pin tag alternate_email badge contact_page contacts how_to_reg person_search
manage_accounts admin_panel_settings supervisor_account support_agent volunteer_activism handshake celebration cake
sports_esports casino token_outlined monetization_on price_change price_check request_quote point_of_sale account_balance_outlined
real_estate_agent show_chart_outlined ssid_chart area_chart scatter_plot bubble_chart multiline_chart waterfall_chart stacked_line_chart
data_usage data_exploration donut_small legend_toggle align_horizontal_left space_dashboard view_quilt view_agenda view_column
view_week view_day calendar_view_month today date_range event_available event_busy more_time access_time watch_later av_timer
offline_bolt cloud_off cloud_done cloud_sync sync_problem error_outline wifi_off portable_wifi_off`;
const names = new Set(extra.split(/\s+/).filter(Boolean));
const aliases = {};
for (const line of fs.readFileSync(mapFile, 'utf8').split('\n')) {
  const [alias, icon] = line.trim().split(/\s+/);
  if (!alias || !icon) continue;
  aliases[alias] = icon;
  names.add(icon);
}
for (const n of fs.readFileSync(usedFile, 'utf8').split('\n')) if (n.trim()) names.add(n.trim());

const icons = {};
const missing = [];
function load(name) {
  let style = 'round', base = name;
  if (base.endsWith('_rounded')) base = base.slice(0, -8);
  else if (base.endsWith('_outlined')) { base = base.slice(0, -9); style = 'outlined'; }
  else if (base.endsWith('_sharp')) { base = base.slice(0, -6); style = 'sharp'; }
  for (const s of [style, 'round', 'filled']) {
    const file = path.join(pkg, s, base + '.svg');
    if (fs.existsSync(file)) {
      const svg = fs.readFileSync(file, 'utf8');
      const d = [...svg.matchAll(/<path[^>]*?\sd="([^"]+)"/g)].map((m) => m[1]);
      const circles = [...svg.matchAll(/<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"/g)]
        .map(([, cx, cy, r]) => `M${+cx - +r} ${cy}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0z`);
      if (d.length || circles.length) return [...d, ...circles].join('');
    }
  }
  return null;
}
for (const n of [...names].sort()) {
  const d = load(n);
  if (d) icons[n] = d; else missing.push(n);
}
for (const [a, i] of Object.entries(aliases)) if (!icons[i]) delete aliases[a];
const out = `// Generated by tools/gen_icons.mjs: Material icons (round style), Apache-2.0,
// https://github.com/marella/material-design-icons. Do not edit.
const ICONS = ${JSON.stringify(icons)};
const ICON_ALIASES = ${JSON.stringify(aliases)};
`;
fs.writeFileSync(new URL('../src/00_icons.js', import.meta.url), out);
console.log(Object.keys(icons).length, 'icons;', Object.keys(aliases).length, 'aliases; missing:', missing.join(' '));
