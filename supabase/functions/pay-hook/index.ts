// METRO DROP — уведомления об оплате от CryptoBot и NOWPayments.
// Адрес: https://<project>.supabase.co/functions/v1/pay-hook   (verify_jwt = false, проверка по подписи)
// Секреты: CRYPTOPAY_TOKEN, NOWPAYMENTS_IPN_SECRET
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

async function hmac(algo: "SHA-256" | "SHA-512", key: Uint8Array, msg: string) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: algo }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
}
function same(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function sortDeep(o: any): any {
  if (Array.isArray(o)) return o.map(sortDeep);
  if (o && typeof o === "object") return Object.keys(o).sort().reduce((a, k) => ((a[k] = sortDeep(o[k])), a), {} as Record<string, unknown>);
  return o;
}
const ok = () => new Response("ok");

Deno.serve(async (req) => {
  if (req.method !== "POST") return ok();
  const raw = await req.text();
  try {
    // ---------- CryptoBot ----------
    const cbSig = req.headers.get("crypto-pay-api-signature");
    if (cbSig) {
      const token = Deno.env.get("CRYPTOPAY_TOKEN");
      if (!token) return new Response("no token", { status: 500 });
      const secret = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(token)));
      if (!same(await hmac("SHA-256", secret, raw), cbSig)) return new Response("bad sig", { status: 401 });
      const u = JSON.parse(raw);
      if (u.update_type === "invoice_paid" && u.payload?.status === "paid") {
        const inv = u.payload;
        const { data: dep } = await db.from("deposits").select("id,usd").eq("provider", "cryptobot")
          .eq("invoice_id", inv.invoice_id).single();
        if (dep && String(inv.payload) === String(dep.id)) {
          await db.rpc("credit_deposit", { p_id: dep.id, p_asset: inv.paid_asset || null });
        }
      }
      return ok();
    }

    // ---------- NOWPayments ----------
    const npSig = req.headers.get("x-nowpayments-sig");
    if (npSig) {
      const secret = Deno.env.get("NOWPAYMENTS_IPN_SECRET");
      if (!secret) return new Response("no secret", { status: 500 });
      const p = JSON.parse(raw);
      const sig = await hmac("SHA-512", enc.encode(secret), JSON.stringify(sortDeep(p)));
      if (!same(sig, npSig.toLowerCase())) return new Response("bad sig", { status: 401 });
      if (p.payment_status === "finished") {
        const id = Number(p.order_id);
        const { data: dep } = await db.from("deposits").select("id,usd,status").eq("provider", "nowpayments").eq("id", id).single();
        // сумма и валюта счёта должны совпасть с нашими
        if (dep && String(p.price_currency).toLowerCase() === "usd" && Math.abs(Number(p.price_amount) - Number(dep.usd)) < 0.01) {
          await db.rpc("credit_deposit", { p_id: dep.id, p_asset: p.pay_currency ? String(p.pay_currency).toUpperCase() : null });
        }
      }
      return ok();
    }
    return ok();
  } catch (e) {
    console.error(e);
    return new Response("error", { status: 500 });
  }
});
