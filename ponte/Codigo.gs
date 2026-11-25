// Agenda Inicial · ponte pelo Google
// Repassa a sincronização da agenda ao Supabase quando a rede bloqueia o supabase.co.
// Contém só o endereço e a chave PÚBLICA do Supabase; quem protege os dados é a chave pessoal enviada pela agenda.
var SB_URL = 'https://wkhlnthcfmacizhyotss.supabase.co';
var SB_KEY = 'sb_publishable_KF3D3TUFqRJ34wHWqNR5RQ_CMLVeUO0';

function doGet() {
  return saida({ ok: true, ponte: 'Agenda Inicial', versao: 3 });
}

function doPost(e) {
  try {
    var p = JSON.parse(e.postData.contents);
    if (p.op === 'ler') return saida({ ok: true, dados: rpc('agendainicial_ponte_ler', { p_chave: p.chave, p_desde: p.desde, p_limite: p.limite || 500 }) });
    if (p.op === 'gravar') return saida({ ok: true, dados: rpc('agendainicial_ponte_gravar', { p_chave: p.chave, p_itens: p.itens }) });
    // Funções novas da ponte (perfil, nuvem…): só as do grupo agendainicial_ponte_, sempre com a chave pessoal.
    if (p.op === 'rpc' && /^agendainicial_ponte_[a-z_]{1,40}$/.test(p.fn || '')) {
      var args = p.args || {}; args.p_chave = p.chave;
      return saida({ ok: true, dados: rpc(p.fn, args) });
    }
    // Acesso temporário ao OneDrive / Google Drive (função inicial-nuvem do Supabase), com a chave pessoal.
    if (p.op === 'nuvem') {
      var r = UrlFetchApp.fetch(SB_URL + '/functions/v1/inicial-nuvem', {
        method: 'post', contentType: 'application/json', muteHttpExceptions: true,
        headers: { apikey: SB_KEY }, payload: JSON.stringify({ chave: p.chave, provedor: p.provedor || '' })
      });
      var j = JSON.parse(r.getContentText() || '{}');
      return saida(j.ok ? { ok: true, dados: j } : { ok: false, erro: j.erro || ('erro ' + r.getResponseCode()) });
    }
    return saida({ ok: false, erro: 'operação desconhecida' });
  } catch (err) {
    return saida({ ok: false, erro: String(err && err.message || err) });
  }
}

function rpc(nome, corpo) {
  var r = UrlFetchApp.fetch(SB_URL + '/rest/v1/rpc/' + nome, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: SB_KEY }, payload: JSON.stringify(corpo)
  });
  var txt = r.getContentText(), cod = r.getResponseCode();
  var j = txt ? JSON.parse(txt) : null;
  if (cod >= 300) throw new Error((j && (j.message || j.hint)) || ('erro ' + cod));
  return j;
}

function saida(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
