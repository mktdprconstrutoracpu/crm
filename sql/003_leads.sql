-- ============================================================================
-- CRM DPR - 003: leads e funil (etapa 2)
--
-- Plano aprovado por ela em 06/10/2026: etapas do funil numa tabela (o gestor
-- renomeia e colore pela tela), leads com o WhatsApp como chave (dois
-- cadastros com o mesmo numero sao a mesma pessoa), linha do tempo
-- automatica, corretor ve so os proprios leads, gestor e administrativo veem
-- todos. O assistente do site da DPR entra pela funcao api/entrada.js, com a
-- chave de servico.
--
-- COMO RODAR: depois do 001 e do 002, no SQL Editor, colar inteiro e Run.
-- Pode repetir: as etapas padrao so entram se ainda nao existirem.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. crm_etapas - as colunas do funil
--    tipo: aberta (em andamento), ganho (venda feita), perdido.
-- ----------------------------------------------------------------------------
create table if not exists public.crm_etapas (
  id             bigint generated always as identity primary key,
  nome           text not null,
  ordem          int  not null,
  cor            text not null default '#8a8a94',
  tipo           text not null default 'aberta' check (tipo in ('aberta', 'ganho', 'perdido')),
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  constraint crm_etapas_nome_key unique (nome)
);

drop trigger if exists crm_etapas_atualizado on public.crm_etapas;
create trigger crm_etapas_atualizado
  before update on public.crm_etapas
  for each row execute function public.crm_toca_atualizado_em();

-- as etapas do Minha Casa, Minha Vida. Renomeaveis pela tela; a chave e o id.
insert into public.crm_etapas (nome, ordem, cor, tipo) values
  ('Novo',              10, '#1565c0', 'aberta'),
  ('Em contato',        20, '#00838f', 'aberta'),
  ('Simulação feita',   30, '#6a1b9a', 'aberta'),
  ('Documentação',      40, '#ef6c00', 'aberta'),
  ('Análise na Caixa',  50, '#c77800', 'aberta'),
  ('Aprovado',          60, '#2e7d32', 'aberta'),
  ('Contrato assinado', 70, '#1b5e20', 'ganho'),
  ('Perdido',           80, '#8a8a94', 'perdido')
on conflict (nome) do nothing;


-- ----------------------------------------------------------------------------
-- 2. crm_leads - uma pessoa interessada
--    telefone: so digitos, com 55 na frente, e UNICO: o WhatsApp e a chave.
--    respostas_assistente: as dez respostas do chat do site, quando o lead
--    veio de la ([{ resumo, valor }]).
-- ----------------------------------------------------------------------------
create table if not exists public.crm_leads (
  id                    bigint generated always as identity primary key,
  nome                  text not null,
  telefone              text not null,
  email                 text,
  origem                text not null default 'outro'
    check (origem in ('site_chat', 'formulario', 'instagram', 'anuncio', 'indicacao', 'plantao', 'portal', 'outro')),
  empreendimento_id     bigint references public.crm_empreendimentos(id) on delete set null,
  unidade_id            bigint references public.crm_unidades(id) on delete set null,
  etapa_id              bigint not null references public.crm_etapas(id),
  responsavel           uuid references public.crm_perfis(user_id) on delete set null,
  observacoes           text,
  motivo_perda          text,
  respostas_assistente  jsonb,
  pagina_origem         text,
  criado_por            uuid references public.crm_perfis(user_id) on delete set null default auth.uid(),
  etapa_desde           timestamptz not null default now(),
  ultimo_contato_em     timestamptz,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  constraint crm_leads_telefone_key unique (telefone),
  constraint crm_leads_telefone_formato check (telefone ~ '^55[1-9][1-9][0-9]{8,9}$')
);

create index if not exists crm_leads_etapa_idx       on public.crm_leads (etapa_id);
create index if not exists crm_leads_responsavel_idx on public.crm_leads (responsavel);

drop trigger if exists crm_leads_atualizado on public.crm_leads;
create trigger crm_leads_atualizado
  before update on public.crm_leads
  for each row execute function public.crm_toca_atualizado_em();


-- ----------------------------------------------------------------------------
-- 3. crm_lead_eventos - a linha do tempo de cada lead
--    criado, etapa, responsavel entram sozinhos (gatilhos abaixo);
--    nota e contato entram pela tela; entrada_site pela funcao api/entrada.
-- ----------------------------------------------------------------------------
create table if not exists public.crm_lead_eventos (
  id         bigint generated always as identity primary key,
  lead_id    bigint not null references public.crm_leads(id) on delete cascade,
  tipo       text not null check (tipo in ('criado', 'etapa', 'responsavel', 'nota', 'contato', 'entrada_site')),
  de         text,
  para       text,
  texto      text,
  autor      uuid references public.crm_perfis(user_id) on delete set null default auth.uid(),
  criado_em  timestamptz not null default now()
);

create index if not exists crm_lead_eventos_lead_idx on public.crm_lead_eventos (lead_id, criado_em);


-- ----------------------------------------------------------------------------
-- 4. Gatilhos do lead
--    ANTES de atualizar: se a etapa mudou, etapa_desde volta para agora.
--    DEPOIS de inserir/atualizar: grava os eventos. security definer porque
--    o evento e gravado em nome de quem mexeu, passando pelas travas da
--    tabela de eventos.
-- ----------------------------------------------------------------------------
create or replace function public.crm_lead_antes_de_atualizar()
returns trigger
language plpgsql
as $$
begin
  if new.etapa_id is distinct from old.etapa_id then
    new.etapa_desde := now();
  end if;
  return new;
end;
$$;

drop trigger if exists crm_leads_antes on public.crm_leads;
create trigger crm_leads_antes
  before update on public.crm_leads
  for each row execute function public.crm_lead_antes_de_atualizar();

create or replace function public.crm_lead_registra_evento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_de   text;
  v_para text;
begin
  if tg_op = 'INSERT' then
    select e.nome into v_para from public.crm_etapas e where e.id = new.etapa_id;
    insert into public.crm_lead_eventos (lead_id, tipo, para, texto, autor)
         values (new.id, 'criado', v_para,
                 case new.origem
                   when 'site_chat' then 'Entrou pelo assistente do site'
                   else 'Cadastrado' end,
                 auth.uid());
    return new;
  end if;

  if new.etapa_id is distinct from old.etapa_id then
    select e.nome into v_de   from public.crm_etapas e where e.id = old.etapa_id;
    select e.nome into v_para from public.crm_etapas e where e.id = new.etapa_id;
    insert into public.crm_lead_eventos (lead_id, tipo, de, para, texto, autor)
         values (new.id, 'etapa', v_de, v_para, nullif(new.motivo_perda, ''), auth.uid());
  end if;

  if new.responsavel is distinct from old.responsavel then
    select p.nome into v_de   from public.crm_perfis p where p.user_id = old.responsavel;
    select p.nome into v_para from public.crm_perfis p where p.user_id = new.responsavel;
    insert into public.crm_lead_eventos (lead_id, tipo, de, para, autor)
         values (new.id, 'responsavel', v_de, v_para, auth.uid());
  end if;

  return new;
end;
$$;

drop trigger if exists crm_leads_eventos on public.crm_leads;
create trigger crm_leads_eventos
  after insert or update on public.crm_leads
  for each row execute function public.crm_lead_registra_evento();


-- ============================================================================
-- 5. TRAVAS DE ACESSO (RLS)
-- ============================================================================
alter table public.crm_etapas       enable row level security;
alter table public.crm_leads        enable row level security;
alter table public.crm_lead_eventos enable row level security;

-- etapas: quem tem acesso le; so gestor mexe (renomear, cor, criar, apagar)
drop policy if exists crm_etapas_le on public.crm_etapas;
create policy crm_etapas_le on public.crm_etapas
  for select to authenticated using (public.crm_tem_acesso());

drop policy if exists crm_etapas_gestor on public.crm_etapas;
create policy crm_etapas_gestor on public.crm_etapas
  for all to authenticated
  using (public.crm_e_gestor()) with check (public.crm_e_gestor());

-- leads: equipe ve e edita todos; corretor so os seus, e nao passa lead para
-- outra pessoa (o with check exige que ele continue responsavel)
drop policy if exists crm_leads_le on public.crm_leads;
create policy crm_leads_le on public.crm_leads
  for select to authenticated
  using (public.crm_e_equipe() or responsavel = auth.uid());

drop policy if exists crm_leads_cria on public.crm_leads;
create policy crm_leads_cria on public.crm_leads
  for insert to authenticated
  with check (public.crm_e_equipe() or (public.crm_tem_acesso() and responsavel = auth.uid()));

drop policy if exists crm_leads_edita on public.crm_leads;
create policy crm_leads_edita on public.crm_leads
  for update to authenticated
  using (public.crm_e_equipe() or responsavel = auth.uid())
  with check (public.crm_e_equipe() or responsavel = auth.uid());

drop policy if exists crm_leads_apaga on public.crm_leads;
create policy crm_leads_apaga on public.crm_leads
  for delete to authenticated using (public.crm_e_gestor());

-- eventos: quem ve o lead ve a linha do tempo dele e pode anotar nela
drop policy if exists crm_lead_eventos_le on public.crm_lead_eventos;
create policy crm_lead_eventos_le on public.crm_lead_eventos
  for select to authenticated
  using (exists (select 1 from public.crm_leads l where l.id = lead_id and (public.crm_e_equipe() or l.responsavel = auth.uid())));

drop policy if exists crm_lead_eventos_anota on public.crm_lead_eventos;
create policy crm_lead_eventos_anota on public.crm_lead_eventos
  for insert to authenticated
  with check (tipo in ('nota', 'contato')
          and exists (select 1 from public.crm_leads l where l.id = lead_id and (public.crm_e_equipe() or l.responsavel = auth.uid())));
