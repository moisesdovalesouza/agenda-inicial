-- Agenda Inicial · ponte para redes que bloqueiam o Supabase (ex.: rede da Cagece).
-- A agenda fala com um Google Apps Script, que repassa a estas funções usando apenas a chave pública.
-- Cada usuário gera uma chave pessoal longa; no banco fica só o resumo (sha256) dela.

create table if not exists public.agendainicial_chaves (
  usuario uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  resumo text not null unique,
  criado timestamptz not null default now()
);
alter table public.agendainicial_chaves enable row level security;
revoke all on public.agendainicial_chaves from anon, authenticated;

-- Gera (ou troca) a chave do usuário logado. Só quem está logado consegue.
create or replace function public.agendainicial_definir_chave(p_chave text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  if p_chave is null or length(p_chave) < 40 then raise exception 'chave curta demais'; end if;
  insert into public.agendainicial_chaves (usuario, resumo)
  values (auth.uid(), encode(sha256(convert_to(p_chave, 'UTF8')), 'hex'))
  on conflict (usuario) do update set resumo = excluded.resumo, criado = now();
end $$;

create or replace function public.agendainicial_apagar_chave()
returns void language sql security definer set search_path = '' as $$
  delete from public.agendainicial_chaves where usuario = auth.uid();
$$;

create or replace function public.agendainicial_dono(p_chave text)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare u uuid;
begin
  if p_chave is null or length(p_chave) < 40 then raise exception 'chave inválida'; end if;
  select usuario into u from public.agendainicial_chaves where resumo = encode(sha256(convert_to(p_chave, 'UTF8')), 'hex');
  if u is null then raise exception 'chave inválida'; end if;
  return u;
end $$;

-- Ler o que mudou desde um instante.
create or replace function public.agendainicial_ponte_ler(p_chave text, p_desde timestamptz, p_limite int default 500)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare u uuid := public.agendainicial_dono(p_chave);
begin
  return jsonb_build_object('usuario', u, 'itens', coalesce((
    select jsonb_agg(to_jsonb(x) order by x.atualizado) from (
      select tipo, id, dados, excluido, alterado_em, atualizado
      from public.agendainicial_itens
      where usuario = u and atualizado > p_desde
      order by atualizado limit least(greatest(p_limite, 1), 1000)) x), '[]'::jsonb));
end $$;

-- Gravar itens (o gatilho de carimbo continua impedindo que versão antiga sobrescreva a nova).
create or replace function public.agendainicial_ponte_gravar(p_chave text, p_itens jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare u uuid := public.agendainicial_dono(p_chave); n int;
begin
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) > 500 then raise exception 'lote inválido'; end if;
  insert into public.agendainicial_itens (usuario, tipo, id, dados, excluido, alterado_em)
  select u, i->>'tipo', i->>'id', coalesce(i->'dados', '{}'::jsonb), coalesce((i->>'excluido')::boolean, false), coalesce((i->>'alterado_em')::bigint, 0)
  from jsonb_array_elements(p_itens) i
  on conflict (usuario, tipo, id) do update
    set dados = excluded.dados, excluido = excluded.excluido, alterado_em = excluded.alterado_em;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.agendainicial_definir_chave(text) from public, anon;
revoke all on function public.agendainicial_apagar_chave() from public, anon;
revoke all on function public.agendainicial_dono(text) from public, anon, authenticated;
revoke all on function public.agendainicial_ponte_ler(text, timestamptz, int) from public;
revoke all on function public.agendainicial_ponte_gravar(text, jsonb) from public;
grant execute on function public.agendainicial_definir_chave(text) to authenticated;
grant execute on function public.agendainicial_apagar_chave() to authenticated;
grant execute on function public.agendainicial_ponte_ler(text, timestamptz, int) to anon, authenticated;
grant execute on function public.agendainicial_ponte_gravar(text, jsonb) to anon, authenticated;
