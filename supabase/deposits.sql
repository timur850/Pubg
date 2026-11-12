-- =====================================================================
--  METRO DROP — пополнения через CryptoBot (запускать после schema.sql)
-- =====================================================================
create table if not exists public.deposits(
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  coins      numeric(14,2) not null check (coins > 0),
  usd        numeric(14,2) not null check (usd > 0),
  invoice_id bigint unique,
  status     text not null default 'pending' check (status in ('pending','paid','expired')),
  asset      text,
  created_at timestamptz not null default now(),
  paid_at    timestamptz
);
create index if not exists deposits_user on public.deposits(user_id, created_at desc);
alter table public.deposits enable row level security;
drop policy if exists "own" on public.deposits;
create policy "own" on public.deposits for select using (user_id = auth.uid() or public.is_admin());
grant select on public.deposits to authenticated;

insert into public.settings(key, value, note) values
 ('pay_on',        '0',        'Автопополнение через CryptoBot: 1 — вкл, 0 — выкл'),
 ('coins_per_usd', '100',      'Сколько монет за 1 $'),
 ('pay_min',       '100',      'Минимальное пополнение, монет'),
 ('pay_max',       '100000',   'Максимальное пополнение, монет'),
 ('pay_assets',    'USDT,TON', 'Чем можно платить (через запятую): USDT, TON, BTC, ETH, LTC, BNB, TRX, USDC'),
 ('pay_testnet',   '0',        'Тестовая сеть CryptoBot (@CryptoTestnetBot): 1 — да, 0 — нет')
on conflict (key) do nothing;

-- зачислить оплаченный счёт (вызывает только сервер, игрок — не может)
create or replace function public.credit_deposit(p_id bigint, p_asset text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d deposits; b numeric;
begin
  update deposits set status = 'paid', paid_at = now(), asset = coalesce(p_asset, asset)
   where id = p_id and status = 'pending' returning * into d;
  if not found then return jsonb_build_object('credited', 0); end if;
  b := _money(d.user_id, d.coins, 'deposit');
  return jsonb_build_object('credited', d.coins, 'balance', b, 'user_id', d.user_id);
end $$;
revoke execute on function public.credit_deposit(bigint, text) from public, anon, authenticated;
grant execute on function public.credit_deposit(bigint, text) to service_role;

-- статистика с пополнениями
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
    'usd_today',     (select coalesce(sum(usd), 0) from deposits where status = 'paid' and paid_at > now() - interval '24 hours'),
    'usd_total',     (select coalesce(sum(usd), 0) from deposits where status = 'paid'),
    'today', (select coalesce(jsonb_object_agg(r, s), '{}') from (
               select split_part(reason, ':', 1) r, sum(delta) s from ledger
                where created_at > now() - interval '24 hours' group by 1) t),
    'all',   (select coalesce(jsonb_object_agg(r, s), '{}') from (
               select split_part(reason, ':', 1) r, sum(delta) s from ledger group by 1) t)
  );
end $$;
revoke execute on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;

-- второй способ оплаты: NOWPayments
alter table public.deposits add column if not exists provider text not null default 'cryptobot';
alter table public.deposits add column if not exists ext_id text;
create index if not exists deposits_ext on public.deposits(provider, ext_id);
insert into public.settings(key, value, note) values
 ('np_on', '0', 'Пополнение через NOWPayments (все криптовалюты, страница оплаты): 1 — вкл, 0 — выкл')
on conflict (key) do nothing;
