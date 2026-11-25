-- Pacote Inicial · ambientes de trabalho (empresas), setores, funções e convites.
-- Tabelas próprias da plataforma: as do Termo Inicial (escritorios, membros, convites) não são tocadas.
-- Na unificação, os escritórios do Termo migram para cá (dono → proprietário, sócio → gerente…).
-- Todo acesso passa pelas funções abaixo (security definer), que conferem a função de quem pede;
-- as tabelas não têm acesso direto para anon/authenticated.

create table if not exists public.inicial_ambientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(btrim(nome)) between 2 and 80),
  criado_por uuid not null references auth.users (id),
  criado_em timestamptz not null default now()
);

create table if not exists public.inicial_setores (
  id uuid primary key default gen_random_uuid(),
  ambiente_id uuid not null references public.inicial_ambientes (id) on delete cascade,
  nome text not null check (length(btrim(nome)) between 1 and 80),
  unique (ambiente_id, nome)
);

create table if not exists public.inicial_membros (
  ambiente_id uuid not null references public.inicial_ambientes (id) on delete cascade,
  usuario_id uuid not null references auth.users (id) on delete cascade,
  funcao text not null check (funcao in ('proprietario', 'gerente', 'coordenador', 'colaborador')),
  setor_id uuid references public.inicial_setores (id) on delete set null,
  cargo text check (cargo is null or length(cargo) <= 80),
  entrou_em timestamptz not null default now(),
  primary key (ambiente_id, usuario_id)
);
create unique index if not exists inicial_membros_um_proprietario on public.inicial_membros (ambiente_id) where funcao = 'proprietario';
create index if not exists inicial_membros_usuario on public.inicial_membros (usuario_id);

create table if not exists public.inicial_convites (
  id uuid primary key default gen_random_uuid(),
  ambiente_id uuid not null references public.inicial_ambientes (id) on delete cascade,
  email text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  funcao text not null check (funcao in ('gerente', 'coordenador', 'colaborador')),
  setor_id uuid references public.inicial_setores (id) on delete set null,
  token text not null unique default encode(gen_random_bytes(18), 'hex'),
  limite int not null default 1 check (limite between 1 and 50),
  usos int not null default 0,
  expira_em timestamptz not null default now() + interval '7 days',
  cancelado boolean not null default false,
  recusado_em timestamptz,
  criado_por uuid not null references auth.users (id),
  criado_em timestamptz not null default now()
);
create index if not exists inicial_convites_email on public.inicial_convites (lower(email));

alter table public.inicial_ambientes enable row level security;
alter table public.inicial_setores enable row level security;
alter table public.inicial_membros enable row level security;
alter table public.inicial_convites enable row level security;
revoke all on public.inicial_ambientes, public.inicial_setores, public.inicial_membros, public.inicial_convites from anon, authenticated;

-- Nome e foto de qualquer pessoa da plataforma: o perfil do Termo Inicial, se houver; senão, o da conta Google.
create or replace function public.inicial_pessoa(u uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', x.id, 'email', x.email,
    'nome', coalesce(nullif(p.nome, ''), x.raw_user_meta_data->>'full_name', x.raw_user_meta_data->>'name', split_part(x.email, '@', 1)),
    'foto_caminho', p.foto_caminho,
    'foto_google', coalesce(p.foto_google, x.raw_user_meta_data->>'avatar_url', x.raw_user_meta_data->>'picture'))
  from auth.users x left join public.perfis p on p.usuario_id = x.id
  where x.id = u;
$$;

create or replace function public.inicial_convite_json(c public.inicial_convites)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', c.id, 'ambiente_id', c.ambiente_id, 'ambiente', a.nome, 'email', c.email, 'funcao', c.funcao,
    'setor_id', c.setor_id, 'setor', s.nome, 'token', c.token, 'limite', c.limite, 'usos', c.usos, 'expira_em', c.expira_em,
    'por', public.inicial_pessoa(c.criado_por))
  from public.inicial_ambientes a left join public.inicial_setores s on s.id = c.setor_id
  where a.id = c.ambiente_id;
$$;

create or replace function public.inicial_amb_estado(u uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with eu as (select lower(email) email from auth.users where id = u),
  meus as (select m.* from public.inicial_membros m where m.usuario_id = u)
  select jsonb_build_object(
    'eu', public.inicial_pessoa(u),
    'ambientes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', a.id, 'nome', a.nome, 'funcao', me.funcao, 'setor_id', me.setor_id, 'cargo', me.cargo, 'criado_em', a.criado_em,
        'setores', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'nome', s.nome) order by s.nome) from public.inicial_setores s where s.ambiente_id = a.id), '[]'),
        'membros', coalesce((select jsonb_agg(public.inicial_pessoa(m.usuario_id) || jsonb_build_object('funcao', m.funcao, 'setor_id', m.setor_id, 'cargo', m.cargo, 'entrou_em', m.entrou_em) order by m.entrou_em)
                             from public.inicial_membros m where m.ambiente_id = a.id), '[]'),
        'convites', case when me.funcao in ('proprietario', 'gerente') then coalesce((select jsonb_agg(public.inicial_convite_json(c) order by c.criado_em desc)
                             from public.inicial_convites c where c.ambiente_id = a.id and not c.cancelado and c.recusado_em is null and c.usos < c.limite and c.expira_em > now()), '[]') else '[]' end
      ) order by a.nome) from public.inicial_ambientes a join meus me on me.ambiente_id = a.id), '[]'),
    'convites_para_mim', coalesce((select jsonb_agg(public.inicial_convite_json(c) - 'token' order by c.criado_em desc)
        from public.inicial_convites c, eu
        where c.email is not null and lower(c.email) = eu.email and not c.cancelado and c.recusado_em is null and c.usos < c.limite and c.expira_em > now()
          and not exists (select 1 from public.inicial_membros m where m.ambiente_id = c.ambiente_id and m.usuario_id = u)), '[]'));
$$;

-- Ações. d = dados em JSON. Regras de função:
-- proprietário: tudo; gerente: tudo menos excluir (ambiente, setor, pessoa) e menos mexer em proprietário;
-- coordenador e colaborador: só o próprio cargo e setor, e sair do ambiente.
create or replace function public.inicial_amb_de(u uuid, acao text, d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_amb uuid := nullif(d->>'ambiente', '')::uuid;
  v_eu text; v_minha text; v_alvo text; v_id uuid; v_setor uuid; v_c public.inicial_convites; v_nome text; v_n int;
begin
  if u is null then raise exception 'precisa estar logado'; end if;
  if acao = 'estado' then return public.inicial_amb_estado(u); end if;
  if v_amb is not null then select funcao into v_minha from public.inicial_membros where ambiente_id = v_amb and usuario_id = u; end if;

  if acao = 'criar' then
    v_nome := btrim(coalesce(d->>'nome', ''));
    if length(v_nome) < 2 then raise exception 'dê um nome ao ambiente'; end if;
    select count(*) into v_n from public.inicial_membros where usuario_id = u and funcao = 'proprietario';
    if v_n >= 20 then raise exception 'limite de 20 ambientes próprios'; end if;
    insert into public.inicial_ambientes (nome, criado_por) values (v_nome, u) returning id into v_amb;
    insert into public.inicial_setores (ambiente_id, nome)
      select distinct v_amb, btrim(x) from jsonb_array_elements_text(coalesce(d->'setores', '[]')) x where length(btrim(x)) between 1 and 80;
    select id into v_setor from public.inicial_setores where ambiente_id = v_amb and nome = btrim(coalesce(d->>'meu_setor', ''));
    insert into public.inicial_membros (ambiente_id, usuario_id, funcao, setor_id, cargo) values (v_amb, u, 'proprietario', v_setor, nullif(btrim(d->>'cargo'), ''));
    return public.inicial_amb_estado(u) || jsonb_build_object('criado', v_amb);
  end if;

  if acao in ('convite_aceitar', 'convite_recusar', 'convite_ver') then
    if d ? 'token' then select * into v_c from public.inicial_convites where token = d->>'token';
    else select * into v_c from public.inicial_convites where id = nullif(d->>'id', '')::uuid; end if;
    if v_c.id is null or v_c.cancelado or v_c.recusado_em is not null or v_c.usos >= v_c.limite or v_c.expira_em <= now() then raise exception 'convite inválido, usado ou vencido'; end if;
    select lower(email) into v_eu from auth.users where id = u;
    if not (d ? 'token') and (v_c.email is null or lower(v_c.email) <> v_eu) then raise exception 'este convite não é para você'; end if;
    if acao = 'convite_ver' then return public.inicial_convite_json(v_c) - 'token'; end if;
    if acao = 'convite_recusar' then
      if v_c.email is not null then update public.inicial_convites set recusado_em = now() where id = v_c.id; end if;
      return public.inicial_amb_estado(u);
    end if;
    if not exists (select 1 from public.inicial_membros where ambiente_id = v_c.ambiente_id and usuario_id = u) then
      insert into public.inicial_membros (ambiente_id, usuario_id, funcao, setor_id) values (v_c.ambiente_id, u, v_c.funcao, v_c.setor_id);
      update public.inicial_convites set usos = usos + 1 where id = v_c.id;
    end if;
    return public.inicial_amb_estado(u) || jsonb_build_object('entrou', v_c.ambiente_id);
  end if;

  if v_minha is null then raise exception 'você não faz parte deste ambiente'; end if;

  if acao = 'renomear' then
    if v_minha not in ('proprietario', 'gerente') then raise exception 'só proprietário ou gerente'; end if;
    v_nome := btrim(coalesce(d->>'nome', ''));
    if length(v_nome) < 2 or length(v_nome) > 80 then raise exception 'nome inválido'; end if;
    update public.inicial_ambientes set nome = v_nome where id = v_amb;
  elsif acao = 'setor_add' then
    if v_minha not in ('proprietario', 'gerente') then raise exception 'só proprietário ou gerente'; end if;
    v_nome := btrim(coalesce(d->>'nome', ''));
    if length(v_nome) < 1 or length(v_nome) > 80 then raise exception 'nome de setor inválido'; end if;
    insert into public.inicial_setores (ambiente_id, nome) values (v_amb, v_nome) on conflict do nothing;
  elsif acao = 'setor_rm' then
    if v_minha <> 'proprietario' then raise exception 'só o proprietário exclui'; end if;
    delete from public.inicial_setores where id = (d->>'setor')::uuid and ambiente_id = v_amb;
  elsif acao = 'convidar' then
    if v_minha not in ('proprietario', 'gerente') then raise exception 'só proprietário ou gerente convidam'; end if;
    if coalesce(d->>'funcao', '') not in ('gerente', 'coordenador', 'colaborador') then raise exception 'função inválida'; end if;
    v_setor := nullif(d->>'setor', '')::uuid;
    if v_setor is not null and not exists (select 1 from public.inicial_setores where id = v_setor and ambiente_id = v_amb) then raise exception 'setor inválido'; end if;
    if nullif(btrim(d->>'email'), '') is not null and exists (select 1 from public.inicial_membros m join auth.users x on x.id = m.usuario_id where m.ambiente_id = v_amb and lower(x.email) = lower(btrim(d->>'email'))) then
      raise exception 'essa pessoa já está no ambiente';
    end if;
    insert into public.inicial_convites (ambiente_id, email, funcao, setor_id, limite, criado_por)
      values (v_amb, nullif(lower(btrim(d->>'email')), ''), d->>'funcao', v_setor,
              case when nullif(btrim(d->>'email'), '') is null then least(greatest(coalesce((d->>'limite')::int, 10), 1), 50) else 1 end, u)
      returning * into v_c;
    return public.inicial_amb_estado(u) || jsonb_build_object('convite', public.inicial_convite_json(v_c));
  elsif acao = 'convite_cancelar' then
    if v_minha not in ('proprietario', 'gerente') then raise exception 'só proprietário ou gerente'; end if;
    update public.inicial_convites set cancelado = true where id = (d->>'id')::uuid and ambiente_id = v_amb;
  elsif acao = 'membro' then
    v_id := (d->>'usuario')::uuid;
    select funcao into v_alvo from public.inicial_membros where ambiente_id = v_amb and usuario_id = v_id;
    if v_alvo is null then raise exception 'pessoa não encontrada no ambiente'; end if;
    if d ? 'funcao' and d->>'funcao' is distinct from v_alvo then
      if d->>'funcao' not in ('gerente', 'coordenador', 'colaborador') then raise exception 'função inválida'; end if;
      if v_alvo = 'proprietario' then raise exception 'para mudar o proprietário, transfira a propriedade'; end if;
      if v_minha = 'gerente' and v_alvo = 'gerente' and v_id <> u then raise exception 'gerente não muda outro gerente'; end if;
      if v_minha not in ('proprietario', 'gerente') then raise exception 'só proprietário ou gerente mudam funções'; end if;
      update public.inicial_membros set funcao = d->>'funcao' where ambiente_id = v_amb and usuario_id = v_id;
    end if;
    if d ? 'setor' or d ? 'cargo' then
      if v_id <> u and (v_minha not in ('proprietario', 'gerente') or (v_minha = 'gerente' and v_alvo = 'proprietario')) then raise exception 'sem permissão para mudar os dados dessa pessoa'; end if;
      v_setor := nullif(d->>'setor', '')::uuid;
      if v_setor is not null and not exists (select 1 from public.inicial_setores where id = v_setor and ambiente_id = v_amb) then raise exception 'setor inválido'; end if;
      update public.inicial_membros set
        setor_id = case when d ? 'setor' then v_setor else setor_id end,
        cargo = case when d ? 'cargo' then nullif(left(btrim(d->>'cargo'), 80), '') else cargo end
      where ambiente_id = v_amb and usuario_id = v_id;
    end if;
  elsif acao = 'remover' then
    v_id := (d->>'usuario')::uuid;
    if v_id = u then
      if v_minha = 'proprietario' then raise exception 'o proprietário não sai: transfira a propriedade ou exclua o ambiente'; end if;
    elsif v_minha <> 'proprietario' then raise exception 'só o proprietário remove pessoas';
    end if;
    delete from public.inicial_membros where ambiente_id = v_amb and usuario_id = v_id;
  elsif acao = 'transferir' then
    if v_minha <> 'proprietario' then raise exception 'só o proprietário transfere'; end if;
    v_id := (d->>'usuario')::uuid;
    if v_id = u or not exists (select 1 from public.inicial_membros where ambiente_id = v_amb and usuario_id = v_id) then raise exception 'escolha outra pessoa do ambiente'; end if;
    update public.inicial_membros set funcao = 'gerente' where ambiente_id = v_amb and usuario_id = u;
    update public.inicial_membros set funcao = 'proprietario' where ambiente_id = v_amb and usuario_id = v_id;
  elsif acao = 'excluir' then
    if v_minha <> 'proprietario' then raise exception 'só o proprietário exclui o ambiente'; end if;
    if coalesce(d->>'confirmo', '') <> (select nome from public.inicial_ambientes where id = v_amb) then raise exception 'confirme digitando o nome do ambiente'; end if;
    delete from public.inicial_ambientes where id = v_amb;
  else
    raise exception 'ação desconhecida';
  end if;
  return public.inicial_amb_estado(u);
end $$;

-- Com login (Supabase acessível)
create or replace function public.inicial_amb(acao text, dados jsonb default '{}')
returns jsonb language sql security definer set search_path = '' as $$ select public.inicial_amb_de(auth.uid(), acao, coalesce(dados, '{}')) $$;
-- Pela ponte (rede que bloqueia o Supabase), com a chave pessoal
create or replace function public.agendainicial_ponte_amb(p_chave text, p_acao text, p_dados jsonb default '{}')
returns jsonb language sql security definer set search_path = '' as $$ select public.inicial_amb_de(public.agendainicial_dono(p_chave), p_acao, coalesce(p_dados, '{}')) $$;

revoke all on function public.inicial_pessoa(uuid) from public, anon, authenticated;
revoke all on function public.inicial_convite_json(public.inicial_convites) from public, anon, authenticated;
revoke all on function public.inicial_amb_estado(uuid) from public, anon, authenticated;
revoke all on function public.inicial_amb_de(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.inicial_amb(text, jsonb) from public, anon;
revoke all on function public.agendainicial_ponte_amb(text, text, jsonb) from public;
grant execute on function public.inicial_amb(text, jsonb) to authenticated;
grant execute on function public.agendainicial_ponte_amb(text, text, jsonb) to anon, authenticated;
