-- Grupo Inicial · a mesma foto de perfil em todos os apps.
-- Lê a foto do Termo Inicial (enviada ou a da conta Google) e permite trocá-la por um arquivo já enviado
-- para a pasta do próprio usuário no Storage (fotos-perfil/<usuario>/…).

create or replace function public.inicial_perfil_de(u uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', p.nome, 'telefone', p.telefone, 'oab_numero', p.oab_numero, 'oab_uf', p.oab_uf,
                            'foto_caminho', p.foto_caminho, 'foto_google', p.foto_google, 'atualizado', p.atualizado_em)
  from public.perfis p where p.usuario_id = u;
$$;

create or replace function public.inicial_perfil_gravar_de(u uuid, d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_nome text := nullif(btrim(d->>'nome'), '');
  v_tel text := nullif(regexp_replace(coalesce(d->>'telefone', ''), '\D', '', 'g'), '');
  v_oab text := nullif(regexp_replace(coalesce(d->>'oab_numero', ''), '\D', '', 'g'), '');
  v_uf text := nullif(upper(btrim(d->>'oab_uf')), '');
  v_foto text := nullif(btrim(d->>'foto_caminho'), '');
begin
  if not exists (select 1 from public.perfis where usuario_id = u) then return null; end if;
  if d ? 'nome' and (v_nome is null or length(v_nome) < 5 or position(' ' in v_nome) = 0 or length(v_nome) > 160) then raise exception 'nome completo inválido'; end if;
  if d ? 'telefone' and v_tel is not null and length(v_tel) not between 10 and 11 then raise exception 'telefone com DDD (10 ou 11 dígitos)'; end if;
  if d ? 'oab_numero' and v_oab is not null and (length(v_oab) not between 3 and 7 or v_uf is null or v_uf !~ '^[A-Z]{2}$') then raise exception 'inscrição na OAB inválida'; end if;
  if d ? 'foto_caminho' and v_foto is not null and (left(v_foto, 37) <> u::text || '/' or position('..' in v_foto) > 0 or length(v_foto) > 200) then raise exception 'foto fora da pasta do usuário'; end if;
  update public.perfis set
    nome = case when d ? 'nome' then v_nome else nome end,
    telefone = case when d ? 'telefone' then v_tel else telefone end,
    oab_numero = case when d ? 'oab_numero' then v_oab else oab_numero end,
    oab_uf = case when d ? 'oab_numero' then (case when v_oab is null then null else v_uf end) else oab_uf end,
    foto_caminho = case when d ? 'foto_caminho' then v_foto else foto_caminho end
  where usuario_id = u;
  return public.inicial_perfil_de(u);
end $$;
