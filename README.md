# METRO DROP

Демо-сайт кейсов в тематике Metro Royale: открытие кейсов, инвентарь, колесо. Вся графика оригинальная (SVG), монеты виртуальные.


## Фото предметов

Положи картинки в папку `img/items/` (PNG, лучше с прозрачным фоном, ~256×256). Имя файла = id предмета. Если файла нет — показывается SVG-иконка.

- `scrap.png` — Металлолом
- `vest3.png` — Бронежилет ур.3
- `m416.png` — M416 (Металл)
- `vest4.png` — Бронежилет ур.4
- `mk14.png` — Mk14 (Сталь)
- `groza.png` — Groza (Кобальт)
- `uc60.png` — 60 UC
- `tape.png` — Изолента
- `pills.png` — Аптечка
- `helm3.png` — Шлем ур.3
- `akm.png` — AKM (Металл)
- `ump.png` — UMP45 (Улучш.)
- `bag4.png` — Рюкзак ур.4
- `helm4.png` — Шлем ур.4
- `vector.png` — Vector (Сталь)
- `key.png` — Ключ «Лаборатория»
- `vest5.png` — Бронежилет ур.5
- `gpu.png` — Видеокарта
- `card.png` — Карта доступа
- `awm.png` — AWM (Кобальт)
- `vest6.png` — Бронежилет ур.6
- `gold.png` — Золотой слиток
- `uc325.png` — 325 UC
- `uc660.png` — 660 UC

## База данных и админка (Supabase)

Баланс, инвентарь, кейсы и игры работают через Supabase — накрутить монеты из браузера нельзя.
Админка: `admin.html` (например `https://timur850.github.io/Pubg/admin.html`).

### Настройка (один раз)
1. Зарегистрируйся на supabase.com → **New project** (регион — Frankfurt/EU).
2. **SQL Editor → New query** → вставь весь `supabase/schema.sql` → **Run**.
3. **Authentication → Sign In / Providers → Email** → выключи **Confirm email** (игроки регистрируются по почте и паролю без письма).
4. **Authentication → Users → Add user → Create new user**: твоя почта + пароль, галочка **Auto Confirm User**.
5. В SQL Editor выполни (со своей почтой):
   `update public.profiles set is_admin = true where id = (select id from auth.users where email = 'ТВОЯ@ПОЧТА');`
6. **Project Settings → API**: скопируй **Project URL** и ключ **anon public** в `config.js`.

### Что умеет админка
- Статистика: игроки, открытия, доход сайта.
- Кейсы: цена, картинка, предметы и шансы, расчёт % возврата.
- Предметы: цена, редкость, фото (загрузка с телефона), можно ли выводить.
- Игроки: поиск по номеру/ID PUBG, начислить/списать монеты, выдать предмет, бан.
- Выводы: заявки игроков с ID PUBG → «Выдано» / «Отказ» (предмет возвращается).
- Настройки: стартовый баланс, таймер бесплатного кейса, текст пополнения и т.д.
