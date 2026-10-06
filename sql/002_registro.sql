-- ============================================================================
-- CRM DPR - 002: cadastro pela tela "Criar conta", com aprovacao do gestor
--
-- Pedido dela em 06/10/2026: registrar com e-mail, senha e nivel direto no
-- CRM, gravando no Supabase, com os usuarios do CRM separados dos clientes
-- do portal (Central DPR). O login e o mesmo Supabase Auth; a separacao e
-- esta tabela: so quem tem crm_perfis entra no CRM, e um cliente do portal
-- nunca ganha perfil aqui sem passar pelo cadastro ou por um convite.
--
-- POR QUE NAO DEIXAR QUALQUER UM SE CADASTRAR COMO GESTOR
-- O CRM guarda telefone de lead e comissao. Se o nivel escolhido no cadastro
-- valesse na hora, qualquer pessoa com o endereco do site viraria gestor.
-- Entao:
--   - o PRIMEIRO cadastro (quando ainda nao ha gestor ativo) vira gestor na
--     hora: e quem esta montando o CRM;
--   - os seguintes entram com o nivel pedido, mas INATIVOS e sem aprovacao
--     (aprovado_em nulo). Um gestor aprova na tela Equipe, podendo trocar o
--     nivel antes.
--
-- COMO RODAR: depois do 001, no SQL Editor, colar inteiro e Run. Pode repetir.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. aprovado_em: distingue "nunca foi aprovado" de "foi desativado"
--    ativo=false e aprovado_em nulo  -> aguardando aprovacao
--    ativo=false e aprovado_em cheio -> desativado por um gestor
-- ----------------------------------------------------------------------------
alter table public.crm_perfis add column if not exists aprovado_em timestamptz;

-- quem ja estava na tabela entrou por convite ou pelo SQL: conta como aprovado
update public.crm_perfis set aprovado_em = criado_em where aprovado_em is null;


-- ----------------------------------------------------------------------------
-- 2. o gatilho de protecao passa a cobrir aprovado_em
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
  if (new.papel       is distinct from old.papel
   or new.ativo       is distinct from old.ativo
   or new.aprovado_em is distinct from old.aprovado_em
   or new.email       is distinct from old.email
   or new.user_id     is distinct from old.user_id)
     and not public.crm_e_gestor() then
    raise exception 'Somente um gestor pode mudar papel, situacao, aprovacao ou e-mail de um perfil.';
  end if;
  return new;
end;
$$;


-- ----------------------------------------------------------------------------
-- 3. crm_registrar(nome, papel) - a tela "Criar conta" chama logo apos o
--    signUp do Supabase, ja autenticada. Cria o perfil de quem chamou.
--
-- security definer: a tabela nao tem politica de INSERT para o navegador (de
-- proposito); so esta funcao e a chave de servico escrevem perfis novos.
-- Idempotente: se o perfil ja existe, so devolve.
-- ----------------------------------------------------------------------------
create or replace function public.crm_registrar(p_nome text, p_papel text)
returns public.crm_perfis
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid        uuid := auth.uid();
  v_email      text;
  v_nome       text;
  v_papel      text;
  v_tem_gestor boolean;
  v_perfil     public.crm_perfis;
begin
  if v_uid is null then
    raise exception 'Precisa estar autenticado para se cadastrar.';
  end if;

  select p.* into v_perfil from public.crm_perfis p where p.user_id = v_uid;
  if found then
    return v_perfil;
  end if;

  select lower(u.email) into v_email from auth.users u where u.id = v_uid;
  if v_email is null then
    raise exception 'Login sem e-mail.';
  end if;

  v_nome  := coalesce(nullif(trim(p_nome), ''), split_part(v_email, '@', 1));
  v_papel := case when p_papel in ('gestor', 'administrativo', 'corretor') then p_papel else 'corretor' end;

  select exists (select 1 from public.crm_perfis where papel = 'gestor' and ativo) into v_tem_gestor;

  if not v_tem_gestor then
    -- o primeiro: gestor na hora
    insert into public.crm_perfis (user_id, nome, email, papel, ativo, senha_definida, aprovado_em)
         values (v_uid, v_nome, v_email, 'gestor', true, true, now())
      returning * into v_perfil;
  else
    -- os seguintes: com o nivel pedido, aguardando um gestor aprovar
    insert into public.crm_perfis (user_id, nome, email, papel, ativo, senha_definida, aprovado_em)
         values (v_uid, v_nome, v_email, v_papel, false, true, null)
      returning * into v_perfil;
  end if;

  return v_perfil;
end;
$$;

revoke all on function public.crm_registrar(text, text) from public, anon;
grant execute on function public.crm_registrar(text, text) to authenticated;


-- ----------------------------------------------------------------------------
-- 4. crm_promover_gestor tambem marca a aprovacao
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
    return 'Nao achei nenhum login com o e-mail ' || p_email || '. Crie a conta em Authentication > Users ou pela tela Criar conta do CRM.';
  end if;

  insert into public.crm_perfis (user_id, nome, email, papel, ativo, senha_definida, aprovado_em)
       values (v_uid, v_nome, lower(trim(p_email)), 'gestor', true, true, now())
  on conflict (user_id) do update
        set papel = 'gestor', ativo = true, senha_definida = true, aprovado_em = coalesce(public.crm_perfis.aprovado_em, now());

  return 'Pronto: ' || p_email || ' e gestor do CRM.';
end;
$$;

revoke all on function public.crm_promover_gestor(text) from public, anon, authenticated;
