// Agenda Inicial · ponte pelo Google
// Repassa a sincronização da agenda ao Supabase quando a rede bloqueia o supabase.co.
// Contém só o endereço e a chave PÚBLICA do Supabase; quem protege os dados é a chave pessoal enviada pela agenda.
var SB_URL = 'https://wkhlnthcfmacizhyotss.supabase.co';
var SB_KEY = 'sb_publishable_KF3D3TUFqRJ34wHWqNR5RQ_CMLVeUO0';

function doGet() {
  return saida({ ok: true, ponte: 'Agenda Inicial', versao: 1 });
}

function doPost(e) {
  try {
    var p = JSON.parse(e.postData.contents);
    if (p.op === 'ler') return saida({ ok: true, dados: rpc('agendainicial_ponte_ler', { p_chave: p.chave, p_desde: p.desde, p_limite: p.limite || 500 }) });
    if (p.op === 'gravar') return saida({ ok: true, dados: rpc('agendainicial_ponte_gravar', { p_chave: p.chave, p_itens: p.itens }) });
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
