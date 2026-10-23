const checked=r=>{if(r.error)throw r.error;return r.data};
const el=(t,s,c)=>{const n=document.createElement(t);if(s!==undefined)n.textContent=s;if(c)n.className=c;return n};
const status={draft:'Draft',awaiting_client:'Awaiting client signature',awaiting_approval:'Awaiting Nexora approval',completed:'Completed',cancelled:'Cancelled'};
function card(a){const row=el('div',undefined,'file-row');row.append(el('strong',a.data.title||'FCO'),el('span',a.transaction_code+' · Version '+a.version+' · '+(status[a.status]||a.status),'meta'));const link=el('a','Open FCO','button secondary');link.href='fco-agreements.html?agreement='+encodeURIComponent(a.id);row.append(link);return row}
export async function loadFCOClientSummary({db,member,tasks,list,basePending}){
 const rows=checked(await db.from('fco_agreements').select('id,transaction_code,status,version,data').eq('recipient',member.user_id).neq('status','draft').order('created_at',{ascending:false}));
 const pending=rows.filter(a=>a.status==='awaiting_client').length;if(pending)tasks.append(el('p',pending+' FCO(s) awaiting your signature.'));
 const head=el('h3','FCO Petroleum');list.append(head);for(const a of rows)list.append(card(a));if(!rows.length)list.append(el('p','No FCO has been assigned to you.','file-empty'));
}
export async function mountFCOAdmin({db,clientId,section,overview,createAfter}){
 const rows=checked(await db.from('fco_agreements').select('id,transaction_code,status,version,data').eq('recipient',clientId).order('created_at',{ascending:false}));
 const panel=el('section',undefined,'panel');panel.append(el('h2','FCO Petroleum'));for(const a of rows)panel.append(card(a));if(!rows.length)panel.append(el('p','No FCO assigned to this client.'));section.append(panel);
 const link=el('a','Create / manage FCO','button secondary');link.href='fco-agreements.html?client='+encodeURIComponent(clientId);createAfter.after(link);
 const pending=rows.filter(a=>!['completed','cancelled'].includes(a.status)).length;const text=overview.querySelector('section:nth-child(2) p');if(text)text.textContent+=' · '+pending+' open FCOs';
}
