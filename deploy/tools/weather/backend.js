// Weather — an Aseman tool backend for QuickJS.
//
// Weather data comes from Open-Meteo (https://open-meteo.com): free, no API
// key. Requests go out through the runtime's `aseman.fetch` host API (the
// program itself has no network). Every microtool takes a place either by
// name (`city`) or by coordinates (`latitude` + `longitude`), and `units`
// (`metric`, the default, or `imperial`).

var GEOCODING = 'https://geocoding-api.open-meteo.com/v1/search';
var FORECAST = 'https://api.open-meteo.com/v1/forecast';

var PLACE = {
  city: { type: 'string', description: 'Place name, e.g. "Lisbon" or "Austin, Texas".' },
  latitude: { type: 'number', description: 'Latitude, instead of a city.' },
  longitude: { type: 'number', description: 'Longitude, instead of a city.' },
  units: { type: 'string', enum: ['metric', 'imperial'], description: 'metric (°C, km/h, mm) or imperial (°F, mph, in). Default metric.' },
};

function input(extra) {
  var properties = {};
  for (var k in PLACE) properties[k] = PLACE[k];
  for (var e in extra || {}) properties[e] = extra[e];
  return { type: 'object', properties: properties };
}

function tools() {
  return [
    {
      name: 'weather_report',
      description: 'Everything for a place in one call: current conditions, today, the next 12 hours and the next 7 days, with emoji, labels and units ready to show.',
      input: input(),
    },
    {
      name: 'current_weather',
      description: 'Current conditions for a place: temperature, feels-like, condition, humidity, wind, pressure, cloud cover, precipitation.',
      input: input(),
    },
    {
      name: 'daily_forecast',
      description: 'Day-by-day forecast for a place: high/low, condition, precipitation and its chance, wind, UV index, sunrise and sunset.',
      input: input({ days: { type: 'integer', minimum: 1, maximum: 16, description: 'How many days, 1-16. Default 7.' } }),
    },
    {
      name: 'hourly_forecast',
      description: 'Hour-by-hour forecast for a place: temperature, condition, chance of precipitation and wind.',
      input: input({ hours: { type: 'integer', minimum: 1, maximum: 72, description: 'How many hours ahead, 1-72. Default 24.' } }),
    },
    {
      name: 'search_places',
      description: 'Places matching a name, to tell apart places with the same name.',
      input: { type: 'object', properties: { query: { type: 'string', description: 'Place name to search.' } }, required: ['query'] },
    },
  ];
}

// --- WMO weather codes -------------------------------------------------------

var CONDITIONS = {
  0: ['Clear sky', '☀️', '🌙'],
  1: ['Mainly clear', '🌤️', '🌙'],
  2: ['Partly cloudy', '⛅', '☁️'],
  3: ['Overcast', '☁️', '☁️'],
  45: ['Fog', '🌫️', '🌫️'],
  48: ['Freezing fog', '🌫️', '🌫️'],
  51: ['Light drizzle', '🌦️', '🌧️'],
  53: ['Drizzle', '🌦️', '🌧️'],
  55: ['Heavy drizzle', '🌧️', '🌧️'],
  56: ['Freezing drizzle', '🌧️', '🌧️'],
  57: ['Heavy freezing drizzle', '🌧️', '🌧️'],
  61: ['Light rain', '🌦️', '🌧️'],
  63: ['Rain', '🌧️', '🌧️'],
  65: ['Heavy rain', '🌧️', '🌧️'],
  66: ['Freezing rain', '🌧️', '🌧️'],
  67: ['Heavy freezing rain', '🌧️', '🌧️'],
  71: ['Light snow', '🌨️', '🌨️'],
  73: ['Snow', '🌨️', '🌨️'],
  75: ['Heavy snow', '❄️', '❄️'],
  77: ['Snow grains', '🌨️', '🌨️'],
  80: ['Light showers', '🌦️', '🌧️'],
  81: ['Showers', '🌧️', '🌧️'],
  82: ['Violent showers', '⛈️', '⛈️'],
  85: ['Snow showers', '🌨️', '🌨️'],
  86: ['Heavy snow showers', '❄️', '❄️'],
  95: ['Thunderstorm', '⛈️', '⛈️'],
  96: ['Thunderstorm with hail', '⛈️', '⛈️'],
  99: ['Severe thunderstorm with hail', '⛈️', '⛈️'],
};

function condition(code, isDay) {
  var c = CONDITIONS[code] || ['Unknown', '🌡️', '🌡️'];
  return { code: code, text: c[0], emoji: isDay === 0 ? c[2] : c[1] };
}

var COMPASS = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
function compass(degrees) {
  if (degrees === null || degrees === undefined) return '';
  return COMPASS[Math.round(((degrees % 360) + 360) % 360 / 22.5) % 16];
}

var WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// Open-Meteo times are local to the place ("2026-10-13T14:00"): read them as
// text, never through the runtime's own time zone.
function dayLabel(date, index) {
  if (index === 0) return 'Today';
  if (index === 1) return 'Tomorrow';
  var p = date.split('-');
  var d = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2]));
  return WEEKDAYS[d.getUTCDay()] + ' ' + (+p[2]) + ' ' + MONTHS[+p[1] - 1];
}
function clock(time) { return time ? time.slice(11, 16) : ''; }

function round(n) { return n === null || n === undefined ? null : Math.round(n); }
function one(n) { return n === null || n === undefined ? null : Math.round(n * 10) / 10; }

// --- requests --------------------------------------------------------------------

function query(params) {
  var parts = [];
  for (var k in params) {
    if (params[k] !== undefined && params[k] !== null && params[k] !== '') {
      parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(params[k]));
    }
  }
  return parts.join('&');
}

function getJSON(url) {
  var res = askHost('aseman.fetch', { url: url });
  if (!res || !res.ok) {
    var reason = res && res.json && res.json.reason ? res.json.reason : (res ? 'HTTP ' + res.status : 'no response');
    throw new Error('Open-Meteo: ' + reason);
  }
  return res.json;
}

function units(args) {
  var imperial = args && args.units === 'imperial';
  return {
    system: imperial ? 'imperial' : 'metric',
    params: imperial ? { temperature_unit: 'fahrenheit', wind_speed_unit: 'mph', precipitation_unit: 'inch' } : {},
    labels: imperial
      ? { temperature: '°F', wind: 'mph', precipitation: 'in', pressure: 'hPa' }
      : { temperature: '°C', wind: 'km/h', precipitation: 'mm', pressure: 'hPa' },
  };
}

function describePlace(p) {
  var region = [p.admin1, p.country].filter(function (x) { return x; }).join(', ');
  return {
    name: p.name,
    region: region,
    label: region ? p.name + ', ' + region : p.name,
    country_code: p.country_code || '',
    latitude: p.latitude,
    longitude: p.longitude,
    timezone: p.timezone || 'auto',
  };
}

function searchPlaces(name, count) {
  var data = getJSON(GEOCODING + '?' + query({ name: name, count: count || 5, language: 'en', format: 'json' }));
  return (data && data.results ? data.results : []).map(describePlace);
}

function place(args) {
  args = args || {};
  if (typeof args.latitude === 'number' && typeof args.longitude === 'number') {
    var label = args.city || (one(args.latitude) + ', ' + one(args.longitude));
    return { name: label, region: '', label: label, country_code: '', latitude: args.latitude, longitude: args.longitude, timezone: 'auto' };
  }
  var city = String(args.city || '').trim();
  if (!city) throw new Error('Say which place: a city, or latitude and longitude.');
  var found = searchPlaces(city, 1);
  if (!found.length) throw new Error('No place called "' + city + '" was found.');
  return found[0];
}

function forecast(where, u, fields) {
  var params = {
    latitude: where.latitude,
    longitude: where.longitude,
    timezone: 'auto',
  };
  for (var k in u.params) params[k] = u.params[k];
  for (var f in fields) params[f] = fields[f];
  return getJSON(FORECAST + '?' + query(params));
}

// --- shaping -----------------------------------------------------------------------

var CURRENT = 'temperature_2m,apparent_temperature,relative_humidity_2m,is_day,precipitation,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m';
var HOURLY = 'temperature_2m,precipitation_probability,weather_code,wind_speed_10m,is_day';
var DAILY = 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,uv_index_max,sunrise,sunset';

function shapeCurrent(data, u) {
  var c = data.current || {};
  var cond = condition(c.weather_code, c.is_day);
  var t = u.labels.temperature;
  return {
    time: c.time,
    temperature: one(c.temperature_2m),
    temperature_text: round(c.temperature_2m) + '°',
    feels_like: one(c.apparent_temperature),
    feels_like_text: 'Feels like ' + round(c.apparent_temperature) + t,
    condition: cond.text,
    emoji: cond.emoji,
    is_day: c.is_day === 1,
    humidity: c.relative_humidity_2m,
    humidity_text: c.relative_humidity_2m + '%',
    cloud_cover: c.cloud_cover,
    cloud_cover_text: c.cloud_cover + '%',
    pressure: round(c.pressure_msl),
    pressure_text: round(c.pressure_msl) + ' ' + u.labels.pressure,
    precipitation: one(c.precipitation),
    precipitation_text: one(c.precipitation) + ' ' + u.labels.precipitation,
    wind_speed: round(c.wind_speed_10m),
    wind_direction: compass(c.wind_direction_10m),
    wind_text: round(c.wind_speed_10m) + ' ' + u.labels.wind + ' ' + compass(c.wind_direction_10m),
    gusts_text: 'Gusts ' + round(c.wind_gusts_10m) + ' ' + u.labels.wind,
  };
}

function shapeDays(data, u, limit) {
  var d = data.daily || {};
  var out = [];
  var n = Math.min((d.time || []).length, limit || 16);
  for (var i = 0; i < n; i++) {
    var cond = condition(d.weather_code[i], 1);
    out.push({
      date: d.time[i],
      label: dayLabel(d.time[i], i),
      condition: cond.text,
      emoji: cond.emoji,
      high: round(d.temperature_2m_max[i]),
      low: round(d.temperature_2m_min[i]),
      range_text: round(d.temperature_2m_max[i]) + '° / ' + round(d.temperature_2m_min[i]) + '°',
      precipitation: one(d.precipitation_sum[i]),
      precipitation_chance: d.precipitation_probability_max[i],
      precipitation_text: (d.precipitation_probability_max[i] || 0) + '% · ' + one(d.precipitation_sum[i]) + ' ' + u.labels.precipitation,
      wind_max_text: round(d.wind_speed_10m_max[i]) + ' ' + u.labels.wind,
      uv_index: one(d.uv_index_max[i]),
      sunrise: clock(d.sunrise[i]),
      sunset: clock(d.sunset[i]),
    });
  }
  return out;
}

function shapeHours(data, u, from, limit) {
  var h = data.hourly || {};
  var times = h.time || [];
  // The first hour at or after the place's current time.
  var start = 0;
  while (start < times.length && from && times[start] < from.slice(0, 13) + ':00') start++;
  var out = [];
  for (var i = start; i < times.length && out.length < limit; i++) {
    var cond = condition(h.weather_code[i], h.is_day[i]);
    out.push({
      time: times[i],
      label: out.length === 0 ? 'Now' : clock(times[i]),
      temperature: round(h.temperature_2m[i]),
      temperature_text: round(h.temperature_2m[i]) + '°',
      condition: cond.text,
      emoji: cond.emoji,
      precipitation_chance: h.precipitation_probability[i],
      precipitation_chance_text: (h.precipitation_probability[i] || 0) + '%',
      wind_text: round(h.wind_speed_10m[i]) + ' ' + u.labels.wind,
    });
  }
  return out;
}

// --- microtools -----------------------------------------------------------------------

function weather_report(args) {
  var u = units(args);
  var where = place(args);
  var data = forecast(where, u, { current: CURRENT, hourly: HOURLY, daily: DAILY, forecast_days: 7 });
  var current = shapeCurrent(data, u);
  var days = shapeDays(data, u, 7);
  var today = days[0] || null;
  return {
    place: where,
    units: u.system,
    unit_labels: u.labels,
    current: current,
    today: today,
    hours: shapeHours(data, u, current.time, 12),
    days: days,
    summary: current.emoji + ' ' + current.condition + ', ' + current.temperature_text + ' in ' + where.name +
      (today ? ' — high ' + today.high + '°, low ' + today.low + '°, ' + (today.precipitation_chance || 0) + '% chance of precipitation.' : '.'),
    timezone: data.timezone,
    updated: current.time,
    source: 'Open-Meteo',
  };
}

function current_weather(args) {
  var u = units(args);
  var where = place(args);
  var data = forecast(where, u, { current: CURRENT });
  return { place: where, units: u.system, unit_labels: u.labels, current: shapeCurrent(data, u) };
}

function daily_forecast(args) {
  var u = units(args);
  var where = place(args);
  var days = Math.max(1, Math.min(16, Math.round((args && args.days) || 7)));
  var data = forecast(where, u, { daily: DAILY, forecast_days: days });
  return { place: where, units: u.system, unit_labels: u.labels, days: shapeDays(data, u, days) };
}

function hourly_forecast(args) {
  var u = units(args);
  var where = place(args);
  var hours = Math.max(1, Math.min(72, Math.round((args && args.hours) || 24)));
  var data = forecast(where, u, { current: 'temperature_2m', hourly: HOURLY, forecast_days: Math.ceil(hours / 24) + 1 });
  return { place: where, units: u.system, unit_labels: u.labels, hours: shapeHours(data, u, data.current && data.current.time, hours) };
}

function search_places(args) {
  var q = String((args && args.query) || '').trim();
  if (!q) throw new Error('Say which place to search for.');
  return { query: q, places: searchPlaces(q, 8) };
}
