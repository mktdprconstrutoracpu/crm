-- ============================================================================
-- CRM DPR - etapa 1: a base
--
-- Quem usa o CRM (perfis e papeis), os empreendimentos e o estoque de unidades.
-- Roda no MESMO projeto Supabase do Central DPR (portal do cliente). Por isso
-- toda tabela, funcao e politica daqui comeca com crm_: nada colide com
-- unidades, parcelas e vinculos do portal, e a ponte entre os dois (contrato
-- assinado virando unidade no portal) fica para a etapa 6.
--
-- COMO RODAR
-- Supabase > SQL Editor > New query > colar este arquivo inteiro > Run.
-- Pode rodar mais de uma vez sem estragar nada ("if not exists", "create or
-- replace", "drop policy if exists").
--
-- DEPOIS DE RODAR
-- 1. Crie (ou use) a conta do primeiro gestor: Authentication > Users > Add
--    user, com e-mail e senha. Ou entre uma vez no CRM e use "Esqueci a senha".
-- 2. Promova essa conta a gestor, aqui no SQL Editor:
--      select public.crm_promover_gestor('email@da.pessoa');
-- 3. A partir dai os outros entram por convite, pela tela Equipe do CRM.
--
-- QUEM VE O QUE (as travas valem no banco, nao so na tela)
--   gestor          ve tudo, edita tudo, convida e desativa pessoas
--   administrativo  ve tudo, edita empreendimentos e unidades
--   corretor        ve empreendimentos e unidades, nao edita nada (ainda)
--   sem perfil      nao ve nada, mesmo logado (um cliente do portal, por exemplo)
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. crm_perfis - quem usa o CRM e com que papel
--
-- Uma linha por login do Supabase (auth.users). O e-mail e copiado para ca
-- porque o navegador nao le auth.users; o telefone e para o WhatsApp.
-- senha_definida: quem entra por convite ainda nao tem senha; o CRM obriga a
-- criar uma no primeiro acesso.
-- ----------------------------------------------------------------------------
create table if not exists public.crm_perfis (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  nome            text not null,
  email           text not null,
  telefone        text,
  papel           text not null default 'corretor'
    check (papel in ('gestor', 'administrativo', 'corretor')),
  ativo           boolean not null default true,
  senha_definida  boolean not null default false,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);

create unique index if not exists crm_perfis_email_idx
  on public.crm_perfis (lower(email));


-- ----------------------------------------------------------------------------
-- 2. Quem esta chamando: funcoes que as travas usam
--
-- security definer para ler crm_perfis por dentro, sem cair na propria trava
-- da tabela (senao a politica de crm_perfis chamaria a si mesma sem fim).
-- stable: pode ser avaliada uma vez por consulta.
-- ----------------------------------------------------------------------------
create or replace function public.crm_papel()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.papel
    from public.crm_perfis p
   where p.user_id = auth.uid()
     and p.ativo
$$;

create or replace function public.crm_tem_acesso()
returns boolean language sql stable security definer set search_path = public
as $$ select public.crm_papel() is not null $$;

create or replace function public.crm_e_equipe()
returns boolean language sql stable security definer set search_path = public
as $$ select public.crm_papel() in ('gestor', 'administrativo') $$;

create or replace function public.crm_e_gestor()
returns boolean language sql stable security definer set search_path = public
as $$ select public.crm_papel() = 'gestor' $$;

revoke all on function public.crm_papel()      from public, anon;
revoke all on function public.crm_tem_acesso() from public, anon;
revoke all on function public.crm_e_equipe()   from public, anon;
revoke all on function public.crm_e_gestor()   from public, anon;
grant execute on function public.crm_papel()      to authenticated;
grant execute on function public.crm_tem_acesso() to authenticated;
grant execute on function public.crm_e_equipe()   to authenticated;
grant execute on function public.crm_e_gestor()   to authenticated;


-- ----------------------------------------------------------------------------
-- 3. atualizado_em sempre em dia, sem depender do site lembrar
-- ----------------------------------------------------------------------------
create or replace function public.crm_toca_atualizado_em()
returns trigger
language plpgsql
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

drop trigger if exists crm_perfis_atualizado on public.crm_perfis;
create trigger crm_perfis_atualizado
  before update on public.crm_perfis
  for each row execute function public.crm_toca_atualizado_em();


-- ----------------------------------------------------------------------------
-- 4. Ninguem se promove: so gestor muda papel, ativo, e-mail ou dono do perfil
--
-- A politica de UPDATE deixa cada pessoa editar o PROPRIO perfil (nome,
-- telefone, senha_definida). Sem este gatilho, um corretor trocaria o proprio
-- papel para gestor. O gatilho olha o que mudou e barra se nao for gestor.
-- A chave de servico (funcao api/convidar) nao passa por aqui: auth.uid() e
-- nulo e crm_e_gestor() e falso, entao comparamos tambem current_user.
-- ----------------------------------------------------------------------------
create or replace function public.crm_protege_perfil()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if current_user in ('service_role', 'postgres', 'supabase_admin') then
    return new;
  end if;
  if (new.papel   is distinct from old.papel
   or new.ativo   is distinct from old.ativo
   or new.email   is distinct from old.email
   or new.user_id is distinct from old.user_id)
     and not public.crm_e_gestor() then
    raise exception 'Somente um gestor pode mudar papel, situacao ou e-mail de um perfil.';
  end if;
  return new;
end;
$$;

drop trigger if exists crm_perfis_protegido on public.crm_perfis;
create trigger crm_perfis_protegido
  before update on public.crm_perfis
  for each row execute function public.crm_protege_perfil();


-- ----------------------------------------------------------------------------
-- 5. crm_empreendimentos
-- ----------------------------------------------------------------------------
create table if not exists public.crm_empreendimentos (
  id             bigint generated always as identity primary key,
  nome           text not null,
  cidade         text,
  uf             text not null default 'SP' check (char_length(uf) = 2),
  tipo           text not null default 'casas'
    check (tipo in ('casas', 'lotes', 'apartamentos')),
  programa       text not null default 'Minha Casa, Minha Vida',
  status         text not null default 'lancamento'
    check (status in ('lancamento', 'em_obras', 'entregue', 'encerrado')),
  observacoes    text,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  constraint crm_empreendimentos_nome_key unique (nome)
);

drop trigger if exists crm_empreendimentos_atualizado on public.crm_empreendimentos;
create trigger crm_empreendimentos_atualizado
  before update on public.crm_empreendimentos
  for each row execute function public.crm_toca_atualizado_em();


-- ----------------------------------------------------------------------------
-- 6. crm_unidades - o estoque: uma linha por casa, lote ou apartamento
--
-- O par (empreendimento_id, codigo) e unico: "CASA 03" so existe uma vez no
-- Villagio Caucaia II. E por esse par que a etapa 6 vai casar a unidade
-- vendida com a tabela unidades do portal do cliente.
-- Reserva: quem reservou e ate quando; a etapa 2 liga a reserva ao lead.
-- ----------------------------------------------------------------------------
create table if not exists public.crm_unidades (
  id                bigint generated always as identity primary key,
  empreendimento_id bigint not null
                      references public.crm_empreendimentos(id) on delete restrict,
  codigo            text not null,            -- "CASA 03", "LOTE 12", "APTO 101"
  quadra            text,                     -- quadra, bloco ou rua
  metragem_m2       numeric(10,2),
  valor             numeric(14,2),
  status            text not null default 'disponivel'
    check (status in ('disponivel', 'reservada', 'vendida', 'indisponivel')),
  reservado_por     uuid references public.crm_perfis(user_id) on delete set null,
  reserva_ate       timestamptz,
  observacoes       text,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  constraint crm_unidades_empreendimento_codigo_key unique (empreendimento_id, codigo)
);

create index if not exists crm_unidades_empreendimento_idx
  on public.crm_unidades (empreendimento_id, status);

drop trigger if exists crm_unidades_atualizado on public.crm_unidades;
create trigger crm_unidades_atualizado
  before update on public.crm_unidades
  for each row execute function public.crm_toca_atualizado_em();


-- ============================================================================
-- 7. TRAVAS DE ACESSO (RLS)
-- ============================================================================
alter table public.crm_perfis          enable row level security;
alter table public.crm_empreendimentos enable row level security;
alter table public.crm_unidades        enable row level security;

-- perfis: quem tem acesso ve a equipe toda (precisa dos nomes para saber quem
-- e o responsavel por cada coisa); cada um edita o proprio; gestor edita todos.
-- Ninguem insere ou apaga pelo navegador: entrar e por convite (api/convidar,
-- chave de servico) e sair e ficar inativo, nunca apagado (historico).
drop policy if exists crm_perfis_le_equipe on public.crm_perfis;
create policy crm_perfis_le_equipe on public.crm_perfis
  for select to authenticated
  using (public.crm_tem_acesso());

drop policy if exists crm_perfis_edita_o_proprio on public.crm_perfis;
create policy crm_perfis_edita_o_proprio on public.crm_perfis
  for update to authenticated
  using (user_id = auth.uid() and public.crm_tem_acesso())
  with check (user_id = auth.uid());

drop policy if exists crm_perfis_gestor_edita on public.crm_perfis;
create policy crm_perfis_gestor_edita on public.crm_perfis
  for update to authenticated
  using (public.crm_e_gestor())
  with check (public.crm_e_gestor());

-- empreendimentos e unidades: todo mundo com acesso le; so a equipe escreve.
drop policy if exists crm_empreendimentos_le on public.crm_empreendimentos;
create policy crm_empreendimentos_le on public.crm_empreendimentos
  for select to authenticated using (public.crm_tem_acesso());

drop policy if exists crm_empreendimentos_escreve on public.crm_empreendimentos;
create policy crm_empreendimentos_escreve on public.crm_empreendimentos
  for all to authenticated
  using (public.crm_e_equipe()) with check (public.crm_e_equipe());

drop policy if exists crm_unidades_le on public.crm_unidades;
create policy crm_unidades_le on public.crm_unidades
  for select to authenticated using (public.crm_tem_acesso());

drop policy if exists crm_unidades_escreve on public.crm_unidades;
create policy crm_unidades_escreve on public.crm_unidades
  for all to authenticated
  using (public.crm_e_equipe()) with check (public.crm_e_equipe());


-- ----------------------------------------------------------------------------
-- 8. crm_promover_gestor(email) - o primeiro gestor, e socorro
--
-- Roda so no SQL Editor (quem esta la ja e dono do projeto). Acha o login pelo
-- e-mail em auth.users e cria ou atualiza o perfil como gestor ativo, com a
-- senha ja definida (a pessoa criou a conta com senha).
-- ----------------------------------------------------------------------------
create or replace function public.crm_promover_gestor(p_email text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid;
  v_nome text;
begin
  select u.id,
         coalesce(u.raw_user_meta_data ->> 'nome', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1))
    into v_uid, v_nome
    from auth.users u
   where lower(u.email) = lower(trim(p_email))
   limit 1;

  if v_uid is null then
    return 'Nao achei nenhum login com o e-mail ' || p_email || '. Crie a conta em Authentication > Users primeiro.';
  end if;

  insert into public.crm_perfis (user_id, nome, email, papel, ativo, senha_definida)
       values (v_uid, v_nome, lower(trim(p_email)), 'gestor', true, true)
  on conflict (user_id) do update
        set papel = 'gestor', ativo = true, senha_definida = true;

  return 'Pronto: ' || p_email || ' e gestor do CRM.';
end;
$$;

revoke all on function public.crm_promover_gestor(text) from public, anon, authenticated;
