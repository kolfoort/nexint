import {getLanguage} from './portal-language.js?v=20261029-whatsapp1';
const copy={
 en:{heading:'Your MCNDA & JVA',open:'Open agreement',none:'No current shared agreement is available.',released:'Ready for your signature',review:'For review only',waiting:'Awaiting completion',completed:'Completed',action:'Agreement awaiting your action',profile:'Profile version'},
 es:{heading:'Sus acuerdos MCNDA y JVA',open:'Abrir acuerdo',none:'No hay ningún acuerdo compartido vigente.',released:'Listo para su firma',review:'Solo para revisión',waiting:'Pendiente de finalización',completed:'Completado',action:'Acuerdo pendiente de su acción',profile:'Versión del perfil'},
 nl:{heading:'Uw MCNDA en JVA',open:'Overeenkomst openen',none:'Er is geen actuele gedeelde overeenkomst beschikbaar.',released:'Klaar voor uw ondertekening',review:'Alleen ter inzage',waiting:'Wacht op afronding',completed:'Afgerond',action:'Overeenkomst wacht op uw actie',profile:'Profielversie'},
 de:{heading:'Ihre MCNDA und JVA',open:'Vereinbarung öffnen',none:'Keine aktuelle gemeinsame Vereinbarung verfügbar.',released:'Bereit für Ihre Unterschrift',review:'Nur zur Prüfung',waiting:'Abschluss ausstehend',completed:'Abgeschlossen',action:'Vereinbarung wartet auf Ihre Aktion',profile:'Profilversion'}
};
const MC='18c69eda-091d-4093-9615-f9f578f306ca',JV='34e218d8-ec15-49ae-8066-7816a08ff4ee';
export function currentSharedAgreements(rows){
 const latest=new Map();
 for(const v of [...rows].sort((a,b)=>b.revision-a.revision||String(b.created_at).localeCompare(String(a.created_at)))){
  if(!['draft_review','released','awaiting_bundle','completed'].includes(v.status))continue;
  if(!latest.has(v.thread_id||v.id))latest.set(v.thread_id||v.id,v);
 }
 const visible=[...latest.values()];
 return visible.filter(v=>v.id!==JV||visible.some(m=>m.id===MC&&m.status==='completed'));
}
export async function mountMultiMCNDAList({db,container,userId,admin=false,tasks}){
 if(!container)return;
 const t=copy[getLanguage()]||copy.en;
 const node=(tag,value,cls)=>{const n=document.createElement(tag);if(value!==undefined)n.textContent=value;if(cls)n.className=cls;return n};
 const checked=r=>{if(r.error)throw r.error;return r.data};
 container.querySelector('[data-multi-mcnda-list]')?.remove();tasks?.querySelector('[data-multi-mcnda-tasks]')?.remove();
 const partyRows=checked(await db.from('portal_mcnda_parties').select('version_id').eq('user_id',userId));
 const ids=[...new Set(partyRows.map(p=>p.version_id))];
 const versions=ids.length?checked(await db.from('portal_mcnda_versions').select('id,thread_id,revision,status,created_at,snapshot').in('id',ids).order('created_at',{ascending:false})):[];
 const rows=admin?versions:currentSharedAgreements(versions);
 if(!rows.length)return;
 const panel=node('section',undefined,'panel');panel.dataset.multiMcndaList='';panel.dataset.i18nSkip='';panel.append(node('h2',t.heading));
 const actionPanel=node('div');actionPanel.dataset.multiMcndaTasks='';actionPanel.dataset.i18nSkip='';
 for(const v of rows){
  const kind=v.snapshot?.document?.kind||'MCNDA',reference=v.snapshot?.document?.reference;
  const sourceRevision=v.snapshot?.document?.filename?.match(/-R(\d+)(?:-|\.)/i)?.[1];
  const label=kind+' · '+(getLanguage()==='es'?'Revisión':'Revision')+' '+(sourceRevision||v.revision);
  const status=v.status==='released'?t.released:v.status==='draft_review'?t.review:v.status==='completed'?t.completed:t.waiting;
  const card=node('div',undefined,'file-row');card.append(node('strong',label),node('span',status,'meta'));if(reference)card.append(node('span',reference,'meta'));
  const link=node('a',t.open,'button');link.href='mcnda-agreements.html?id='+encodeURIComponent(v.id);card.append(link);panel.append(card);
  if(tasks){const item=node('div',undefined,'file-row');item.append(node('strong',label),node('span',status,'meta'));const action=node('a',t.open,'button');action.href=link.href;item.append(action);actionPanel.append(item)}
 }
 container.prepend(panel);
 if(tasks){for(const n of [...tasks.querySelectorAll('p')])if(/No agreements currently require your signature\./.test(n.textContent))n.remove();tasks.prepend(actionPanel)}
 // These are empty legacy-form sections, not evidence of absent shared contracts.
 container.querySelectorAll('.file-empty').forEach(n=>{if(/No (legacy MCNDA|Joint Venture Agreement)/.test(n.textContent))n.remove()});
}
