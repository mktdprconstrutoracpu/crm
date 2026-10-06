// ============================================================================
// /api/convidar -- um gestor convida alguem para o CRM.
//
// Quem chama: a tela Equipe do CRM, com o token de quem esta logado no
// cabecalho Authorization. O corpo e { nome, email, papel, telefone }.
//
// O que faz, na ordem:
//   1. confere que o token e de um usuario de verdade (pergunta ao Supabase);
//   2. confere que esse usuario e GESTOR ativo no crm_perfis;
//   3. manda o convite do Supabase para o e-mail (a pessoa recebe um link,
//      cai no CRM e cria a senha). Se o e-mail ja tem conta (um cliente do
//      portal, por exemplo), nao manda convite: so cria o perfil, e a pessoa
//      entra com a senha que ja tem;
//   4. grava o perfil em crm_perfis com o papel pedido.
//
// POR QUE UMA FUNCAO, e nao o navegador direto: convidar cria um login, e isso
// exige a chave de SERVICO do Supabase, que passa por cima de todas as travas.
// Ela fica so aqui, na Vercel. O navegador tem a chave publicavel, que nao
// serve para isso.
//
// Variaveis de ambiente (Vercel, Production e Preview, nunca publicas):
//   SUPABASE_URL          https://xxxx.supabase.co  (o mesmo do Central DPR)
//   SUPABASE_SERVICE_KEY  a chave de servico (sb_secret_... / service_role)
//   CRM_URL               opcional: endereco do CRM, para o link do convite
//                         voltar para ca (ex.: https://crm-dpr.vercel.app)
// ============================================================================
'use strict';

const SUPABASE_URL = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const SUPABASE_SERVICE_KEY = String(process.env.SUPABASE_SERVICE_KEY || '');
const CRM_URL = String(process.env.CRM_URL || '').replace(/\/+$/, '');
const PAPEIS = new Set(['gestor', 'administrativo', 'corretor']);
const TEMPO_LIMITE = 9000;

function sinal() {
  return typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function' ? AbortSignal.timeout(TEMPO_LIMITE) : undefined;
}
function cabecalhosServico(extra) {
  return Object.assign({ apikey: SUPABASE_SERVICE_KEY, Authorization: 'Bearer ' + SUPABASE_SERVICE_KEY, 'Content-Type': 'application/json' }, extra || {});
}
async function lerJson(resposta) {
  const texto = await resposta.text();
  try { return texto ? JSON.parse(texto) : null; } catch (e) { return { bruto: texto.slice(0, 200) }; }
}
function emailValido(e) { return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e) && e.length <= 160; }

// 1. de quem e o token
async function usuarioDoToken(token) {
  const r = await fetch(SUPABASE_URL + '/auth/v1/user', { headers: { apikey: SUPABASE_SERVICE_KEY, Authorization: 'Bearer ' + token }, signal: sinal() });
  if (!r.ok) return null;
  const u = await lerJson(r);
  return u && u.id ? u : null;
}
// 2. o perfil dele no CRM
async function perfilDe(userId) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/crm_perfis?user_id=eq.' + encodeURIComponent(userId) + '&select=papel,ativo,nome', { headers: cabecalhosServico(), signal: sinal() });
  if (!r.ok) return null;
  const lista = await lerJson(r);
  return Array.isArray(lista) && lista[0] ? lista[0] : null;
}
async function perfilPorEmail(email) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/crm_perfis?email=ilike.' + encodeURIComponent(email) + '&select=user_id,nome,papel,ativo', { headers: cabecalhosServico(), signal: sinal() });
  if (!r.ok) return null;
  const lista = await lerJson(r);
  return Array.isArray(lista) && lista[0] ? lista[0] : null;
}
// 3. o convite (ou o login que ja existe)
async function convidar(email, nome) {
  const url = SUPABASE_URL + '/auth/v1/invite' + (CRM_URL ? '?redirect_to=' + encodeURIComponent(CRM_URL + '/') : '');
  const r = await fetch(url, { method: 'POST', headers: cabecalhosServico(), body: JSON.stringify({ email, data: { nome } }), signal: sinal() });
  const corpo = await lerJson(r);
  if (r.ok && corpo && corpo.id) return { userId: corpo.id, convidado: true };
  // 422 / "already been registered": a pessoa ja tem login (cliente do portal, ou ja foi convidada)
  const msg = JSON.stringify(corpo || {}).toLowerCase();
  if (r.status === 422 || /already|registered|exists/.test(msg)) {
    const existente = await usuarioPorEmail(email);
    if (existente) return { userId: existente.id, convidado: false, jaTinhaSenha: !!existente.last_sign_in_at || !existente.invited_at };
  }
  const erro = new Error('O Supabase nao aceitou o convite (' + r.status + '): ' + msg.slice(0, 160));
  erro.status = 502;
  throw erro;
}
async function usuarioPorEmail(email) {
  // a API de administracao lista por pagina; a base e pequena, entao basta procurar
  for (let pagina = 1; pagina <= 10; pagina++) {
    const r = await fetch(SUPABASE_URL + '/auth/v1/admin/users?page=' + pagina + '&per_page=200', { headers: cabecalhosServico(), signal: sinal() });
    if (!r.ok) return null;
    const corpo = await lerJson(r);
    const lista = Array.isArray(corpo) ? corpo : (corpo && corpo.users) || [];
    const achado = lista.find((u) => String(u.email || '').toLowerCase() === email);
    if (achado) return achado;
    if (lista.length < 200) break;
  }
  return null;
}
// 4. o perfil
async function gravarPerfil(perfil) {
  const r = await fetch(SUPABASE_URL + '/rest/v1/crm_perfis?on_conflict=user_id', { method: 'POST', headers: cabecalhosServico({ Prefer: 'resolution=merge-duplicates,return=representation' }), body: JSON.stringify(perfil), signal: sinal() });
  if (!r.ok) {
    const corpo = await lerJson(r);
    const erro = new Error('Nao consegui gravar o perfil (' + r.status + '): ' + JSON.stringify(corpo || {}).slice(0, 160));
    erro.status = 502;
    throw erro;
  }
  return true;
}

module.exports = async function (req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return res.status(405).json({ ok: false, motivo: 'metodo' }); }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) return res.status(500).json({ ok: false, motivo: 'servidor sem SUPABASE_URL ou SUPABASE_SERVICE_KEY' });

  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '').trim();
  if (!token) return res.status(401).json({ ok: false, motivo: 'sem login' });

  let corpo = req.body;
  if (typeof corpo === 'string') { try { corpo = JSON.parse(corpo); } catch (e) { corpo = null; } }
  if (!corpo || typeof corpo !== 'object') return res.status(400).json({ ok: false, motivo: 'corpo' });

  const nome = String(corpo.nome || '').trim().slice(0, 120);
  const email = String(corpo.email || '').trim().toLowerCase();
  const papel = String(corpo.papel || 'corretor').trim();
  const telefone = String(corpo.telefone || '').replace(/\D/g, '').slice(0, 13) || null;
  if (nome.length < 2) return res.status(400).json({ ok: false, motivo: 'nome' });
  if (!emailValido(email)) return res.status(400).json({ ok: false, motivo: 'email' });
  if (!PAPEIS.has(papel)) return res.status(400).json({ ok: false, motivo: 'papel' });

  try {
    const quem = await usuarioDoToken(token);
    if (!quem) return res.status(401).json({ ok: false, motivo: 'login invalido' });
    const perfil = await perfilDe(quem.id);
    if (!perfil || !perfil.ativo || perfil.papel !== 'gestor') return res.status(403).json({ ok: false, motivo: 'so gestor convida' });

    const jaNoCrm = await perfilPorEmail(email);
    if (jaNoCrm) return res.status(409).json({ ok: false, motivo: 'ja esta na equipe', nome: jaNoCrm.nome, ativo: jaNoCrm.ativo });

    const resultado = await convidar(email, nome);
    // quem e convidado por um gestor ja entra aprovado (aprovado_em): a aprovacao e o proprio convite
    await gravarPerfil({ user_id: resultado.userId, nome, email, telefone, papel, ativo: true, senha_definida: resultado.convidado ? false : !!resultado.jaTinhaSenha, aprovado_em: new Date().toISOString() });
    return res.status(200).json({ ok: true, convidado: resultado.convidado, jaTinhaConta: !resultado.convidado, papel });
  } catch (e) {
    console.error('convidar:', e && e.message);
    return res.status(e && e.status ? e.status : 500).json({ ok: false, motivo: String((e && e.message) || e).slice(0, 200) });
  }
};
