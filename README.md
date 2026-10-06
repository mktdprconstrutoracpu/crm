# CRM DPR

CRM da DPR Construtora: leads, funil de vendas do Minha Casa, Minha Vida,
estoque de unidades, corretores, fila de atendimento e relatorios. Feito pela
ereio a partir de outubro de 2026, no mesmo padrao do Central DPR (portal do
cliente): uma pagina, funcoes na pasta `api/`, banco e login no Supabase, sem
etapa de build, publicado pela Vercel.

Este e o commit inicial. O conteudo entra por etapas, cada uma numa branch
propria com preview antes de chegar aqui na `main`:

1. Base: banco, login, perfis, empreendimentos, unidades e equipe.
2. Leads e funil (kanban e lista).
3. Fila de atendimento, alertas e app no celular.
4. Follow-up, tarefas, modelos de WhatsApp e documentos do financiamento.
5. Ranking, painel do gestor e relatorios.
6. Facebook Lead Ads, webhooks e ponte com o Central DPR.
