-- =====================================================================
--  METRO DROP — база данных Supabase
--  Как применить: Supabase → SQL Editor → New query → вставить весь файл → Run.
--  Файл можно запускать повторно: стартовые кейсы/предметы добавятся, только если их ещё нет.
-- =====================================================================

-- ---------- ТАБЛИЦЫ ----------
create table if not exists public.settings(
  key   text primary key,
  value text not null default '',
  note  text
);

create table if not exists public.items(
  id       text primary key,
  name     text not null,
  type     text not null default 'gold',          -- иконка-заглушка: rifle smg sniper vest helmet bag key card gold gpu uc
  rarity   int  not null default 1 check (rarity between 1 and 5),
  price    numeric(14,2) not null default 0 check (price >= 0),
  img      text,                                  -- ссылка на фото (загружается из админки)
  withdrawable boolean not null default false,    -- можно ли вывести (например UC)
  active   boolean not null default true,
  sort     int not null default 0
);

create table if not exists public.cases(
  id     text primary key,
  name   text not null,
  price  numeric(14,2) not null default 0 check (price >= 0),   -- 0 = бесплатный кейс с таймером
  col    text not null default '#ffbf2e',
  img    text,
  tag    text not null default '',
  sort   int  not null default 0,
  active boolean not null default true
);

create table if not exists public.case_items(
  case_id text references public.cases(id) on delete cascade on update cascade,
  item_id text references public.items(id) on delete cascade on update cascade,
  weight  numeric not null check (weight > 0),
  primary key (case_id, item_id)
);

create table if not exists public.profiles(
  id         uuid primary key references auth.users(id) on delete cascade,
  num        bigserial unique,                     -- короткий номер игрока (#123)
  nickname   text,
  pubg_id    text,
  balance    numeric(14,2) not null default 0,
  opened     int not null default 0,
  last_free  timestamptz,
  is_admin   boolean not null default false,
  banned     boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.inventory(
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  item_id    text not null references public.items(id) on update cascade,
  status     text not null default 'own' check (status in ('own','sold','withdraw','done','burned')),
  source     text,
  created_at timestamptz not null default now()
);
create index if not exists inventory_user_own on public.inventory(user_id) where status = 'own';

create table if not exists public.withdrawals(
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  inv_id     bigint not null references public.inventory(id) on delete cascade,
  item_id    text not null references public.items(id) on update cascade,
  pubg_id    text not null,
  status     text not null default 'pending' check (status in ('pending','done','rejected')),
  note       text,
  created_at timestamptz not null default now(),
  done_at    timestamptz
);

create table if not exists public.drops(               -- лента дропов
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete cascade,
  item_id    text not null references public.items(id) on delete cascade on update cascade,
  source     text,
  created_at timestamptz not null default now()
);
create index if not exists drops_time on public.drops(created_at desc);

create table if not exists public.ledger(              -- все движения монет (для статистики)
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete cascade,
  delta      numeric(14,2) not null,
  reason     text not null,
  created_at timestamptz not null default now()
);
create index if not exists ledger_time on public.ledger(created_at desc);

create table if not exists public.mines_games(         -- игрокам НЕ видна (там расположение мин)
  user_id uuid primary key references public.profiles(id) on delete cascade,
  bet     numeric(14,2) not null,
  size    int not null,
  bombs   int[] not null,
  opened  int[] not null default '{}',
  active  boolean not null default true
);

-- ---------- НАСТРОЙКИ ПО УМОЛЧАНИЮ ----------
insert into public.settings(key, value, note) values
 ('start_balance', '500',  'Монет новому игроку'),
 ('free_hours',    '24',   'Таймер бесплатного кейса, часов'),
 ('topup_text',    'Чтобы пополнить баланс, напиши админу и назови свой номер игрока.', 'Текст при нажатии «Пополнить»'),
 ('topup_link',    '',     'Ссылка на админа, например https://t.me/username'),
 ('notice',        '',     'Строка под кейсами (пусто — не показывать)'),
 ('upgrade_edge',  '0.95', 'Апгрейд: шанс = цена_своего / цена_цели × это число'),
 ('upgrade_max',   '0.8',  'Апгрейд: максимальный шанс'),
 ('mines_edge',    '0.97', 'Сапёр: множитель × это число'),
 ('games_on',      '1',    'Игры (сапёр/плинко/колесо/апгрейд): 1 — вкл, 0 — выкл')
on conflict (key) do nothing;

-- ---------- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (игрокам недоступны) ----------
create or replace function public._set(k text) returns text
language sql stable security definer set search_path = public as
$$ select value from settings where key = k $$;

create or replace function public._num(k text, def numeric) returns numeric
language plpgsql stable security definer set search_path = public as
$$ begin return coalesce(nullif(trim(_set(k)), '')::numeric, def);
   exception when others then return def; end $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select is_admin from profiles where id = auth.uid()), false) $$;

create or replace function public._player() returns public.profiles
language plpgsql security definer set search_path = public as $$
declare p profiles;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found then raise exception 'Нет профиля, перезагрузи страницу'; end if;
  if p.banned then raise exception 'Аккаунт заблокирован'; end if;
  return p;
end $$;

create or replace function public._money(uid uuid, d numeric, why text) returns numeric
language plpgsql security definer set search_path = public as $$
declare b numeric;
begin
  update profiles set balance = balance + d where id = uid returning balance into b;
  if d <> 0 then insert into ledger(user_id, delta, reason) values (uid, d, why); end if;
  return b;
end $$;

create or replace function public._bet(p profiles, bet numeric, why text) returns numeric
language plpgsql security definer set search_path = public as $$
begin
  if bet is null or bet <= 0 then raise exception 'Неверная ставка'; end if;
  if bet <> round(bet, 2) then raise exception 'Неверная ставка'; end if;
  if p.balance < bet then raise exception 'Недостаточно монет'; end if;
  if _num('games_on', 1) = 0 then raise exception 'Игры временно выключены'; end if;
  return _money(p.id, -bet, why);
end $$;

create or replace function public._roll(c text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare tot numeric; r numeric; rec record;
begin
  select sum(ci.weight) into tot from case_items ci join items i on i.id = ci.item_id
   where ci.case_id = c and i.active;
  if tot is null then return null; end if;
  r := random() * tot;
  for rec in select ci.item_id, ci.weight from case_items ci join items i on i.id = ci.item_id
             where ci.case_id = c and i.active order by ci.item_id loop
    r := r - rec.weight;
    if r < 0 then return rec.item_id; end if;
  end loop;
  return rec.item_id;
end $$;

create or replace function public._mines_mult(n int, b int, k int) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare m numeric := 1; i int;
begin
  if k = 0 then return 1; end if;
  for i in 0..k-1 loop m := m * (n - i)::numeric / (n - b - i); end loop;
  return round(m * _num('mines_edge', 0.97), 4);
end $$;

-- новый пользователь → профиль со стартовым балансом
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles(id, balance) values (new.id, _num('start_balance', 0)) on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- ИГРОВЫЕ ФУНКЦИИ ----------
create or replace function public.me() returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles;
begin
  select * into p from profiles where id = auth.uid();
  if not found then
    insert into profiles(id, balance) values (auth.uid(), _num('start_balance', 0)) returning * into p;
  end if;
  return jsonb_build_object('num', p.num, 'balance', p.balance, 'opened', p.opened, 'last_free', p.last_free,
    'pubg_id', p.pubg_id, 'banned', p.banned, 'is_admin', p.is_admin,
    'mines', (select jsonb_build_object('bet', bet, 'size', size, 'bombs', cardinality(bombs), 'opened', opened)
              from mines_games where user_id = p.id and active));
end $$;

create or replace function public.open_case(p_case text, p_count int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; c cases; it text; inv bigint; res jsonb := '[]'; b numeric; i int;
begin
  p := _player();
  select * into c from cases where id = p_case and active;
  if not found then raise exception 'Кейс не найден'; end if;
  if p_count is null or p_count < 1 or p_count > 5 then raise exception 'Можно открыть от 1 до 5'; end if;
  if c.price = 0 then
    p_count := 1;
    if p.last_free is not null and p.last_free + make_interval(secs => _num('free_hours', 24) * 3600) > now() then
      raise exception 'Бесплатный кейс ещё недоступен';
    end if;
    update profiles set last_free = now() where id = p.id;
  else
    if p.balance < c.price * p_count then raise exception 'Недостаточно монет'; end if;
    perform _money(p.id, -c.price * p_count, 'case:' || c.id);
  end if;
  for i in 1..p_count loop
    it := _roll(c.id);
    if it is null then raise exception 'Кейс пустой'; end if;
    insert into inventory(user_id, item_id, source) values (p.id, it, 'case:' || c.id) returning id into inv;
    insert into drops(user_id, item_id, source) values (p.id, it, 'case');
    res := res || jsonb_build_object('inv', inv, 'item', it);
  end loop;
  update profiles set opened = opened + p_count where id = p.id returning balance into b;
  return jsonb_build_object('items', res, 'balance', b);
end $$;

create or replace function public.sell_items(p_ids bigint[] default null) returns numeric
language plpgsql security definer set search_path = public as $$
declare p profiles; total numeric;
begin
  p := _player();
  with s as (
    update inventory set status = 'sold'
     where user_id = p.id and status = 'own' and (p_ids is null or id = any(p_ids))
    returning item_id)
  select coalesce(sum(i.price), 0) into total from s join items i on i.id = s.item_id;
  return _money(p.id, total, 'sell');
end $$;

create or replace function public.withdraw_item(p_inv bigint, p_pubg text) returns void
language plpgsql security definer set search_path = public as $$
declare p profiles; it text;
begin
  p := _player();
  p_pubg := trim(coalesce(p_pubg, ''));
  if p_pubg !~ '^[0-9]{5,15}$' then raise exception 'Введи правильный ID PUBG (только цифры)'; end if;
  select v.item_id into it from inventory v join items i on i.id = v.item_id
   where v.id = p_inv and v.user_id = p.id and v.status = 'own' and i.withdrawable;
  if it is null then raise exception 'Этот предмет нельзя вывести'; end if;
  update inventory set status = 'withdraw' where id = p_inv;
  update profiles set pubg_id = p_pubg where id = p.id;
  insert into withdrawals(user_id, inv_id, item_id, pubg_id) values (p.id, p_inv, it, p_pubg);
end $$;

create or replace function public.upgrade_item(p_inv bigint, p_target text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; fp numeric; tp numeric; ch numeric; win boolean; inv bigint;
begin
  p := _player();
  if _num('games_on', 1) = 0 then raise exception 'Игры временно выключены'; end if;
  select i.price into fp from inventory v join items i on i.id = v.item_id
   where v.id = p_inv and v.user_id = p.id and v.status = 'own';
  if fp is null then raise exception 'Предмет не найден'; end if;
  select price into tp from items where id = p_target and active;
  if tp is null or tp <= fp then raise exception 'Цель должна быть дороже'; end if;
  ch := least(_num('upgrade_max', 0.8), fp / tp * _num('upgrade_edge', 0.95));
  win := random() < ch;
  update inventory set status = 'burned' where id = p_inv;
  if win then
    insert into inventory(user_id, item_id, source) values (p.id, p_target, 'upgrade') returning id into inv;
    insert into drops(user_id, item_id, source) values (p.id, p_target, 'upgrade');
  end if;
  return jsonb_build_object('win', win, 'chance', ch, 'inv', inv);
end $$;

create or replace function public.mines_start(p_bet numeric, p_size int, p_bombs int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; b numeric; bs int[];
begin
  p := _player();
  if exists (select 1 from mines_games where user_id = p.id and active) then raise exception 'Игра уже идёт'; end if;
  if not ((p_size = 3 and p_bombs in (1,2,3)) or (p_size = 5 and p_bombs in (1,3,5,10,24))
          or (p_size = 7 and p_bombs in (3,5,10,20,48))) then raise exception 'Неверные настройки'; end if;
  b := _bet(p, p_bet, 'mines');
  select array_agg(x) into bs from (select x from generate_series(0, p_size * p_size - 1) x order by random() limit p_bombs) t;
  insert into mines_games(user_id, bet, size, bombs, opened, active) values (p.id, p_bet, p_size, bs, '{}', true)
    on conflict (user_id) do update set bet = excluded.bet, size = excluded.size, bombs = excluded.bombs, opened = '{}', active = true;
  return jsonb_build_object('balance', b);
end $$;

create or replace function public.mines_cashout() returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; g mines_games; w numeric; b numeric;
begin
  p := _player();
  select * into g from mines_games where user_id = p.id and active for update;
  if not found then raise exception 'Нет активной игры'; end if;
  if cardinality(g.opened) = 0 then raise exception 'Открой хотя бы одну клетку'; end if;
  w := round(g.bet * _mines_mult(g.size * g.size, cardinality(g.bombs), cardinality(g.opened)), 2);
  update mines_games set active = false where user_id = p.id;
  b := _money(p.id, w, 'mines');
  return jsonb_build_object('win', w, 'balance', b, 'bombs', to_jsonb(g.bombs));
end $$;

create or replace function public.mines_click(p_cell int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; g mines_games; n int;
begin
  p := _player();
  select * into g from mines_games where user_id = p.id and active for update;
  if not found then raise exception 'Нет активной игры'; end if;
  n := g.size * g.size;
  if p_cell is null or p_cell < 0 or p_cell >= n then raise exception 'Неверная клетка'; end if;
  if p_cell = any(g.opened) then return jsonb_build_object('bomb', false, 'opened', cardinality(g.opened)); end if;
  if p_cell = any(g.bombs) then
    update mines_games set active = false where user_id = p.id;
    return jsonb_build_object('bomb', true, 'bombs', to_jsonb(g.bombs));
  end if;
  update mines_games set opened = opened || p_cell where user_id = p.id returning * into g;
  if cardinality(g.opened) = n - cardinality(g.bombs) then
    return mines_cashout() || jsonb_build_object('bomb', false, 'finished', true, 'opened', cardinality(g.opened));
  end if;
  return jsonb_build_object('bomb', false, 'opened', cardinality(g.opened));
end $$;

create or replace function public.plinko_drop(p_bet numeric, p_diff text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; m numeric[]; path int[] := '{}'; slot int := 0; d int; i int; w numeric; b numeric;
begin
  p := _player();
  m := case p_diff when 'easy' then array[5.6,2.1,1.1,1,0.5,1,1.1,2.1,5.6]
                   when 'mid'  then array[13,3,1.3,0.7,0.4,0.7,1.3,3,13]
                   when 'hard' then array[29,4,1.5,0.3,0.2,0.3,1.5,4,29] end;
  if m is null then raise exception 'Неверная сложность'; end if;
  perform _bet(p, p_bet, 'plinko');
  for i in 1..8 loop d := case when random() < 0.5 then 0 else 1 end; path := path || d; slot := slot + d; end loop;
  w := round(p_bet * m[slot + 1], 2);
  b := _money(p.id, w, 'plinko');
  return jsonb_build_object('path', to_jsonb(path), 'slot', slot, 'mult', m[slot + 1], 'win', w, 'balance', b);
end $$;

create or replace function public.wheel_spin(p_bet numeric, p_pick int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; r numeric; res int; mult int[] := array[2,3,5,50]; w numeric := 0; b numeric;
begin
  p := _player();
  if p_pick is null or p_pick < 0 or p_pick > 3 then raise exception 'Выбери цвет'; end if;
  perform _bet(p, p_bet, 'wheel');
  r := random() * 51;   -- секторов: 24×2x, 16×3x, 10×5x, 1×50x
  res := case when r < 24 then 0 when r < 40 then 1 when r < 50 then 2 else 3 end;
  if res = p_pick then w := p_bet * mult[res + 1]; end if;
  b := _money(p.id, w, 'wheel');
  return jsonb_build_object('res', res, 'win', w, 'balance', b);
end $$;

-- ---------- АДМИН-ФУНКЦИИ ----------
create or replace function public._need_admin() returns void
language plpgsql stable security definer set search_path = public as
$$ begin if not is_admin() then raise exception 'Нет доступа'; end if; end $$;

create or replace function public.admin_money(p_user uuid, p_delta numeric) returns numeric
language plpgsql security definer set search_path = public as $$
begin perform _need_admin(); return _money(p_user, p_delta, 'admin'); end $$;

create or replace function public.admin_ban(p_user uuid, p_ban boolean) returns void
language plpgsql security definer set search_path = public as $$
begin perform _need_admin(); update profiles set banned = p_ban where id = p_user; end $$;

create or replace function public.admin_give(p_user uuid, p_item text) returns void
language plpgsql security definer set search_path = public as $$
begin perform _need_admin(); insert into inventory(user_id, item_id, source) values (p_user, p_item, 'admin'); end $$;

create or replace function public.admin_withdrawal(p_id bigint, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare w withdrawals;
begin
  perform _need_admin();
  if p_status not in ('done','rejected') then raise exception 'Неверный статус'; end if;
  select * into w from withdrawals where id = p_id and status = 'pending' for update;
  if not found then raise exception 'Заявка уже обработана'; end if;
  update withdrawals set status = p_status, note = p_note, done_at = now() where id = p_id;
  update inventory set status = case when p_status = 'done' then 'done' else 'own' end where id = w.inv_id;
end $$;

create or replace function public.admin_stats() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return jsonb_build_object(
    'players',       (select count(*) from profiles),
    'players_today', (select count(*) from profiles where created_at > now() - interval '24 hours'),
    'opens_today',   (select count(*) from drops where source = 'case' and created_at > now() - interval '24 hours'),
    'opens_total',   (select count(*) from drops where source = 'case'),
    'balances',      (select coalesce(sum(balance), 0) from profiles),
    'pending',       (select count(*) from withdrawals where status = 'pending'),
    'today', (select coalesce(jsonb_object_agg(r, s), '{}') from (
               select split_part(reason, ':', 1) r, sum(delta) s from ledger
                where created_at > now() - interval '24 hours' group by 1) t),
    'all',   (select coalesce(jsonb_object_agg(r, s), '{}') from (
               select split_part(reason, ':', 1) r, sum(delta) s from ledger group by 1) t)
  );
end $$;

-- ---------- ДОСТУП (RLS) ----------
alter table public.settings    enable row level security;
alter table public.items       enable row level security;
alter table public.cases       enable row level security;
alter table public.case_items  enable row level security;
alter table public.profiles    enable row level security;
alter table public.inventory   enable row level security;
alter table public.withdrawals enable row level security;
alter table public.drops       enable row level security;
alter table public.ledger      enable row level security;
alter table public.mines_games enable row level security;

do $$
declare t text;
begin
  -- каталог: читают все, меняет только админ
  foreach t in array array['settings','items','cases','case_items'] loop
    execute format('drop policy if exists "read" on public.%I', t);
    execute format('drop policy if exists "admin" on public.%I', t);
    execute format('create policy "read" on public.%I for select using (true)', t);
    execute format('create policy "admin" on public.%I for all using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
  -- личное: игрок видит своё, админ — всё
  foreach t in array array['inventory','withdrawals'] loop
    execute format('drop policy if exists "own" on public.%I', t);
    execute format('create policy "own" on public.%I for select using (user_id = auth.uid() or public.is_admin())', t);
  end loop;
end $$;

drop policy if exists "own" on public.profiles;
create policy "own" on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists "admin" on public.profiles;
create policy "admin" on public.profiles for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists "read" on public.drops;
create policy "read" on public.drops for select using (true);
drop policy if exists "admin" on public.ledger;
create policy "admin" on public.ledger for select using (public.is_admin());
-- mines_games: политик нет → никто, кроме функций, не видит мины

-- внутренние функции нельзя вызывать с сайта
revoke execute on function public._set(text), public._num(text, numeric), public._player(), public._money(uuid, numeric, text),
  public._bet(public.profiles, numeric, text), public._roll(text), public._mines_mult(int, int, int), public._need_admin(),
  public.handle_new_user() from public, anon, authenticated;

-- ---------- ХРАНИЛИЩЕ КАРТИНОК ----------
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets(id, name, public) values ('img', 'img', true) on conflict (id) do nothing;
    drop policy if exists "img admin insert" on storage.objects;
    drop policy if exists "img admin update" on storage.objects;
    drop policy if exists "img admin delete" on storage.objects;
    create policy "img admin insert" on storage.objects for insert to authenticated with check (bucket_id = 'img' and public.is_admin());
    create policy "img admin update" on storage.objects for update to authenticated using (bucket_id = 'img' and public.is_admin());
    create policy "img admin delete" on storage.objects for delete to authenticated using (bucket_id = 'img' and public.is_admin());
  end if;
end $$;

-- ---------- СТАРТОВЫЕ ПРЕДМЕТЫ И КЕЙСЫ ----------
insert into public.items(id, name, type, rarity, price, withdrawable, sort) values
 ('scrap','Металлолом','gold',1,5,false,1), ('tape','Изолента','card',1,8,false,2), ('pills','Аптечка','bag',1,12,false,3),
 ('vest3','Бронежилет ур.3','vest',1,15,false,4), ('helm3','Шлем ур.3','helmet',1,14,false,5),
 ('m416','M416 (Металл)','rifle',2,35,false,6), ('akm','AKM (Металл)','rifle',2,32,false,7), ('ump','UMP45 (Улучш.)','smg',2,28,false,8),
 ('bag4','Рюкзак ур.4','bag',2,40,false,9),
 ('vest4','Бронежилет ур.4','vest',3,85,false,10), ('helm4','Шлем ур.4','helmet',3,80,false,11), ('vector','Vector (Сталь)','smg',3,95,false,12),
 ('key','Ключ «Лаборатория»','key',3,110,false,13),
 ('mk14','Mk14 (Сталь)','sniper',4,260,false,14), ('vest5','Бронежилет ур.5','vest',4,240,false,15), ('gpu','Видеокарта','gpu',4,300,false,16),
 ('card','Карта доступа','card',4,220,false,17),
 ('groza','Groza (Кобальт)','rifle',5,780,false,18), ('awm','AWM (Кобальт)','sniper',5,950,false,19), ('vest6','Бронежилет ур.6','vest',5,700,false,20),
 ('gold','Золотой слиток','gold',5,650,false,21),
 ('uc60','60 UC','uc',2,60,true,22), ('uc325','325 UC','uc',4,320,true,23), ('uc660','660 UC','uc',5,1200,true,24)
on conflict (id) do nothing;

insert into public.cases(id, name, price, col, img, tag, sort) values
 ('free','Бесплатный 24ч',0,'#ffbf2e','img/free.jpg','FREE',1),
 ('supply','Снабжение',29,'#3ddc84','img/supply.jpg','',2),
 ('armor','Броня',89,'#8d5cff','img/armor.jpg','ХИТ',3),
 ('weapon','Арсенал',159,'#ff4a4a','img/weapon.jpg','',4),
 ('elite','Элитный',349,'#ff4fd8','img/elite.jpg','TOP',5),
 ('uc','UC кейс',199,'#3d7bff','img/uc.jpg','UC',6)
on conflict (id) do nothing;

insert into public.case_items(case_id, item_id, weight) values
 ('free','scrap',34),('free','tape',26),('free','pills',18),('free','helm3',10),('free','vest3',8),('free','ump',3),('free','uc60',1),
 ('supply','scrap',22),('supply','tape',22),('supply','pills',22),('supply','vest3',12),('supply','helm3',10),('supply','bag4',7),('supply','uc60',3),('supply','key',1.5),('supply','gpu',0.5),
 ('armor','vest3',22),('armor','helm3',20),('armor','bag4',18),('armor','helm4',14),('armor','vest4',13),('armor','vest5',8),('armor','uc60',3),('armor','vest6',2),
 ('weapon','ump',22),('weapon','akm',20),('weapon','m416',18),('weapon','vector',16),('weapon','mk14',12),('weapon','uc60',6),('weapon','groza',4),('weapon','awm',2),
 ('elite','vector',20),('elite','key',18),('elite','card',16),('elite','gpu',14),('elite','vest5',12),('elite','mk14',10),('elite','gold',5),('elite','vest6',3),('elite','awm',2),
 ('uc','scrap',26),('uc','pills',22),('uc','uc60',26),('uc','vest4',12),('uc','key',7),('uc','uc325',6),('uc','uc660',1)
on conflict do nothing;

-- ---------- СДЕЛАТЬ СЕБЯ АДМИНОМ ----------
-- 1) Supabase → Authentication → Users → Add user → Create new user (почта + пароль, галочка Auto Confirm)
-- 2) Впиши свою почту ниже и выполни ТОЛЬКО эту строку:
-- update public.profiles set is_admin = true where id = (select id from auth.users where email = 'ТВОЯ@ПОЧТА');
