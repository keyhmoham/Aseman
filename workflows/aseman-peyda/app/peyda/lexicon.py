"""A small gazetteer and word list: what the lexicon extractor knows, and how
the hybrid extractor double-checks GLiNER2 on the plain cases."""
from __future__ import annotations

import re

# Persian name → English name (search tools accept either; the frame keeps what was written).
CITIES: dict[str, str] = {
    "تهران": "tehran", "مشهد": "mashhad", "اصفهان": "isfahan", "شیراز": "shiraz", "تبریز": "tabriz",
    "کرج": "karaj", "قم": "qom", "اهواز": "ahvaz", "کرمانشاه": "kermanshah", "ارومیه": "urmia",
    "رشت": "rasht", "زاهدان": "zahedan", "کرمان": "kerman", "همدان": "hamedan", "یزد": "yazd",
    "اردبیل": "ardabil", "بندرعباس": "bandar abbas", "اراک": "arak", "زنجان": "zanjan", "سنندج": "sanandaj",
    "قزوین": "qazvin", "خرم‌آباد": "khorramabad", "گرگان": "gorgan", "ساری": "sari", "بوشهر": "bushehr",
    "کیش": "kish", "قشم": "qeshm", "چابهار": "chabahar", "بیرجند": "birjand", "ایلام": "ilam",
    "یاسوج": "yasuj", "سمنان": "semnan", "شهرکرد": "shahrekord", "بجنورد": "bojnord", "ساوه": "saveh",
    "رامسر": "ramsar", "نوشهر": "nowshahr", "شمیران": "shemiran", "سعادت‌آباد": "saadat abad",
    "سعادت آباد": "saadat abad", "ونک": "vanak", "پونک": "punak", "تجریش": "tajrish",
}

def find_cities(low: str) -> list[str]:
    """City names in the order they appear, as typed (a city written twice, or
    in both scripts, counts once)."""
    found: list[tuple[int, str, str]] = []
    for fa, en in CITIES.items():
        for name in (fa, en):
            for m in re.finditer(rf"(?<!\w){re.escape(name)}(?!\w)", low):
                found.append((m.start(), en, name))
    found.sort()
    seen: set[str] = set()
    out: list[str] = []
    for _, canon, name in found:
        if canon not in seen:
            seen.add(canon)
            out.append(name)
    return out


def has_word(low: str, word: str) -> bool:
    """Whether a word starts anywhere in the text (Persian suffixes follow it)."""
    return re.search(rf"(?<!\w){re.escape(word.strip())}", low) is not None


DOMAIN_WORDS: dict[str, tuple[str, ...]] = {
    "shopping": ("گوشی", "لپ تاپ", "لپ‌تاپ", "تلویزیون", "یخچال", "کفش", "لباس", "هدفون", "phone", "laptop", "headphone", "tv ", "قیمت", "خرید", "buy", "price of"),
    "classifieds": ("دست دوم", "کارکرده", "آگهی", "دیوار", "used", "second hand", "classified"),
    "real_estate": ("آپارتمان", "خانه", "اجاره", "رهن", "ویلا", "زمین", "متری", "apartment", "rent a", "for sale", "real estate", "flat"),
    "cars": ("خودرو", "ماشین", "پراید", "پژو", "سمند", "تیبا", "دنا", "car ", "peugeot", "پراید", "بنز"),
    "food": ("پیتزا", "برگر", "کباب", "رستوران", "غذا", "ناهار", "شام", "سوپرمارکت", "pizza", "burger", "restaurant", "food", "kebab", "delivery"),
    "travel_tickets": ("بلیط", "پرواز", "قطار", "اتوبوس", "flight", "ticket", "train", "bus "),
    "stays": ("هتل", "ویلا", "اقامتگاه", "سوئیت", "hotel", "villa", "stay", "nights"),
    "maps": ("آدرس", "مسیر", "نقشه", "نزدیک", "route", "directions", "address", "nearby", "map"),
    "health": ("دکتر", "پزشک", "نوبت", "داروخانه", "دارو", "درمانگاه", "doctor", "clinic", "pharmacy", "appointment", "dermatolog"),
    "books": ("کتاب", "رمان", "کتاب صوتی", "book", "novel", "audiobook"),
    "courses": ("دوره", "آموزش", "کلاس", "course", "learn ", "tutorial"),
    "jobs": ("استخدام", "شغل", "کار", "حقوق", "job", "hiring", "salary", "vacancy"),
    "freelance": ("فریلنس", "پروژه", "freelance", "gig"),
    "software": ("نرم افزار", "نرم‌افزار", "برنامه", "بازی", "اپلیکیشن", "دانلود", "app ", "software", "game", "download"),
    "prices": ("طلا", "سکه", "دلار", "یورو", "بیت کوین", "ارز", "gold", "coin", "dollar", "bitcoin", "currency", "crypto"),
    "stocks": ("بورس", "سهام", "صندوق", "نماد", "کدال", "stock", "bourse", "fund", "shares"),
    "news": ("خبر", "اخبار", "news", "headline"),
    "media": ("فیلم", "سریال", "سینما", "کنسرت", "تئاتر", "آپارات", "film", "movie", "series", "cinema", "concert", "theatre"),
    "weather_time": ("هوا", "آب و هوا", "دما", "تعطیل", "اذان", "تاریخ", "weather", "forecast", "holiday", "prayer"),
    "reference": ("معنی", "معنا", "ویکی", "مترادف", "meaning", "definition", "wikipedia", "synonym"),
    "law": ("قانون", "مالیات", "ماده", "آیین نامه", "law", "tax", "regulation"),
    "sports": ("فوتبال", "لیگ", "بازی امشب", "نتیجه", "football", "league", "score", "match"),
}
