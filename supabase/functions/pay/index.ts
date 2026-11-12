// METRO DROP — создание счёта на пополнение и проверка оплаты.
// Секреты (Supabase → Edge Functions → Secrets): CRYPTOPAY_TOKEN, NOWPAYMENTS_API_KEY
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (msg: string, status = 400) => json({ error: msg }, status);

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SB_URL, SB_KEY, { auth: { persistSession: false } });

async function settings(): Promise<Record<string, string>> {
  const { data } = await db.from("settings").select("key,value");
  return Object.fromEntries((data || []).map((r: { key: string; value: string }) => [r.key, r.value]));
}

// ---------- CryptoBot ----------
function cbBase(S: Record<string, string>) {
  return S.pay_testnet === "1" ? "https://testnet-pay.crypt.bot/api" : "https://pay.crypt.bot/api";
}
async function cb(S: Record<string, string>, method: string, params: Record<string, unknown>) {
  const token = Deno.env.get("CRYPTOPAY_TOKEN");
  if (!token) throw new Error("CryptoBot ещё не подключён");
  const r = await fetch(`${cbBase(S)}/${method}`, {
    method: "POST",
    headers: { "Crypto-Pay-API-Token": token, "Content-Type": "application/json" },
    body: JSON.stringify(params),
  });
  const j = await r.json();
  if (!j.ok) throw new Error("CryptoBot: " + (j.error?.name || j.error?.code || "ошибка"));
  return j.result;
}

// ---------- NOWPayments ----------
async function np(path: string, body?: unknown) {
  const key = Deno.env.get("NOWPAYMENTS_API_KEY");
  if (!key) throw new Error("NOWPayments ещё не подключён");
  const r = await fetch(`https://api.nowpayments.io/v1/${path}`, {
    method: body ? "POST" : "GET",
    headers: { "x-api-key": key, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json();
  if (!r.ok) throw new Error("NOWPayments: " + (j.message || r.status));
  return j;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: { user } } = await db.auth.getUser(jwt);
    if (!user) return fail("Войди в аккаунт", 401);
    const { data: prof } = await db.from("profiles").select("banned").eq("id", user.id).single();
    if (!prof || prof.banned) return fail("Аккаунт заблокирован", 403);

    const body = await req.json().catch(() => ({}));
    const S = await settings();

    // ----- создать счёт -----
    if (body.action === "create") {
      const provider = body.provider === "nowpayments" ? "nowpayments" : "cryptobot";
      if (provider === "cryptobot" && S.pay_on !== "1") return fail("Этот способ оплаты выключен");
      if (provider === "nowpayments" && S.np_on !== "1") return fail("Этот способ оплаты выключен");
      const rate = Number(S.coins_per_usd) || 100;
      const coins = Math.floor(Number(body.coins));
      const min = Number(S.pay_min) || 100, max = Number(S.pay_max) || 100000;
      if (!(coins >= min && coins <= max)) return fail(`Сумма от ${min} до ${max} монет`);
      const usd = Math.ceil((coins / rate) * 100) / 100;
      if (usd < 0.1) return fail("Слишком маленькая сумма");

      // не больше 10 неоплаченных счетов за час
      const { count } = await db.from("deposits").select("id", { count: "exact", head: true })
        .eq("user_id", user.id).eq("status", "pending").gt("created_at", new Date(Date.now() - 3600e3).toISOString());
      if ((count || 0) >= 10) return fail("Слишком много неоплаченных счетов, подожди немного");

      const { data: dep, error } = await db.from("deposits")
        .insert({ user_id: user.id, coins, usd, provider }).select("id").single();
      if (error) throw error;

      const back = typeof body.return_url === "string" && /^https:\/\//.test(body.return_url) ? body.return_url : undefined;
      let url: string, ext: string;
      if (provider === "cryptobot") {
        const inv = await cb(S, "createInvoice", {
          currency_type: "fiat", fiat: "USD", amount: usd.toFixed(2),
          accepted_assets: (S.pay_assets || "USDT,TON").replace(/\s/g, ""),
          description: `METRO DROP: ${coins} монет`, payload: String(dep.id), expires_in: 3600,
          ...(back ? { paid_btn_name: "callback", paid_btn_url: back } : {}),
        });
        url = inv.bot_invoice_url; ext = String(inv.invoice_id);
        await db.from("deposits").update({ invoice_id: inv.invoice_id, ext_id: ext }).eq("id", dep.id);
      } else {
        const inv = await np("invoice", {
          price_amount: usd, price_currency: "usd", order_id: String(dep.id),
          order_description: `METRO DROP: ${coins} монет`,
          ipn_callback_url: `${SB_URL}/functions/v1/pay-hook`,
          ...(back ? { success_url: back, cancel_url: back } : {}),
        });
        url = inv.invoice_url; ext = String(inv.id);
        await db.from("deposits").update({ ext_id: ext }).eq("id", dep.id);
      }
      return json({ id: dep.id, url, usd, coins });
    }

    // ----- проверить неоплаченные счета CryptoBot (NOWPayments сообщает сам через pay-hook) -----
    if (body.action === "check") {
      const { data: deps } = await db.from("deposits").select("id,invoice_id")
        .eq("user_id", user.id).eq("status", "pending").eq("provider", "cryptobot")
        .not("invoice_id", "is", null).gt("created_at", new Date(Date.now() - 2 * 86400e3).toISOString());
      let credited = 0;
      if (deps && deps.length && Deno.env.get("CRYPTOPAY_TOKEN")) {
        const res = await cb(S, "getInvoices", { invoice_ids: deps.map((d) => d.invoice_id).join(",") });
        for (const inv of res.items || []) {
          const dep = deps.find((d) => String(d.invoice_id) === String(inv.invoice_id));
          if (!dep) continue;
          if (inv.status === "paid") {
            const { data } = await db.rpc("credit_deposit", { p_id: dep.id, p_asset: inv.paid_asset || null });
            credited += Number(data?.credited || 0);
          } else if (inv.status === "expired") {
            await db.from("deposits").update({ status: "expired" }).eq("id", dep.id).eq("status", "pending");
          }
        }
      }
      const { data: p } = await db.from("profiles").select("balance").eq("id", user.id).single();
      return json({ credited, balance: p?.balance });
    }

    return fail("Неизвестное действие");
  } catch (e) {
    console.error(e);
    return fail(e instanceof Error ? e.message : "Ошибка сервера", 500);
  }
});
