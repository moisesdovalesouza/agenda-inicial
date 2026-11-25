// Grupo Inicial · inicial-nuvem
// Entrega à Agenda Inicial um acesso temporário (1 h) ao OneDrive / Google Drive usando a MESMA conexão
// que o Termo Inicial guarda em nuvem_conexoes (credencial cifrada com AES-256-GCM, chave via HKDF).
// Quem chama se identifica com a sessão do Supabase (Authorization) ou com a chave pessoal da ponte (rede da Cagece).
// Segredos (Supabase › Edge Functions › Secrets): MICROSOFT_CLIENT_SECRET, GOOGLE_DRIVE_CLIENT_SECRET e,
// se existir na Vercel, NUVEM_CHAVE. SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já vêm do próprio Supabase.

const MS_ID = Deno.env.get("MICROSOFT_CLIENT_ID") || "cd442a33-0bda-4ab8-ae91-c37cd1a69fa1";
const GD_ID = Deno.env.get("GOOGLE_DRIVE_CLIENT_ID") || "772697288430-7tg79didk1kfotep9s6ot51ulv5ucann.apps.googleusercontent.com";
const MS_SEGREDO = () => Deno.env.get("MICROSOFT_CLIENT_SECRET") || Deno.env.get("MICROSOFT_CLIENTE_SECRET") || "";
const GD_SEGREDO = () => Deno.env.get("GOOGLE_DRIVE_CLIENT_SECRET") || "";
const SB_URL = Deno.env.get("SUPABASE_URL")!;
// Chave de serviço: formato antigo (JWT) ou novo (sb_secret_…, em SUPABASE_SECRET_KEYS).
const SB_SERVICO = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || (() => { try { return Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}"))[0] as string; } catch { return ""; } })();
const cabServico = (): Record<string, string> => SB_SERVICO.startsWith("sb_") ? { apikey: SB_SERVICO } : { apikey: SB_SERVICO, authorization: `Bearer ${SB_SERVICO}` };
const ORIGENS = ["https://moisesdovalesouza.github.io"];

const cors = (origem: string | null) => ({
  "access-control-allow-origin": origem && (ORIGENS.includes(origem) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origem)) ? origem : ORIGENS[0],
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
  "vary": "origin",
});

// ---------- cifra (idêntica a src/lib/nuvem/cifra.ts do Termo Inicial) ----------
const b64u = {
  de: (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0)),
  para: (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""),
};
async function chave(): Promise<CryptoKey> {
  const base = Deno.env.get("NUVEM_CHAVE") || MS_SEGREDO();
  if (!base || base.length < 20) throw new Erro("Segredo do servidor ausente: cole os segredos em Edge Functions › Secrets.", 503);
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(base), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode("termoinicial"), info: new TextEncoder().encode("credenciais-de-nuvem-v1") },
    k, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}
export async function decifrar<T>(texto: string): Promise<T> {
  const [v, iv, tag, corpo] = texto.split(".");
  if (v !== "v1" || !iv || !tag || !corpo) throw new Erro("Credencial em formato desconhecido.", 409);
  const c = b64u.de(corpo), t = b64u.de(tag), junto = new Uint8Array(c.length + t.length); junto.set(c); junto.set(t, c.length);
  try {
    const claro = await crypto.subtle.decrypt({ name: "AES-GCM", iv: b64u.de(iv) }, await chave(), junto);
    return JSON.parse(new TextDecoder().decode(claro)) as T;
  } catch { throw new Erro("Não consegui abrir a conexão da nuvem: o segredo colado não é o mesmo do Termo Inicial.", 409); }
}
export async function cifrar(dados: unknown): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const tudo = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await chave(), new TextEncoder().encode(JSON.stringify(dados))));
  return `v1.${b64u.para(iv)}.${b64u.para(tudo.slice(-16))}.${b64u.para(tudo.slice(0, -16))}`;
}

class Erro extends Error { constructor(m: string, public status = 400) { super(m); } }

// ---------- banco (com a chave de serviço, sempre filtrando pelo usuário identificado) ----------
async function rest(caminho: string, init: RequestInit = {}) {
  const r = await fetch(`${SB_URL}/rest/v1/${caminho}`, { ...init, headers: { ...cabServico(), "content-type": "application/json", ...(init.headers ?? {}) } });
  if (!r.ok) throw new Erro(`Banco: ${r.status} ${await r.text()}`, 502);
  return r.status === 204 ? null : r.json();
}
async function quem(req: Request, corpo: { chave?: string }): Promise<string> {
  if (corpo.chave){
    if (corpo.chave.length < 40) throw new Erro("Chave inválida.", 401);
    const resumo = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(corpo.chave)))).map((b) => b.toString(16).padStart(2, "0")).join("");
    const l = await rest(`agendainicial_chaves?select=usuario&resumo=eq.${resumo}`);
    if (!l?.length) throw new Erro("Chave inválida.", 401);
    return l[0].usuario;
  }
  const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) throw new Erro("Entre com a conta Google.", 401);
  const r = await fetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: SB_SERVICO, authorization: `Bearer ${jwt}` } });
  if (!r.ok) throw new Erro("Sessão expirada: entre de novo.", 401);
  return (await r.json()).id;
}

// ---------- renovar o acesso ----------
type Cred = { refresh: string };
async function renovar(provedor: string, cred: Cred) {
  const ms = provedor === "onedrive";
  const segredo = ms ? MS_SEGREDO() : GD_SEGREDO();
  if (!segredo) throw new Erro(`Falta o segredo ${ms ? "MICROSOFT_CLIENT_SECRET" : "GOOGLE_DRIVE_CLIENT_SECRET"} em Edge Functions › Secrets.`, 503);
  const r = await fetch(ms ? "https://login.microsoftonline.com/common/oauth2/v2.0/token" : "https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: ms ? MS_ID : GD_ID, client_secret: segredo, grant_type: "refresh_token", refresh_token: cred.refresh,
      ...(ms ? { scope: "offline_access openid email profile User.Read Files.ReadWrite.All" } : {}) }),
  });
  const d = await r.json();
  if (!r.ok || !d.access_token) throw new Erro((ms ? "A Microsoft" : "O Google") + " recusou: " + (d.error_description || d.error || r.status) + ". Reconecte a nuvem no Termo Inicial.", 409);
  return { access: d.access_token as string, refresh: (d.refresh_token as string) || cred.refresh, expira: Date.now() + (Number(d.expires_in ?? 3600) - 120) * 1000 };
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { headers: h });
  const resp = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...h, "content-type": "application/json" } });
  try {
    const corpo = await req.json().catch(() => ({}));
    const u = await quem(req, corpo);
    const linhas: { id: string; provedor: string; conta_email: string; credencial: string }[] =
      await rest(`nuvem_conexoes?select=id,provedor,conta_email,credencial&usuario_id=eq.${u}`);
    const conectadas = linhas.map((l) => ({ provedor: l.provedor, conta: l.conta_email }));
    if (!corpo.provedor) return resp({ ok: true, conectadas });
    const l = linhas.find((x) => x.provedor === corpo.provedor);
    if (!l) throw new Erro(`${corpo.provedor === "onedrive" ? "OneDrive" : "Google Drive"} ainda não conectado no Termo Inicial.`, 404);
    const cred = await decifrar<Cred>(l.credencial);
    const novo = await renovar(l.provedor, cred);
    if (novo.refresh !== cred.refresh) {   // a Microsoft troca o token de renovação: guarda no mesmo formato do Termo Inicial
      await rest(`nuvem_conexoes?id=eq.${l.id}`, { method: "PATCH", body: JSON.stringify({ credencial: await cifrar({ refresh: novo.refresh }), atualizado_em: new Date().toISOString() }), headers: { prefer: "return=minimal" } });
    }
    return resp({ ok: true, provedor: l.provedor, conta: l.conta_email, access: novo.access, expira: novo.expira, conectadas });
  } catch (e) {
    return resp({ ok: false, erro: (e as Error).message }, e instanceof Erro ? e.status : 500);
  }
});
