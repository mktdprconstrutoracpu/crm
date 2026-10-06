// ============================================================================
// /api/entrada -- o assistente do site da DPR (chat-dpr.js -> api/lead.js, no
// repositorio siteDPR) manda para ca o WhatsApp da pessoa e as dez respostas.
// Aqui o lead entra no funil, na primeira etapa, com as respostas guardadas.
//
// COMO LIGAR (do lado do site nao muda codigo, so variaveis na Vercel dele):
//   LEAD_WEBHOOK_URL      https://<endereco do CRM>/api/entrada
//   LEAD_WEBHOOK_SEGREDO  a mesma senha que esta aqui em LEAD_SEGREDO
// O site ja manda { telefone, respostas: [{ resumo, valor }], pagina, ... }
// com o cabecalho x-lead-segredo.
//
// O QUE FAZ: confere o segredo (comparacao em tempo constante), confere o
// telefone, procura um lead com esse WhatsApp. Se ja existe, atualiza as
// respostas e anota "passou de novo pelo site" na linha do tempo. Se nao,
// cria o lead em "Novo" com origem site_chat; o gatilho do banco grava o
// evento de criacao. Responde { ok, leadId, novo }.
//
// Variaveis de ambiente (Vercel, nunca publicas):
//   SUPABASE_URL, SUPABASE_SERVICE_KEY  os mesmos de api/convidar.js
//   LEAD_SEGREDO                        senha combinada com o site
// ============================================================================
'use strict';

const SUPABASE_URL = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const SUPABASE_SERVICE_KEY = String(process.env.SUPABASE_SERVICE_KEY || '');
const LEAD_SEGREDO = String(process.env.LEAD_SEGREDO || '');
const TEMPO_LIMITE = 9000;

function sinal() { return typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function' ? AbortSignal.timeout(TEMPO_LIMITE) : undefined; }
function cabecalhos(extra) { return Object.assign({ apikey: SUPABASE_SERVICE_KEY, Authorization: 'Bearer ' + SUPABASE_SERVICE_KEY, 'Content-Type': 'application/json' }, extra || {}); }
async function lerJson(r) { const t = await r.text(); try { return t ? JSON.parse(t) : null; } catch (e) { return { bruto: t.slice(0, 200) }; } }

// um "===" vaza pelo tempo quantos caracteres do comeco estao certos
function segredoConfere(recebido, esperado) {
  const a = String(recebido || ''), b = String(esperado || '');
  if (!b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
function somenteDigitos(s) { return String(s || '').replace(/\D/g, ''); }

async function supabase(caminho, opcoes) {
  const r = await fetch(SUPABASE_URL + '/rest/v1' + caminho, Object.assign({}, opcoes || {}, { headers: cabecalhos((opcoes && opcoes.headers) || {}), signal: sinal() }));
  const corpo = await lerJson(r);
  if (!r.ok) { const e = new Error('Supabase ' + r.status + ' em ' + caminho + ': ' + JSON.stringify(corpo || {}).slice(0, 160)); e.status = 502; throw e; }
  return corpo;
}

module.exports = async function (req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return res.status(405).json({ ok: false, motivo: 'metodo' }); }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) return res.status(500).json({ ok: false, motivo: 'servidor sem SUPABASE_URL ou SUPABASE_SERVICE_KEY' });
  if (!LEAD_SEGREDO) return res.status(500).json({ ok: false, motivo: 'servidor sem LEAD_SEGREDO' });
  if (!segredoConfere(req.headers['x-lead-segredo'], LEAD_SEGREDO)) return res.status(401).json({ ok: false, motivo: 'segredo' });

  let corpo = req.body;
  if (typeof corpo === 'string') { try { corpo = JSON.parse(corpo); } catch (e) { corpo = null; } }
  if (!corpo || typeof corpo !== 'object') return res.status(400).json({ ok: false, motivo: 'corpo' });

  const telefone = somenteDigitos(corpo.telefone);
  if (!/^55[1-9][1-9](9\d{8}|\d{8})$/.test(telefone)) return res.status(400).json({ ok: false, motivo: 'telefone' });
  const nome = String(corpo.nome || '').trim().slice(0, 120) || 'Lead do site';
  const email = String(corpo.email || '').trim().toLowerCase().slice(0, 160) || null;
  const pagina = String(corpo.pagina || '').slice(0, 300) || null;
  const respostas = Array.isArray(corpo.respostas)
    ? corpo.respostas.slice(0, 12).map((r) => ({ resumo: String((r && r.resumo) || '').slice(0, 80), valor: String((r && r.valor) || '').slice(0, 40) })).filter((r) => r.resumo && r.valor)
    : null;

  try {
    const existentes = await supabase('/crm_leads?telefone=eq.' + telefone + '&select=id,nome', {});
    if (Array.isArray(existentes) && existentes[0]) {
      const lead = existentes[0];
      const mudancas = { pagina_origem: pagina };
      if (respostas && respostas.length) mudancas.respostas_assistente = respostas;
      if (email) mudancas.email = email;
      await supabase('/crm_leads?id=eq.' + lead.id, { method: 'PATCH', body: JSON.stringify(mudancas), headers: { Prefer: 'return=minimal' } });
      await supabase('/crm_lead_eventos', { method: 'POST', body: JSON.stringify({ lead_id: lead.id, tipo: 'entrada_site', texto: 'Passou de novo pelo assistente do site' + (respostas && respostas.length ? ' e respondeu as perguntas' : '') }), headers: { Prefer: 'return=minimal' } });
      return res.status(200).json({ ok: true, leadId: lead.id, novo: false });
    }

    // a primeira etapa aberta, pela ordem
    const etapas = await supabase('/crm_etapas?tipo=eq.aberta&ativo=eq.true&select=id,nome&order=ordem.asc&limit=1', {});
    if (!Array.isArray(etapas) || !etapas[0]) return res.status(500).json({ ok: false, motivo: 'o funil nao tem etapa aberta; rode sql/003_leads.sql' });

    const criado = await supabase('/crm_leads', {
      method: 'POST',
      body: JSON.stringify({ nome, telefone, email, origem: 'site_chat', etapa_id: etapas[0].id, respostas_assistente: respostas && respostas.length ? respostas : null, pagina_origem: pagina }),
      headers: { Prefer: 'return=representation' }
    });
    const novo = Array.isArray(criado) ? criado[0] : criado;
    return res.status(200).json({ ok: true, leadId: novo && novo.id, novo: true });
  } catch (e) {
    console.error('entrada:', e && e.message);
    return res.status(e && e.status ? e.status : 500).json({ ok: false, motivo: String((e && e.message) || e).slice(0, 200) });
  }
};

module.exports.segredoConfere = segredoConfere;
