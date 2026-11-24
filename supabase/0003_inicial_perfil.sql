-- Grupo Inicial · perfil único entre os apps (Termo Inicial, Agenda Inicial…).
-- A fonte é a tabela perfis do Termo Inicial; a agenda lê e grava só os campos em comum:
-- nome, telefone e inscrição na OAB. Nada é criado: se a pessoa não tem perfil no Termo Inicial, nada muda.

create or replace function public.inicial_perfil_de(u uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', p.nome, 'telefone', p.telefone, 'oab_numero', p.oab_numero, 'oab_uf', p.oab_uf,
                            'atualizado', p.atualizado_em)
  from public.perfis p where p.usuario_id = u;
$$;

create or replace function public.inicial_perfil_gravar_de(u uuid, d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_nome text := nullif(btrim(d->>'nome'), '');
  v_tel text := nullif(regexp_replace(coalesce(d->>'telefone', ''), '\D', '', 'g'), '');
  v_oab text := nullif(regexp_replace(coalesce(d->>'oab_numero', ''), '\D', '', 'g'), '');
  v_uf text := nullif(upper(btrim(d->>'oab_uf')), '');
begin
  if not exists (select 1 from public.perfis where usuario_id = u) then return null; end if;
  if d ? 'nome' and (v_nome is null or length(v_nome) < 5 or position(' ' in v_nome) = 0 or length(v_nome) > 160) then raise exception 'nome completo inválido'; end if;
  if d ? 'telefone' and v_tel is not null and length(v_tel) not between 10 and 11 then raise exception 'telefone com DDD (10 ou 11 dígitos)'; end if;
  if d ? 'oab_numero' and v_oab is not null and (length(v_oab) not between 3 and 7 or v_uf is null or v_uf !~ '^[A-Z]{2}$') then raise exception 'inscrição na OAB inválida'; end if;
  update public.perfis set
    nome = case when d ? 'nome' then v_nome else nome end,
    telefone = case when d ? 'telefone' then v_tel else telefone end,
    oab_numero = case when d ? 'oab_numero' then v_oab else oab_numero end,
    oab_uf = case when d ? 'oab_numero' then (case when v_oab is null then null else v_uf end) else oab_uf end
  where usuario_id = u;
  return public.inicial_perfil_de(u);
end $$;

-- Com login (Supabase acessível)
create or replace function public.inicial_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$ select public.inicial_perfil_de(auth.uid()) $$;
create or replace function public.inicial_perfil_gravar(d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  return public.inicial_perfil_gravar_de(auth.uid(), d);
end $$;

-- Pela ponte (rede que bloqueia o Supabase), com a chave pessoal
create or replace function public.agendainicial_ponte_perfil(p_chave text)
returns jsonb language sql stable security definer set search_path = '' as $$ select public.inicial_perfil_de(public.agendainicial_dono(p_chave)) $$;
create or replace function public.agendainicial_ponte_perfil_gravar(p_chave text, p_dados jsonb)
returns jsonb language sql security definer set search_path = '' as $$ select public.inicial_perfil_gravar_de(public.agendainicial_dono(p_chave), p_dados) $$;

revoke all on function public.inicial_perfil_de(uuid) from public, anon, authenticated;
revoke all on function public.inicial_perfil_gravar_de(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.inicial_perfil() from public, anon;
revoke all on function public.inicial_perfil_gravar(jsonb) from public, anon;
revoke all on function public.agendainicial_ponte_perfil(text) from public;
revoke all on function public.agendainicial_ponte_perfil_gravar(text, jsonb) from public;
grant execute on function public.inicial_perfil() to authenticated;
grant execute on function public.inicial_perfil_gravar(jsonb) to authenticated;
grant execute on function public.agendainicial_ponte_perfil(text) to anon, authenticated;
grant execute on function public.agendainicial_ponte_perfil_gravar(text, jsonb) to anon, authenticated;
