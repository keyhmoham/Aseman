# امپراتوری راه‌آهن پارس — Persian Rails Empire

[`../persian-rails-empire.json`](../persian-rails-empire.json) یک workflow کامل آسمان است که سازمان، پلتفرم، کلید سرور، پروژه، عامل مهماندار فارسی، سرور پایتون، فرانت Elpian و بازی رسمی گودو ۴.۳ (نقشه شماتیک ایران، ۲.۵‌بعدی، مدل‌های CC0 کنی) را بالا می‌آورد.

## چه چیزی ساخته می‌شود

| مرحله | خروجی |
| --- | --- |
| `org`, `team`, `platform` | سازمان و پلتفرم بازیکنان |
| `server_key`, `server_secrets` | کلید توسعه‌دهنده سرور |
| `space`, `team_room`, `steward` | پروژه و مهماندار گرم فارسی |
| `app_files` | سرور + میزبان نازک Scene3D + تست‌ها |
| `games` | شِل گودو (۵ تب)، دانلود مدل Kenney، تست headless، pack و Web |
| `install` … `frontend` | سرویس زنده، انتشار فرانت گودو و اپ اندروید |

## نصب

```bash
docs/workflows/persian-rails-empire/deploy.sh \
  --server http://localhost:8080 \
  --dev-api http://aseman:8080/dev/v1 \
  --public http://localhost:8080 \
  --yes
```

ورودی‌های مهم: `product`, `slug=persian-rails-empire`, `web_builds`, `publish_frontend`, `android_app`, `godot_in_app`.

## بازی گودو

پوشه `games/persian-rails` یک پروژه Godot 4.3 است:

- حلقه نوبت: کارت بردار / مسیر بساز / قرارداد مقصد بگیر
- نقشه ~۳۳ شهر و ~۵۰ مسیر ایران با برچسب سناریویی
- حریف هوشمند قاعده‌محور (۳ سطح)
- رابط فارسی گرم (شِل گودو با ۵ تب خانه/بازی/اطلس/افتخار/قوانین؛ همان بافت HUD)
- مدل‌های قطار Kenney (CC0) از اینترنت در زمان بیلد
- قرارداد Arena روی شِل: `arena_start` / `arena_event` / pack برای Scene3D

## توسعه محلی

```bash
cd docs/workflows/persian-rails-empire
python3 app/test_app.py
python3 app/tools/rails_forge.py check --dir games/persian-rails
games/build.sh persian-rails --offline   # بدون دانلود مدل
cd app && GAMES_DIR=../games/build python3 server.py
```

بعد از هر تغییر: `python3 bundle.py`.
