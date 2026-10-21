// Runs backend.js the way the node runs it: on QuickJS in the tool runtime,
// called over MCP. Open-Meteo is stubbed unless LIVE=1, which calls the real
// API (Node's fetch; set NODE_USE_ENV_PROXY=1 behind a proxy).
//
//   node --test deploy/tools/weather/test/backend.test.mjs
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { handleMcp } from '../../../tool-runtime/lib/mcp.mjs';
import { createQuickJSEngine } from '../../../tool-runtime/lib/quickjs.mjs';

const source = await readFile(new URL('../backend.js', import.meta.url), 'utf8');
const live = process.env.LIVE === '1';

const geocoding = {
  results: [{ name: 'London', admin1: 'England', country: 'United Kingdom', country_code: 'GB', latitude: 51.508, longitude: -0.126, timezone: 'Europe/London' }],
};

function forecastFor(params) {
  const hours = Array.from({ length: 48 }, (_, i) => {
    const day = 13 + Math.floor(i / 24);
    return `2026-10-${day}T${String(i % 24).padStart(2, '0')}:00`;
  });
  const days = Array.from({ length: 7 }, (_, i) => `2026-10-${String(13 + i).padStart(2, '0')}`);
  const out = { timezone: 'Europe/London' };
  if (params.get('current')) {
    out.current = {
      time: '2026-10-13T14:15', temperature_2m: 12.6, apparent_temperature: 10.2, relative_humidity_2m: 81,
      is_day: 1, precipitation: 0.4, weather_code: 61, cloud_cover: 90, pressure_msl: 1008.4,
      wind_speed_10m: 18.2, wind_direction_10m: 225, wind_gusts_10m: 34.9,
    };
  }
  if (params.get('hourly')) {
    out.hourly = {
      time: hours,
      temperature_2m: hours.map((_, i) => 10 + (i % 6)),
      precipitation_probability: hours.map((_, i) => (i * 7) % 100),
      weather_code: hours.map((_, i) => [0, 2, 61, 3][i % 4]),
      wind_speed_10m: hours.map(() => 15),
      is_day: hours.map((_, i) => (i % 24 >= 7 && i % 24 <= 18 ? 1 : 0)),
    };
  }
  if (params.get('daily')) {
    out.daily = {
      time: days, weather_code: [61, 3, 0, 80, 95, 71, 2],
      temperature_2m_max: [14.2, 15, 17.6, 13, 12, 6, 11], temperature_2m_min: [8.1, 9, 10, 7, 6, -1, 4],
      precipitation_sum: [3.2, 0, 0, 5.5, 12, 2, 0], precipitation_probability_max: [80, 10, 0, 60, 90, 40, 5],
      wind_speed_10m_max: [30, 20, 12, 25, 40, 18, 15], uv_index_max: [1.5, 2, 3.1, 1, 0.5, 1, 2],
      sunrise: days.map((d) => `${d}T07:21`), sunset: days.map((d) => `${d}T18:09`),
    };
  }
  if (params.get('temperature_unit') === 'fahrenheit') out.current && (out.current.temperature_2m = 54.7);
  return out;
}

const requests = [];
async function stubFetch({ url }) {
  const u = new URL(url);
  requests.push(u);
  if (u.hostname === 'geocoding-api.open-meteo.com') {
    const found = u.searchParams.get('name') === 'Nowhereville' ? {} : geocoding;
    return { status: 200, ok: true, json: found };
  }
  if (u.hostname === 'api.open-meteo.com') return { status: 200, ok: true, json: forecastFor(u.searchParams) };
  return { status: 404, ok: false, json: null };
}

async function liveFetch({ url }) {
  const res = await fetch(url);
  return { status: res.status, ok: res.ok, json: await res.json().catch(() => null) };
}

async function setup() {
  const engine = await createQuickJSEngine(source);
  const tools = await engine.list();
  const call = async (name, args) => {
    const [, body] = await handleMcp({
      engine, tools, token: 't', fetch: live ? liveFetch : stubFetch,
      headers: { 'x-aseman-token': 't', 'x-aseman-actor': 'alice', 'x-aseman-space': 's1' },
      message: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } },
    });
    return body.result;
  };
  return { engine, tools, call };
}

test('declares its microtools with argument schemas', async () => {
  const { engine, tools } = await setup();
  assert.deepEqual(tools.map((t) => t.name), ['weather_report', 'current_weather', 'daily_forecast', 'hourly_forecast', 'search_places']);
  assert.ok(tools[0].inputSchema.properties.city);
  assert.deepEqual(tools[0].inputSchema.properties.units.enum, ['metric', 'imperial']);
  engine.dispose();
});

test('weather_report: a whole report, ready to show', async () => {
  const { engine, call } = await setup();
  const result = await call('weather_report', { city: 'London' });
  assert.equal(result.isError, false, result.content?.[0]?.text);
  const r = result.structuredContent;
  assert.equal(r.place.name, 'London');
  assert.ok(r.place.label.startsWith('London'));
  assert.ok(r.current.temperature_text.endsWith('°'));
  assert.ok(r.current.emoji.length > 0 && r.current.condition.length > 0);
  assert.equal(r.days.length, 7);
  assert.equal(r.days[0].label, 'Today');
  assert.equal(r.days[1].label, 'Tomorrow');
  assert.ok(r.hours.length > 0 && r.hours.length <= 12);
  assert.equal(r.hours[0].label, 'Now');
  assert.match(r.summary, /London/);
  if (!live) {
    assert.equal(r.current.condition, 'Light rain');
    assert.equal(r.current.wind_text, '18 km/h SW');
    assert.equal(r.today.range_text, '14° / 8°');
    assert.equal(r.today.sunrise, '07:21');
    assert.equal(r.days[2].label, 'Thu 15 Oct');
    assert.equal(r.hours[0].time, '2026-10-13T14:00', 'the hours start at the current hour');
    assert.equal(r.unit_labels.temperature, '°C');
  }
  engine.dispose();
});

test('imperial units are asked of Open-Meteo and labelled', { skip: live }, async () => {
  const { engine, call } = await setup();
  requests.length = 0;
  const r = (await call('current_weather', { city: 'London', units: 'imperial' })).structuredContent;
  const forecastRequest = requests.find((u) => u.hostname === 'api.open-meteo.com');
  assert.equal(forecastRequest.searchParams.get('temperature_unit'), 'fahrenheit');
  assert.equal(forecastRequest.searchParams.get('wind_speed_unit'), 'mph');
  assert.equal(r.unit_labels.temperature, '°F');
  assert.equal(r.current.temperature_text, '55°');
  engine.dispose();
});

test('coordinates skip the geocoder; forecasts honour their length', { skip: live }, async () => {
  const { engine, call } = await setup();
  requests.length = 0;
  const days = (await call('daily_forecast', { latitude: 40.4, longitude: -3.7, days: 3 })).structuredContent;
  assert.ok(!requests.some((u) => u.hostname === 'geocoding-api.open-meteo.com'));
  assert.equal(days.days.length, 3);
  const hours = (await call('hourly_forecast', { city: 'London', hours: 5 })).structuredContent;
  assert.equal(hours.hours.length, 5);
  const places = (await call('search_places', { query: 'London' })).structuredContent;
  assert.equal(places.places[0].country_code, 'GB');
  engine.dispose();
});

test('an unknown place or a missing one is an error the caller reads', async () => {
  const { engine, call } = await setup();
  const unknown = await call('weather_report', { city: 'Nowhereville' });
  assert.equal(unknown.isError, true);
  assert.match(unknown.content[0].text, /No place called "Nowhereville"/);
  const missing = await call('current_weather', {});
  assert.equal(missing.isError, true);
  assert.match(missing.content[0].text, /Say which place/);
  engine.dispose();
});
