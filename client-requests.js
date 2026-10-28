const statuses={received:'Received',in_review:'Under review',information_required:'Additional information required',quoted:'Quote available',closed:'Closed'};
const fertilizers=new Set(['Naphtha','Automotive Grade Urea (AGU)','Bitumen','Calcium Ammonium Nitrate (CAN)','Urea 46%','Diammonium Phosphate (DAP)','Nitrogen Phosphorus Potassium (NPK)','Rock Phosphate','Sulphur']);
const node=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n};
export async function loadClientRequests({db,member}){
 const list=document.getElementById('file-requests-list'),status=document.getElementById('file-requests-status'),refresh=document.getElementById('file-requests-refresh');
 if(!list||!status||!refresh)return;
 const load=async()=>{
  refresh.disabled=true;status.textContent='Loading requests…';
  try{
   const result=await db.from('portal_quote_requests').select('*').eq('recipient',member.user_id).order('created_at',{ascending:false}).limit(100);
   if(result.error)throw result.error;
   const cards=[];
   for(const q of result.data){
    const t=q.transaction||{},details=q.details||{},card=node('article',undefined,'file-row');
    card.append(node('span',statuses[q.status]||q.status,'tag'),node('h3',q.reference),node('p',fertilizers.has(t.product)?'Fertilizers & Feedstocks':t.kind==='marine'?'Marine Chartering':t.kind==='crude'?'Crude Oils':'Performance Fluids'));
    const rows=[['Product / vessel',t.product],['Quantity',[t.quantity,t.unit].filter(Boolean).join(' ')],['Delivery basis',t.basis],['Frequency',t.frequency],['Cargo',t.cargo],['Port of loading',t.loading],['Destination / discharge',t.destination],['Requested date / laycan start',t.delivery],['Laycan end',t.laycan_end],['Charter type',t.charter],['Additional information',t.notes],['Company',details.B_COMPANY],['Contact',details.B_REPRESENTATIVE],['Email',q.email],['Phone',details.B_PHONE]];
    for(const [label,value] of rows){if(!value)continue;const p=node('p');p.append(node('strong',label+': '),document.createTextNode(String(value)));card.append(p)}
    card.append(node('p','Submitted '+new Intl.DateTimeFormat('en-GB',{dateStyle:'medium',timeStyle:'short',timeZone:'Europe/Amsterdam'}).format(new Date(q.created_at))+' · Amsterdam time','meta'));cards.push(card);
   }
   list.replaceChildren(...cards);status.textContent=cards.length?'':'No requests yet.';
  }catch(error){list.replaceChildren();status.textContent='Unable to load your requests. Please refresh or contact info@nexint.eu.';}
  finally{refresh.disabled=false;}
 };
 refresh.onclick=load;await load();
}
