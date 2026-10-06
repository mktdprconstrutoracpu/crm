# CRM DPR

CRM da DPR Construtora: leads, funil de vendas do Minha Casa, Minha Vida,
estoque de unidades, corretores, fila de atendimento e relatorios. Feito pela
ereio a partir de outubro de 2026, no mesmo padrao do Central DPR (portal do
cliente): uma pagina (`index.html`), funcoes na pasta `api/`, banco e login no
Supabase, sem etapa de build, publicado pela Vercel.

## Etapas

1. **Base** (esta): banco, login, perfis, empreendimentos, unidades e equipe.
2. Leads e funil (kanban e lista), com o chat do site da DPR entrando como origem.
3. Fila de atendimento, alertas de lead novo e app no celular (PWA).
4. Follow-up, tarefas, modelos de WhatsApp e documentos do financiamento.
5. Ranking de corretores, painel do gestor e relatorios.
6. Facebook Lead Ads, webhooks e ponte com o Central DPR (contrato assinado
   vira unidade e comprador no portal).

## O que a etapa 1 tem

| Tela | O que faz |
|---|---|
| Entrar | E-mail e senha do Supabase; "Esqueci a senha" manda o link de recuperacao |
| Criar a senha | Quem chega pelo link do convite cria a senha antes de entrar |
| Sem acesso | Login que existe mas nao esta na equipe (um cliente do portal, por exemplo) ve so esta tela |
| Inicio | Resumo: empreendimentos ativos, unidades disponiveis, reservadas, vendidas, pessoas na equipe |
| Empreendimentos | Lista e cadastro (nome, cidade, UF, tipo, programa, status, observacoes), com a contagem de unidades por status |
| Unidades | O espelho de vendas: uma peca por unidade, cor por status; filtro por empreendimento e status; cadastro de uma ou de varias de uma vez (CASA 01 a CASA 20) |
| Equipe | Quem usa o CRM e com que papel; o gestor convida por e-mail, troca o papel e desativa (nunca apaga) |

### Papeis

| Papel | Pode |
|---|---|
| gestor | tudo: convida, troca papel, desativa, edita empreendimentos e unidades |
| administrativo | edita empreendimentos e unidades |
| corretor | ve empreendimentos e unidades; nao edita (as proximas etapas dao a ele os leads dele) |

As travas valem **no banco** (RLS em `sql/001_base.sql`), nao so na tela.
Ninguem se promove: um gatilho barra mudanca de papel ou situacao que nao
venha de um gestor.

## Como colocar no ar

### 1. Banco (Supabase, o mesmo projeto do Central DPR)

Supabase > SQL Editor > New query > colar `sql/001_base.sql` inteiro > Run.
Pode rodar mais de uma vez. Todas as tabelas comecam com `crm_`; nada do
portal do cliente e tocado.

Depois, o primeiro gestor:

1. Authentication > Users > Add user (e-mail e senha), ou use um login que ja
   existe.
2. No SQL Editor: `select public.crm_promover_gestor('email@da.pessoa');`

A partir dai, todo mundo entra por convite, na tela Equipe.

### 2. Supabase > Authentication > URL Configuration

Em **Redirect URLs**, adicione o endereco do CRM (o da Vercel e, depois, o
dominio). Sem isso o link do convite e o de "esqueci a senha" nao voltam para
o CRM.

### 3. Vercel

Importar o repositorio `crm` como projeto novo (Framework Preset: Other, sem
Build Command). Em Settings > Environment Variables, para Production e Preview,
nunca marcadas como publicas:

| Nome | Valor |
|---|---|
| `SUPABASE_URL` | `https://roashkfdjgsweuftqhyx.supabase.co` (o mesmo do Central) |
| `SUPABASE_SERVICE_KEY` | a chave de **servico** do Supabase (`sb_secret_...`), em Settings > API keys |
| `CRM_URL` | o endereco do CRM, para o link do convite voltar para ca (ex.: `https://crm-dpr.vercel.app`) |

Variavel nova so vale no proximo deploy: depois de salvar, Redeploy.

A chave publicavel (`sb_publishable_...`) esta no `index.html` de proposito:
ela e feita para o navegador e, sem login, nao abre nada.

## Como funciona por dentro

- `index.html`: HTML, CSS e script num arquivo so. Navegacao por `#ancora`
  (inicio, empreendimentos, unidades, equipe). O script le o perfil de quem
  entrou e esconde o que a pessoa nao pode fazer; a trava de verdade e o RLS.
- `api/convidar.js`: so um gestor chama (o token de quem esta logado vai no
  cabecalho). Confere o token, confere o papel, manda o convite do Supabase e
  grava o perfil. Se o e-mail ja tem login (cliente do portal), nao manda
  convite: so cria o perfil, e a pessoa entra com a senha que ja tem.
- `sql/001_base.sql`: tabelas `crm_perfis`, `crm_empreendimentos`,
  `crm_unidades`; funcoes `crm_papel()`, `crm_tem_acesso()`, `crm_e_equipe()`,
  `crm_e_gestor()` (usadas pelas politicas); gatilhos de `atualizado_em` e de
  protecao do perfil; `crm_promover_gestor(email)` para o primeiro gestor.

## Conferencia antes de cada commit

- DOM falso (jsdom) com um Supabase de mentira: entrar, senha errada, convite
  obrigando a criar senha, login sem perfil, cada papel vendo o que deve,
  cadastro de empreendimento e de unidades (uma e em lote), equipe (convite
  pela funcao, troca de papel, desativar).
- Funcao `api/convidar.js` com pedidos e Supabase falsos: metodo, token
  invalido, nao gestor, e-mail repetido, convite ok, e-mail que ja tinha login.
- Navegador (puppeteer) em 1440 e 390 com o Supabase de mentira servido no
  lugar do CDN: telas fotografadas, nada vazando, toque de 44px.

## Decisoes registradas

- **Mesmo Supabase do Central DPR**, com prefixo `crm_`: a ponte da etapa 6
  vira uma consulta, e ha um banco so para administrar. Decisao dela em
  06/10/2026.
- **Nada entra direto na `main`**: cada etapa em branch propria, preview na
  Vercel, merge com aprovacao.
- **Quem sai fica inativo**, nunca e apagado: o historico de leads e vendas
  precisa continuar apontando para a pessoa.
- **Fim de linha LF** forcado pelo `.gitattributes`.
