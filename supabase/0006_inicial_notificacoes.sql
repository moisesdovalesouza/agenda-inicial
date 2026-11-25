-- Pacote Inicial · notificações do sininho que vêm de outras pessoas
-- (entrada no ambiente, mudança de função, remoção, propriedade; depois: menções, designações, compartilhamentos).
-- Os avisos do próprio dia (compromissos, ponto, registro futuro, atualização do app) são calculados no aparelho.

create table if not exists public.inicial_notificacoes (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users (id) on delete cascade,
  ambiente_id uuid references public.inicial_ambientes (id) on delete cascade,
  de_id uuid references auth.users (id) on delete set null,
  tipo text not null check (length(tipo) between 2 and 40),
  titulo text not null check (length(titulo) between 1 and 200),
  texto text check (texto is null or length(texto) <= 1000),
  dados jsonb not null default '{}',
  criado_em timestamptz not null default now(),
  lida_em timestamptz
);
create index if not exists inicial_notificacoes_usuario on public.inicial_notificacoes (usuario_id, criado_em desc);
alter table public.inicial_notificacoes enable row level security;
revoke all on public.inicial_notificacoes from anon, authenticated;

create or replace function public.inicial_notificar(p_para uuid, p_amb uuid, p_de uuid, p_tipo text, p_titulo text, p_texto text default null, p_dados jsonb default '{}')
returns void language sql security definer set search_path = '' as $$
  insert into public.inicial_notificacoes (usuario_id, ambiente_id, de_id, tipo, titulo, texto, dados)
  select p_para, p_amb, p_de, p_tipo, left(p_titulo, 200), left(p_texto, 1000), coalesce(p_dados, '{}')
  where p_para is not null and p_para is distinct from p_de;
$$;

create or replace function public.inicial_notif_de(u uuid, acao text, d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if u is null then raise exception 'precisa estar logado'; end if;
  if acao = 'lidas' then
    update public.inicial_notificacoes set lida_em = now()
     where usuario_id = u and lida_em is null
       and (not (d ? 'ids') or id in (select (x)::uuid from jsonb_array_elements_text(d->'ids') x));
  elsif acao <> 'listar' then raise exception 'ação desconhecida';
  end if;
  -- guarda só os últimos 60 dias
  delete from public.inicial_notificacoes where usuario_id = u and criado_em < now() - interval '60 days';
  return jsonb_build_object(
    'nao_lidas', (select count(*) from public.inicial_notificacoes where usuario_id = u and lida_em is null),
    'itens', coalesce((select jsonb_agg(x order by x->>'criado_em' desc) from (
      select jsonb_build_object('id', n.id, 'tipo', n.tipo, 'titulo', n.titulo, 'texto', n.texto, 'dados', n.dados,
        'ambiente_id', n.ambiente_id, 'criado_em', n.criado_em, 'lida', n.lida_em is not null,
        'de', case when n.de_id is null then null else public.inicial_pessoa(n.de_id) end) x
      from public.inicial_notificacoes n where n.usuario_id = u order by n.criado_em desc limit 50) t), '[]'));
end $$;

create or replace function public.inicial_notif(acao text, dados jsonb default '{}')
returns jsonb language sql security definer set search_path = '' as $$ select public.inicial_notif_de(auth.uid(), acao, coalesce(dados, '{}')) $$;
create or replace function public.agendainicial_ponte_notif(p_chave text, p_acao text, p_dados jsonb default '{}')
returns jsonb language sql security definer set search_path = '' as $$ select public.inicial_notif_de(public.agendainicial_dono(p_chave), p_acao, coalesce(p_dados, '{}')) $$;

-- Avisos gerados pelas ações dos ambientes
create or replace function public.inicial_membros_avisar()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_amb text; v_quem uuid := auth.uid(); v_nome text;
begin
  if v_quem is null then v_quem := nullif(current_setting('app.agenda_dono', true), '')::uuid; end if;
  select nome into v_amb from public.inicial_ambientes where id = coalesce(new.ambiente_id, old.ambiente_id);
  if tg_op = 'INSERT' then
    if new.funcao <> 'proprietario' then
      select coalesce(public.inicial_pessoa(new.usuario_id)->>'nome', 'Alguém') into v_nome;
      perform public.inicial_notificar(m.usuario_id, new.ambiente_id, new.usuario_id, 'entrou', v_nome || ' entrou em ' || v_amb, null, jsonb_build_object('usuario', new.usuario_id))
        from public.inicial_membros m where m.ambiente_id = new.ambiente_id and m.funcao in ('proprietario', 'gerente') and m.usuario_id <> new.usuario_id;
    end if;
  elsif tg_op = 'UPDATE' then
    if new.funcao is distinct from old.funcao then
      perform public.inicial_notificar(new.usuario_id, new.ambiente_id, v_quem, 'funcao',
        'Sua função em ' || v_amb || ' agora é ' || case new.funcao when 'proprietario' then 'Proprietário' when 'gerente' then 'Gerente' when 'coordenador' then 'Coordenador' else 'Colaborador' end,
        null, jsonb_build_object('funcao', new.funcao));
    end if;
  elsif tg_op = 'DELETE' then
    if v_quem is distinct from old.usuario_id and exists (select 1 from public.inicial_ambientes where id = old.ambiente_id) then
      perform public.inicial_notificar(old.usuario_id, null, v_quem, 'removido', 'Você foi removido de ' || v_amb, null, '{}');
    end if;
    return old;
  end if;
  return new;
end $$;
drop trigger if exists inicial_membros_avisar on public.inicial_membros;
create trigger inicial_membros_avisar after insert or update or delete on public.inicial_membros
  for each row execute function public.inicial_membros_avisar();

-- Pela ponte não há auth.uid(): a ação dos ambientes informa quem está agindo.
create or replace function public.agendainicial_ponte_amb(p_chave text, p_acao text, p_dados jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_u uuid := public.agendainicial_dono(p_chave);
begin
  perform set_config('app.agenda_dono', coalesce(v_u::text, ''), true);
  return public.inicial_amb_de(v_u, p_acao, coalesce(p_dados, '{}'));
end $$;

revoke all on function public.inicial_notificar(uuid, uuid, uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.inicial_notif_de(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.inicial_membros_avisar() from public, anon, authenticated;
revoke all on function public.inicial_notif(text, jsonb) from public, anon;
revoke all on function public.agendainicial_ponte_notif(text, text, jsonb) from public;
revoke all on function public.agendainicial_ponte_amb(text, text, jsonb) from public;
grant execute on function public.inicial_notif(text, jsonb) to authenticated;
grant execute on function public.agendainicial_ponte_notif(text, text, jsonb) to anon, authenticated;
grant execute on function public.agendainicial_ponte_amb(text, text, jsonb) to anon, authenticated;
