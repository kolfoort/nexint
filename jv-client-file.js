const checked=r=>{if(r.error)throw r.error;return r.data};
const el=(t,s,c)=>{const n=document.createElement(t);if(s!==undefined)n.textContent=s;if(c)n.className=c;return n};
const status={draft:'Draft',awaiting_client:'Awaiting Party B signature',awaiting_approval:'Awaiting Nexora final approval',completed:'Completed',cancelled:'Cancelled'};
function card(a){const row=el('div',undefined,'file-row');row.append(el('strong',a.data.title||'Joint Venture Agreement'),el('span',a.transaction_code+' · Version '+a.version+' · '+(status[a.status]||a.status),'meta'));if(a.data.a_percent&&a.data.b_percent)row.append(el('span','Nexora '+a.data.a_percent+'% / Party B '+a.data.b_percent+'%','meta'));const link=el('a','Open Joint Venture','button secondary');link.href='jv-agreements.html?agreement='+encodeURIComponent(a.id);row.append(link);return row}
export async function loadJVClientSummary({db,member,tasks,list}){
 const rows=checked(await db.from('jv_agreements').select('id,transaction_code,status,version,data').eq('recipient',member.user_id).neq('status','draft').order('created_at',{ascending:false}));
 const pending=rows.filter(a=>a.status==='awaiting_client').length;if(pending)tasks.append(el('p',pending+' Joint Venture Agreement(s) awaiting your signature.'));
 list.append(el('h3','Joint Venture Agreements'));for(const a of rows)list.append(card(a));if(!rows.length)list.append(el('p','No Joint Venture Agreement has been assigned to you.','file-empty'));
}
export async function mountJVAdmin({db,clientId,section,overview,createAfter}){
 const rows=checked(await db.from('jv_agreements').select('id,transaction_code,status,version,data').eq('recipient',clientId).order('created_at',{ascending:false}));
 const panel=el('section',undefined,'panel');panel.append(el('h2','Joint Venture Agreements'));for(const a of rows)panel.append(card(a));if(!rows.length)panel.append(el('p','No Joint Venture Agreement assigned to this client.'));section.append(panel);
 const link=el('a','Create / manage Joint Venture','button secondary');link.href='jv-agreements.html?client='+encodeURIComponent(clientId);createAfter.after(link);
 const pending=rows.filter(a=>!['completed','cancelled'].includes(a.status)).length;const text=overview.querySelector('section:nth-child(2) p');if(text)text.textContent+=' · '+pending+' open Joint Ventures';
}
