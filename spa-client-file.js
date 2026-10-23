const checked=r=>{if(r.error)throw r.error;return r.data};
const el=(t,s,c)=>{const n=document.createElement(t);if(s!==undefined)n.textContent=s;if(c)n.className=c;return n};
const status={draft:'Draft',awaiting_client:'Awaiting client signature',awaiting_approval:'Awaiting Nexora approval',completed:'Completed',cancelled:'Cancelled'};
function card(a){const row=el('div',undefined,'file-row');row.append(el('strong',a.data.title||'SPA'),el('span',a.transaction_code+' · Version '+a.version+' · '+(status[a.status]||a.status),'meta'));const link=el('a','Open SPA','button secondary');link.href='spa-agreements.html?agreement='+encodeURIComponent(a.id);row.append(link);return row}
export async function loadSPAClientSummary({db,member,tasks,list,basePending}){
 const rows=checked(await db.from('spa_agreements').select('id,transaction_code,status,version,data').eq('recipient',member.user_id).neq('status','draft').order('created_at',{ascending:false}));
 const total=basePending+rows.filter(a=>a.status==='awaiting_client').length;tasks.replaceChildren(el('p',total?total+' agreement(s) awaiting your action.':'No agreements currently require your signature.'));
 const head=el('h3','SPAs');list.append(head);for(const a of rows)list.append(card(a));if(!rows.length)list.append(el('p','No SPA has been assigned to you.','file-empty'));const blank=el('a','Blank SPA','button secondary');blank.href='spa-agreements.html';list.append(blank);
}
export async function mountSPAAdmin({db,clientId,section,overview,createAfter}){
 const rows=checked(await db.from('spa_agreements').select('id,transaction_code,status,version,data').eq('recipient',clientId).order('created_at',{ascending:false}));
 const panel=el('section',undefined,'panel');panel.append(el('h2','SPAs'));for(const a of rows)panel.append(card(a));if(!rows.length)panel.append(el('p','No SPA assigned to this client.'));section.append(panel);
 const link=el('a','Create / manage SPA','button secondary');link.href='spa-agreements.html?client='+encodeURIComponent(clientId);createAfter.after(link);
 const pending=rows.filter(a=>!['completed','cancelled'].includes(a.status)).length;const text=overview.querySelector('section:nth-child(2) p');if(text)text.textContent+=' · '+pending+' open SPAs';
}
