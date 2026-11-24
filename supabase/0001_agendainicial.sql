-- Agenda Inicial: dados de cada pessoa na nuvem (mesmo projeto Supabase do Termo Inicial).
-- Tabela própria, separada das tabelas do Termo Inicial (agenda_conexoes, agenda_eventos...).
-- Cada linha é um item da agenda (registro, lista, caderno, anexo, anotação do dia ou ajuste),
-- guardado como JSON. Só o dono enxerga e altera os próprios itens.

create table if not exists public.agendainicial_itens (
  usuario     uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  tipo        text        not null check (tipo in ('registro', 'lista', 'caderno', 'arquivo', 'dia', 'ajuste')),
  id          text        not null check (length(id) between 1 and 120),
  dados       jsonb       not null default '{}'::jsonb,
  excluido    boolean     not null default false,          -- exclusão marcada, para os outros aparelhos saberem
  alterado_em bigint      not null default 0,              -- relógio do aparelho que alterou (a mais recente vale)
  atualizado  timestamptz not null default now(),          -- relógio do servidor (para buscar só o que mudou)
  primary key (usuario, tipo, id)
);

create index if not exists agendainicial_itens_mudancas on public.agendainicial_itens (usuario, atualizado);

create or replace function public.agendainicial_carimbo() returns trigger
language plpgsql as $$
begin
  new.atualizado := now();
  -- nunca aceita uma versão mais antiga por cima de uma mais nova
  if tg_op = 'UPDATE' and new.alterado_em < old.alterado_em then
    return old;
  end if;
  return new;
end $$;

drop trigger if exists agendainicial_carimbo on public.agendainicial_itens;
create trigger agendainicial_carimbo before insert or update on public.agendainicial_itens
  for each row execute function public.agendainicial_carimbo();

alter table public.agendainicial_itens enable row level security;

drop policy if exists agendainicial_ver on public.agendainicial_itens;
drop policy if exists agendainicial_criar on public.agendainicial_itens;
drop policy if exists agendainicial_alterar on public.agendainicial_itens;
drop policy if exists agendainicial_apagar on public.agendainicial_itens;
create policy agendainicial_ver     on public.agendainicial_itens for select using (usuario = auth.uid());
create policy agendainicial_criar   on public.agendainicial_itens for insert with check (usuario = auth.uid());
create policy agendainicial_alterar on public.agendainicial_itens for update using (usuario = auth.uid()) with check (usuario = auth.uid());
create policy agendainicial_apagar  on public.agendainicial_itens for delete using (usuario = auth.uid());

grant select, insert, update, delete on public.agendainicial_itens to authenticated;
revoke all on public.agendainicial_itens from anon;
