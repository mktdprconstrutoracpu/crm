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
| Criar conta | Nome, e-mail, senha e nivel. Grava o login no Supabase Auth e o perfil em `crm_perfis`. O **primeiro** cadastro vira gestor na hora; os seguintes ficam **aguardando aprovacao** de um gestor (ver abaixo) |
| Criar a senha | Quem chega pelo link do convite cria a senha antes de entrar |
| Sem acesso | Login que existe mas nao esta na equipe (um cliente do portal, por exemplo) ve so esta tela |
| Inicio | Resumo: empreendimentos ativos, unidades disponiveis, reservadas, vendidas, pessoas na equipe |
| Empreendimentos | Lista e cadastro (nome, cidade, UF, tipo, programa, status, observacoes), com a contagem de unidades por status |
| Unidades | O espelho de vendas: uma peca por unidade, cor por status; filtro por empreendimento e status; cadastro de uma ou de varias de uma vez (CASA 01 a CASA 20) |
| Equipe | Quem usa o CRM e com que papel; o gestor aprova ou recusa os cadastros novos (ajustando o nivel antes, se quiser), convida por e-mail, troca o papel e desativa (nunca apaga) |

### Cadastro e aprovacao

Qualquer pessoa com o endereco do CRM pode criar conta, mas **ninguem entra
sem um gestor liberar**: se o nivel escolhido valesse na hora, qualquer um
viraria gestor. O fluxo e:

1. A pessoa cria a conta (nome, e-mail, senha, nivel). O login nasce no
   Supabase Auth, com nome e nivel guardados nos dados do login.
2. Na primeira sessao, o CRM chama `crm_registrar` e o perfil nasce em
   `crm_perfis`: o primeiro de todos como gestor ativo; os demais com o nivel
   pedido, inativos e sem `aprovado_em`. A pessoa ve "Cadastro recebido".
3. O gestor ve o aviso no Inicio e na Equipe, confere o nivel, ajusta se
   precisar e toca em Aprovar (ou Recusar). Aprovado, a pessoa entra.

Quem e convidado pela tela Equipe ja nasce aprovado: o convite e a aprovacao.

### Separado do portal do cliente

O CRM e o Central DPR usam o **mesmo Supabase Auth** (mesmo projeto), mas os
usuarios sao separados pela tabela: so quem tem linha em `crm_perfis` entra no
CRM, e um cliente do portal que tentar entrar ve "sua conta nao tem acesso".
Um cadastro feito pelo CRM nao vira cliente do portal, e vice-versa. A senha
nunca e gravada em tabela nossa: fica no Supabase Auth, criptografada.

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

Supabase > SQL Editor > New query > colar `sql/001_base.sql` inteiro > Run;
depois o mesmo com `sql/002_registro.sql`. Pode rodar mais de uma vez. Todas
as tabelas comecam com `crm_`; nada do portal do cliente e tocado.

O primeiro gestor e **quem criar a primeira conta** na tela "Criar conta" do
CRM. Se precisar promover alguem a gestor por fora (socorro), no SQL Editor:
`select public.crm_promover_gestor('email@da.pessoa');`

A partir dai, todo mundo entra criando conta (e sendo aprovado) ou por
convite, na tela Equipe.

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
  protecao do perfil; `crm_promover_gestor(email)` para socorro.
- `sql/002_registro.sql`: coluna `aprovado_em` em `crm_perfis` (nulo e inativo
  = aguardando; cheio e inativo = desativado), funcao `crm_registrar(nome,
  papel)` chamada pela tela Criar conta, gatilho de protecao cobrindo a
  aprovacao.

## Conferencia antes de cada commit

- DOM falso (jsdom) com um Supabase de mentira: entrar, senha errada, convite
  obrigando a criar senha, login sem perfil, cada papel vendo o que deve,
  cadastro de empreendimento e de unidades (uma e em lote), equipe (convite
  pela funcao, troca de papel, desativar), criar conta (o primeiro vira
  gestor; o segundo aguarda e e aprovado; recusa; e-mail repetido; projeto
  com confirmacao por e-mail).
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
