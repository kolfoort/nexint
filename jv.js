import {ensurePortalSecurity} from './portal-security.js?v=20261029-multi1';
import {confirmAgreement,hashPDF} from './signing-confirmation.js?v=20261029-multi1';
import {initializeAccountLanguage} from './portal-language.js?v=20261029-multi1';
import {config as portalConfig} from './portal-config.js';
import {initSigningImages} from './signing-images.js?v=20261022-live2';
import {fields} from './jv-fields.js?v=20261027-jv1';
import {createJVPDF} from './jv-pdf.js?v=20261027-jvreview1';
let db,pdfUrl=null,reviewEvidence=null,signingProfile=null;
const templateCache=new Map();
const $=id=>document.getElementById(id);let config,profiles=[],me,items=[],current=null,tab='parties',dirty=false;
const labels={draft:'Draft',awaiting_client:'Awaiting client signature',awaiting_approval:'Awaiting Nexora signature',completed:'Completed',cancelled:'Cancelled'};
const E=(tag,text,cls)=>{let e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e};
function message(t){$('message').textContent=t;$('message').hidden=!t;if(t)$('message').scrollIntoView({behavior:'smooth',block:'nearest'})}
const checked=r=>{if(r.error)throw r.error;return r.data};
function adapt(a){return {...a,code:a.transaction_code,client_sign:a.data.client_signature||{},seller_sign:a.data.seller_signature||{}}}
async function api(path,data){
 if(path==='/api/profiles'){const links=checked(await db.from('portal_company_members').select('user_id,company_id'));const ids=[...new Set(links.map(x=>x.company_id))];const rows=ids.length?checked(await db.from('portal_companies').select('id,details,version,status').in('id',ids)):[];return links.map(l=>({...rows.find(c=>c.id===l.company_id),user_id:l.user_id})).filter(p=>p.id)}
 if(path==='/api/agreements'&&!data){let query=db.from('jv_agreements').select('*');const client=new URLSearchParams(location.search).get('client');if(me.role==='admin'&&client)query=query.eq('recipient',client);if(me.role==='client')query=query.eq('recipient',me.id);return checked(await query.order('created_at',{ascending:false})).map(adapt);}
 if(path==='/api/agreements'&&data){const id=checked(await db.rpc('jv_action',{p_action:'create',p_payload:data}));return {id}}
 const id=path.split('/')[3];
 if(path.endsWith('/audit'))return checked(await db.from('jv_events').select('actor_email,event,created_at').eq('agreement_id',id).order('created_at')).map(r=>({actor:r.actor_email,event:r.event,at:r.created_at}));
 if(data){const id=checked(await db.rpc('jv_action',{p_action:data.action,p_id:current.id,p_revision:data.revision,p_payload:data}));return {id}}
 throw Error('Unknown request');
}
async function act(fn){if(document.body.dataset.busy)return;document.body.dataset.busy='1';document.querySelectorAll('button').forEach(b=>b.disabled=true);try{await fn()}catch(e){message(e.message)}finally{delete document.body.dataset.busy;document.querySelectorAll('button').forEach(b=>b.disabled=false)}}
function button(text,fn,secondary=false){let b=E('button',text,secondary?'secondary':'');b.type='button';b.onclick=()=>act(fn);return b}
function field(key,label,type='text',options=null,wide=false){let l=E('label',label),el=E(options?'select':type==='textarea'?'textarea':'input');if(wide)l.className='wide';el.name=key;if(options)for(let [value,text] of options){let o=E('option',text);o.value=value;el.append(o)}else if(type!=='textarea')el.type=type;let isTech=key.startsWith('technical.');el.value=(isTech?current.data.technical?.[key.split('.')[1]]:current.data[key])??'';el.disabled=!(me.role==='admin'&&current.status==='draft')||['buyer','registration','buyer_address','buyer_country','representative','buyer_role','buyer_email'].includes(key);el.oninput=()=>{if(isTech){current.data.technical??={};current.data.technical[key.split('.')[1]]=el.value}else current.data[key]=el.value;dirty=true;reviewEvidence=null;closePreview();if(['a_percent','b_percent'].includes(key))updateAllocation()};l.append(el);return l}
function check(key,label,container,disabled=false){let l=E('label',undefined,'check'),i=E('input');i.type='checkbox';i.checked=!!current.data[key];i.disabled=disabled;i.onchange=()=>{current.data[key]=i.checked;dirty=true;reviewEvidence=null;closePreview()};l.append(i,E('span',label));container.append(l)}
function updateAllocation(){const e=$('allocation-total');if(e){const n=(Math.round(Number(current.data.a_percent)*100)+Math.round(Number(current.data.b_percent)*100))/100;e.textContent='Selected total: '+(Number.isFinite(n)?n.toFixed(2):'0.00')+'%'+(n===100?'':' - must equal 100%')}}
function closePreview(){$('preview').hidden=true;$('pdf').src='about:blank';if(pdfUrl){URL.revokeObjectURL(pdfUrl);pdfUrl=null}}
async function load(id=current?.id){profiles=await api('/api/profiles');items=await api('/api/agreements');current=items.find(a=>a.id===id)||items[0]||null;reviewEvidence=null;dirty=false;await render()}
async function render(){let list=$('list');list.replaceChildren();for(let a of items){let b=button('',async()=>{if(dirty&&!confirm('Discard unsaved changes?'))return;current=a;dirty=false;closePreview();render()});b.className='item'+(a.id===current?.id?' active':'');b.append(E('strong',a.code),E('small',('Joint Venture')+' · v'+a.version),E('small',a.status==='draft'&&a.data.draft_shared?'Draft assigned for review':labels[a.status]));list.append(b)}if(!items.length)list.append(E('p',me.role==='admin'?'Create your first draft.':'No JV has been assigned to your account.'));$('create-controls').hidden=me.role!=='admin';if($('admin-nav'))$('admin-nav').hidden=me.role!=='admin';$('detail').replaceChildren();if(!current){$('detail').append(E('div','Select an assigned JV or create a new draft.','empty'));return}
 let d=$('detail');if(current.status==='draft')d.append(E('p',current.data.draft_shared?'DRAFT ASSIGNED FOR REVIEW — read only. Signing is not enabled.':'PRIVATE DRAFT — not visible to the client.','info'));d.append(E('span',labels[current.status],'badge '+current.status),E('h2',current.data.title||'Joint Venture Agreement'),E('div',current.code+' · Version '+current.version+' · Assigned to '+(config.users.find(u=>u.id===current.recipient)?.email||current.data.buyer_email||'Assigned account'),'meta'));
 let steps=E('div',undefined,'stepper'),index=['draft','awaiting_client','awaiting_approval','completed'].indexOf(current.status);['1. Prepare','2. Client signs','3. Nexora signs','4. Final copy'].forEach((t,i)=>steps.append(E('span',t,i<=index?'done':'')));d.append(steps);
 const editable=me.role==='admin'&&current.status==='draft';
 let summary=E('div',undefined,'summary');for(const [label,value] of [['Nexora',current.data.a_percent?current.data.a_percent+'%':'Not selected'],['Party B',current.data.b_percent?current.data.b_percent+'%':'Not selected'],['Law','Dutch law / Amsterdam']]){const box=E('div');box.append(E('small',label),E('strong',value));summary.append(box)}d.append(summary);
 d.append(E('p','Party B signs the complete Agreement and both Schedules first. JP’s signature and Nexora stamp are withheld until Nexora reviews and gives final approval.','info'));
 const tabs=E('nav',undefined,'tabs');for(const [key,name] of [['parties','Parties'],['project','Project'],['financial','Profit & funding'],['operating','Schedules'],['review','Review & signatures']]){const b=button(name,()=>{tab=key;return render()});b.classList.toggle('active',tab===key);tabs.append(b)}d.append(tabs);const content=E('div'),grid=E('div',undefined,'grid');d.append(content);content.append(grid);
 if(tab==='parties'){
  grid.append(E('p','Party B details are taken from its approved portal company profile and frozen on assignment. Update and approve that profile before changing the contracting party.','wide'));
  for(const [k,l] of [['buyer','Party B legal company name'],['registration','Registration number'],['buyer_address','Registered address'],['buyer_country','Country'],['representative','Authorised representative'],['buyer_role','Title'],['buyer_email','Business email']])grid.append(field(k,l));
  grid.append(field('a_identity','Confirmed Nexora contracting identity / registration','textarea',null,true));
  if(editable)grid.append(button('Refresh Party B profile',async()=>{if(dirty)await save();await operation('sync_profile');message('Draft profile refreshed.')} ,true));
 }
 if(['project','financial','operating'].includes(tab)){
  for(const [key,label,group] of fields.filter(f=>f[2]===tab)){
   const numeric=['a_percent','b_percent','a_exposure','b_exposure','liability_cap','threshold'].includes(key),el=field(key,label,numeric?'number':key.endsWith('_email')?'email':'textarea',null,!numeric);
   if(numeric){const input=el.querySelector('input');input.step='0.01';input.min=key.includes('percent')?'0.01':'0';if(key.includes('percent'))input.max='99.99';}
   grid.append(el);
  }
  if(tab==='financial'){
   const total=E('p',undefined,'wide');total.id='allocation-total';grid.prepend(total);updateAllocation();
   grid.append(E('p','Both profit shares must be selected explicitly and total exactly 100%. Funding commitments, liability cap and payment threshold use the selected project currency. Losses are agreed separately.','wide'));
  }
  if(tab==='operating')grid.append(E('p','Complete every field. Use “None” or “Not applicable” only where genuinely applicable. Schedule B must identify each protected introduction or state None.','wide'));
 }
 if(tab==='review'){
  for(const [key,label] of [['identity_confirmed','Both contracting identities and representatives’ authority have been confirmed.'],['commercial_confirmed','The entire Agreement and Schedules A and B are complete; percentages, losses, funding and liability cap are expressly agreed.'],['bank_verified','The banking / escrow arrangements have been independently verified, or the schedule expressly states that no transfers are authorised before verification.']])check(key,label,grid,!editable);
 }
 if(tab==='review'){
  let info=E('div',undefined,'wide');info.append(E('h3','Signing order'),E('p','Party B first previews and signs the complete Agreement and both Schedules. Nexora then reviews that version and gives final approval. No automatic Nexora signature is applied when creating or assigning a draft.'));
  let ul=E('ul',undefined,'review-list');for(let t of ['Party B: '+(current.client_sign.name?current.client_sign.name+' · '+new Date(current.client_sign.at).toLocaleString():'Not signed'), 'Nexora: '+(current.seller_sign.at?'J.P. Kolfoort · '+new Date(current.seller_sign.at).toLocaleString():'Not signed')])ul.append(E('li',t));info.append(ul);grid.append(info);
  if((me.role==='client'&&current.status==='awaiting_client')||(me.role==='admin'&&current.status==='awaiting_approval')){let box=E('div',undefined,'wide');box.append(E('h3',me.role==='admin'?'Nexora final approval':'Accept and sign'));let lab=E('label','Type authorized representative’s full name'),input=E('input');input.id='sign-name';lab.append(input);box.append(lab,E('p','Expected name: '+(me.role==='admin'?'J.P. Kolfoort':current.data.representative),'help'));for(let [id,text] of [['authority','I am authorized to represent the named party.'],['accept','I reviewed and accept the complete Agreement and Schedules A and B, including the selected profit percentages and all commercial terms.'],['use_saved_assets','I authorize use of my saved signature and company stamp on this entire Agreement and both Schedules.']]){let l=E('label',undefined,'check'),i=E('input');i.type='checkbox';i.id='sign-'+id;l.append(i,E('span',text));box.append(l)}box.append(button(me.role==='admin'?'Approve, sign & release final PDF':'Sign Agreement & both Schedules',async()=>{if(await signOrApprove()===false)return;message(me.role==='admin'?'Final signed JV released. The stored PDF is locked.':'JV signed and submitted. Nexora must now review and countersign.')}));grid.append(box)}
  let audits=E('div',undefined,'wide');audits.append(E('h3','Activity record'));grid.append(audits);api('/api/agreements/'+current.id+'/audit').then(rows=>{for(let a of rows){let r=E('div',undefined,'audit');r.append(E('strong',a.event),E('small',a.actor+' · '+new Date(a.at).toLocaleString()));audits.append(r)}}).catch(e=>message(e.message));
 }
 if(me.role==='client'&&current.status==='awaiting_client'&&tab==='review'){let assets=E('div',undefined,'wide');content.append(assets);signingProfile=await initSigningImages({db,container:assets,message,onChange:()=>{reviewEvidence=null;closePreview()}})}
 let actions=E('div',undefined,'actions');if(editable){actions.append(button(current.data.draft_shared?'Withdraw draft review access':'Assign draft for review',async()=>{const wasShared=!!current.data.draft_shared;if(dirty)await save();await operation(wasShared?'unshare_draft':'share_draft');message(wasShared?'Draft review access withdrawn.':'Draft assigned for read-only review. The client cannot sign until you release it for signature.');},true));actions.append(button('Save draft',save),button('Release for client signature',async()=>{if(dirty)await save();await operation('issue');tab='review';render();message('Assigned. Party B can review and sign the complete Agreement and both Schedules in its client file.')}))}
 actions.append(button(current.status==='completed'?'View final signed PDF':'Preview JV',async()=>{if(dirty){if(!editable)throw Error('Reload the agreement');await save()}await previewJV()},true));
 if(me.role==='admin'&&!['completed','cancelled'].includes(current.status))actions.append(button('Cancel JV',async()=>{if(confirm('Cancel this unsigned JV? Its audit history will be retained.'))await operation('cancel')},true));
 if(me.role==='admin'&&current.status!=='draft')actions.append(button('Create new version',async()=>{let v=await api('/api/agreements/'+current.id+'/action',{action:'revise',revision:current.revision});closePreview();await load(v.id);tab='parties';render();message('New draft version created. Previous version preserved; new acceptance is required.')},true));
 content.append(actions);if(current.status==='completed')content.append(E('p','Final PDF SHA256: '+current.data.pdf_sha256,'meta')); 
}
async function save(){let id=current.id;await api('/api/agreements/'+id+'/action',{action:'save',revision:current.revision,data:current.data});await load(id);message('Draft saved privately. Assign it for review again if the client should see the revised draft.')}
async function operation(action,extra={}){let id=current.id;let v=await api('/api/agreements/'+id+'/action',{action,revision:current.revision,...extra});closePreview();await load(v.id||id)}

async function getTemplate(){if(!templateCache.has(current.template_version))templateCache.set(current.template_version,checked(await db.from('jv_templates').select('*').eq('version',current.template_version).single()));return templateCache.get(current.template_version)}
async function previewJV(){
 const id=current.id,revision=current.revision;let bytes;
 if(current.status==='completed'){const row=checked(await db.from('jv_final_pdfs').select('pdf_base64,pdf_sha256').eq('agreement_id',id).single());bytes=Uint8Array.from(atob(row.pdf_base64),c=>c.charCodeAt(0))}
 else{let assets=null;if(me.role==='client'&&current.status==='awaiting_client'){assets=signingProfile?.get();if(!assets?.signature||!assets?.stamp)throw Error('Open Review & signatures, save your private signature and stamp, then preview the JV.')}const proof=checked(await db.rpc('jv_review',{p_id:id,p_revision:revision,p_asset_version:assets?.version||null}));bytes=await createJVPDF(current,await getTemplate(),null,assets,proof);if(current.id!==id||current.revision!==revision)throw Error('Agreement changed; review again.');const pdfHash=await hashPDF(bytes);if(current?.id!==id||current.revision!==revision)throw Error('Document changed; preview again.');reviewEvidence={...proof,pdfHash}}
 closePreview();pdfUrl=URL.createObjectURL(new Blob([bytes],{type:'application/pdf'}));$('pdf').src=pdfUrl;$('download').href=pdfUrl;$('download').target='_blank';$('download').rel='noopener';$('preview').hidden=false;$('preview').scrollIntoView({behavior:'smooth'});
}
async function signOrApprove(){
 if(!reviewEvidence||reviewEvidence.revision!==current.revision)throw Error('Preview the complete Agreement and both Schedules after your last change, then confirm and sign.');
 if(!$('sign-authority').checked||!$('sign-accept').checked||!$('sign-use_saved_assets').checked)throw Error('Confirm authority, agreement and use of signing images.');
 const expected=me.role==='admin'?'J.P. Kolfoort':current.data.representative;if($('sign-name').value.trim()!==expected)throw Error('Enter the exact authorized name: '+expected);
 if(me.role==='client'){const assets=signingProfile?.get();if(!assets?.signature||!assets?.stamp)throw Error('Save your private signature and company stamp first.');const confirmation=await confirmAgreement({db,kind:'jv',agreement:current,pdfHash:reviewEvidence.pdfHash,reviewToken:reviewEvidence.token});if(!confirmation)return false;await operation('sign',{...confirmation,name:expected,authority:true,accept:true,use_saved_assets:true,asset_version:assets.version,review_token:reviewEvidence.token,schedules_accepted:true});return}
 if(!confirm('Apply J.P. Kolfoort’s signature and the Nexora stamp to this exact client-signed JV and release the final agreement?'))return false;
 const id=current.id;const assetRows=checked(await db.from('commission_assets').select('name,png_base64'));const assets=Object.fromEntries(assetRows.map(x=>[x.name,x.png_base64]));if(!assets.signature||!assets.stamp)throw Error('Nexora signing images are not configured.');
 await api('/api/agreements/'+id+'/action',{action:'prepare_approval',revision:current.revision,verified:true,review_token:reviewEvidence.token});current=adapt(checked(await db.from('jv_agreements').select('*').eq('id',id).single()));
 const bytes=await createJVPDF(current,await getTemplate(),assets);let binary='';for(let i=0;i<bytes.length;i+=32768)binary+=String.fromCharCode(...bytes.subarray(i,i+32768));
 const confirmation=await confirmAgreement({db,kind:'jv',agreement:current,admin:true,bytes});if(!confirmation)return false;
 await operation('approve',{...confirmation,verified:true,approval_token:current.data.approval_request.token,pdf:btoa(binary)});
}
$('new').onclick=()=>act(async()=>{const recipient=$('new-recipient').value;if(!recipient)throw Error('Select a registered client with a company profile.');const a=await api('/api/agreements',{recipient});tab='parties';closePreview();await load(a.id);message('Private draft created from the selected company profile.')});
$('close-preview').onclick=closePreview;
async function init(){
 const {createClient}=await import('https://esm.sh/@supabase/supabase-js@2.102.0');db=createClient(portalConfig.url,portalConfig.publishableKey,{auth:{storage:sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});if(!await ensurePortalSecurity(db))return;
 const {session}=checked(await db.auth.getSession());if(!session){location.replace('client-login.html');return}
 const member=checked(await db.from('portal_members').select('user_id,email,is_admin,active').eq('user_id',session.user.id).single());if(!member.active||!checked(await db.rpc('my_portal_access_allowed')))throw Error('Your portal access is not active.');await initializeAccountLanguage(db);me={id:member.user_id,email:member.email,role:member.is_admin?'admin':'client'};
 const members=member.is_admin?checked(await db.from('portal_members').select('user_id,email,is_admin,active').eq('active',true)):[member];config={users:members.map(m=>({id:m.user_id,email:m.email,role:m.is_admin?'admin':'client'}))};profiles=await api('/api/profiles');
 for(const u of config.users.filter(u=>u.role==='client')){const profile=profiles.find(p=>p.user_id===u.id);if(!profile)continue;const o=E('option',(profile.details?.B_COMPANY||'Company name not provided')+' ('+u.email+')');o.value=u.id;$('new-recipient').append(o)}
 const params=new URLSearchParams(location.search),client=params.get('client');if(client&&me.role==='admin'){const back=E('a','Back to client file','button secondary');back.href='client-files.html?client='+encodeURIComponent(client);$('protected').prepend(back);}if(client&&[...$('new-recipient').options].some(o=>o.value===client))$('new-recipient').value=client;
 $('logout').onclick=async()=>{await db.auth.signOut();location.replace('client-login.html')};db.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'){closePreview();current=null;$('detail').replaceChildren();$('list').replaceChildren();location.replace('client-login.html')}});
 await load(params.get('agreement'));$('protected').hidden=false;if(params.get('create')==='1'&&me.role==='admin')$('new').click();
}
window.addEventListener('pagehide',closePreview);init().catch(e=>message(e.message));
