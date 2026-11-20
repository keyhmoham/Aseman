"""Dates in the words people use → an ISO date a tool accepts.

Understands today / tomorrow / the day after (Persian and English), weekday
names ('Thursday', 'پنجشنبه', optionally 'next'), ISO dates, and Jalali dates
(1405/09/05, ۱۴۰۵-۹-۵). Anything else is None, and the caller treats the date
as missing rather than guessing.
"""
from __future__ import annotations

import datetime as dt
import re

from .frame import normalize_text

_WEEKDAYS = {  # Monday=0 … Sunday=6
    "دوشنبه": 0, "monday": 0, "mon": 0,
    "سه‌شنبه": 1, "سه شنبه": 1, "سهشنبه": 1, "tuesday": 1, "tue": 1,
    "چهارشنبه": 2, "wednesday": 2, "wed": 2,
    "پنجشنبه": 3, "پنج‌شنبه": 3, "پنج شنبه": 3, "thursday": 3, "thu": 3,
    "جمعه": 4, "friday": 4, "fri": 4,
    "شنبه": 5, "saturday": 5, "sat": 5,
    "یکشنبه": 6, "یک‌شنبه": 6, "یک شنبه": 6, "sunday": 6, "sun": 6,
}


def jalali_to_gregorian(jy: int, jm: int, jd: int) -> dt.date:
    jy += 1595
    days = -355668 + 365 * jy + (jy // 33) * 8 + ((jy % 33) + 3) // 4 + jd
    days += (jm - 1) * 31 if jm < 7 else ((jm - 7) * 30 + 186)
    gy = 400 * (days // 146097)
    days %= 146097
    if days > 36524:
        days -= 1
        gy += 100 * (days // 36524)
        days %= 36524
        if days >= 365:
            days += 1
    gy += 4 * (days // 1461)
    days %= 1461
    if days > 365:
        gy += (days - 1) // 365
        days = (days - 1) % 365
    gd = days + 1
    month_days = [0, 31, 29 if (gy % 4 == 0 and gy % 100 != 0) or gy % 400 == 0 else 28,
                  31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    gm = 0
    while gm < 13 and gd > month_days[gm]:
        gd -= month_days[gm]
        gm += 1
    return dt.date(gy, gm, gd)


def resolve_date(text: str | None, today: dt.date | None = None) -> str | None:
    if not text:
        return None
    today = today or dt.date.today()
    t = normalize_text(text).lower()

    m = re.search(r"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})", t)
    if m:
        y, mo, d = (int(x) for x in m.groups())
        try:
            if y >= 1700:
                return dt.date(y, mo, d).isoformat()
            return jalali_to_gregorian(y, mo, d).isoformat()
        except ValueError:
            return None

    if re.search(r"پس[\s\u200c]*فردا|day after tomorrow", t):
        return (today + dt.timedelta(days=2)).isoformat()
    if re.search(r"فردا|tomorrow", t):
        return (today + dt.timedelta(days=1)).isoformat()
    if re.search(r"امروز|today|tonight", t):
        return today.isoformat()

    for name, idx in sorted(_WEEKDAYS.items(), key=lambda kv: -len(kv[0])):
        if re.search(rf"(?<![\w]){re.escape(name)}(?![\w])", t):
            ahead = (idx - today.weekday()) % 7
            if re.search(r"آینده|بعد|next", t):
                ahead = ahead or 7
            return (today + dt.timedelta(days=ahead)).isoformat()
    return None
