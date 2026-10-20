export const companyFields=[['B_COMPANY','Legal company name',100,true],['B_REGISTRATION','Company registration number',60,true],['B_ADDRESS','Registered address',150,true],['B_COUNTRY','Country of incorporation',60,true],['B_REPRESENTATIVE','Authorized representative',80,true],['B_TITLE','Position / title',80,true],['B_PHONE','Telephone',50,true],['B_EMAIL','Business email',100,true],['B_WEBSITE','Website',100,false]];
const $=id=>document.getElementById(id);
const element=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e;};
function fields(container,prefix,details={}){for(const [key,label,max,required] of companyFields){const wrap=element('div'),l=element('label',label+(required?'':' (optional)')),input=element('input');input.id=prefix+key;input.name=key;l.htmlFor=input.id;input.maxLength=max;input.required=required;input.value=details[key]||'';if(key==='B_EMAIL')input.type='email';wrap.append(l,input);container.append(wrap);}}
export async function initCompanyProfile({db,member,check,action,message}){
 let profile=null;const listeners=[];
 const form=$('company-profile-form');fields($('company-profile-fields'),'company-');
 async function refresh(notify=false){
  const mapping=check(await db.from('portal_company_members').select('company_id').eq('user_id',member.user_id).maybeSingle());
  profile=mapping?check(await db.from('portal_companies').select('*').eq('id',mapping.company_id).single()):null;
  for(const [key] of companyFields)form.elements[key].value=profile?.details[key]||(key==='B_EMAIL'?member.email:'');
  $('company-profile-status').textContent=profile?(profile.status==='approved'?'Approved':'Pending review')+' · Version '+profile.version:'No company profile yet';
  $('company-profile-summary').textContent=profile?.details.B_COMPANY||'Your company details will be saved when you submit your MCNDA. You can also save them here first.';
  $('company-profile-stamp-note').textContent=profile?.details.B_STAMP_PATH?'A company stamp is saved privately and will be available when preparing your MCNDA.':'You can add your company stamp when preparing your MCNDA.';
  if(notify)for(const listener of listeners)await listener(profile);
 }
 form.addEventListener('submit',e=>{e.preventDefault();action($('company-profile-save'),async()=>{
  if(!form.reportValidity())return;
  const details=Object.fromEntries(companyFields.map(([key])=>[key,form.elements[key].value.trim()]));details.B_STAMP_PATH=profile?.details.B_STAMP_PATH||'';details.B_PROFILE_ID=profile?.id||'';
  const result=await db.rpc('save_my_company_profile',{p_details:details,p_expected_version:profile?.version||0});
  if(result.error){message('Unable to save. The company profile may have changed. Refresh the profile and try again.');return;}
  await refresh(true);message('Company profile saved. Changed details require Nexora approval. Existing documents remain unchanged.');
 });});
 $('company-profile-refresh').addEventListener('click',()=>action($('company-profile-refresh'),()=>refresh(true)));
 await refresh();
 return {getProfile:()=>profile,refresh,subscribe:listener=>listeners.push(listener)};
}
export async function loadCompanyAdmin({db,check,action,message,members}){
 const list=$('company-admin-list');if(!list)return;
 const companies=check(await db.from('portal_companies').select('*').order('updated_at',{ascending:false}));
 const mappings=check(await db.from('portal_company_members').select('user_id,company_id'));
 list.replaceChildren();
 if(!companies.length)list.append(element('p','No company profiles have been submitted yet. Profiles appear after a client saves their details or submits an MCNDA.'));
 for(const company of companies){
  const panel=element('section');panel.className='admin-doc';panel.append(element('h3',company.details.B_COMPANY),element('p',(company.status==='approved'?'Approved':'Pending review')+' · Version '+company.version));
  const dl=element('dl');dl.className='company-details';for(const [key,label] of companyFields){dl.append(element('dt',label),element('dd',company.details[key]||'—'));}panel.append(dl);
  const actions=element('div');actions.className='submission-actions';
  if(company.details.B_STAMP_PATH){const view=element('button','View company stamp');view.className='secondary';view.type='button';view.addEventListener('click',()=>action(view,async()=>{const blob=check(await db.storage.from('nexora-company-assets').download(company.details.B_STAMP_PATH));const url=URL.createObjectURL(blob);const a=element('a');a.href=url;a.download='Company_stamp.png';a.click();setTimeout(()=>URL.revokeObjectURL(url),10000);}));actions.append(view);}
  if(company.status!=='approved'){const approve=element('button','Approve company profile');approve.type='button';const incomplete=companyFields.some(([key,,,required])=>required&&!String(company.details[key]||'').trim());if(incomplete){approve.disabled=true;panel.append(element('p','The client must complete all required company details before this profile can be approved.'));}approve.addEventListener('click',()=>action(approve,async()=>{check(await db.rpc('approve_company_profile',{p_company_id:company.id,p_expected_version:company.version}));await loadCompanyAdmin({db,check,action,message,members});message('Company profile approved. Approval applies to this version only.');}));actions.append(approve);}
  panel.append(actions);list.append(panel);
 }
 if(companies.length){const title=element('h3','Company users');list.append(title,element('p','Link existing portal users to a company. This gives them access to that company’s profile and saved stamp. Previous document records remain with their original account.'));
  for(const person of members.filter(m=>!m.is_admin)){
   const row=element('div');row.className='member';const label=element('label',person.email),select=element('select');select.setAttribute('aria-label','Company for '+person.email);
   const blank=element('option','No company linked');blank.value='';select.append(blank);
   for(const c of companies){const o=element('option',c.details.B_COMPANY);o.value=c.id;select.append(o);}
   const current=mappings.find(m=>m.user_id===person.user_id)?.company_id||'';select.value=current;label.append(select);row.append(label);
   const save=element('button','Save company link');save.type='button';save.className='secondary';
   save.addEventListener('click',()=>{
    if(select.value===current)return;
    if(!window.confirm('Change the company linked to '+person.email+'? The user will have access to the selected company profile and stamp. Previously submitted documents will keep their original details.'))return;
    action(save,async()=>{if(select.value)check(await db.from('portal_company_members').upsert({user_id:person.user_id,company_id:select.value},{onConflict:'user_id'}));else check(await db.from('portal_company_members').delete().eq('user_id',person.user_id));await loadCompanyAdmin({db,check,action,message,members});message('Company link updated. Ask the client to refresh their profile.');});
   });row.append(save);list.append(row);
  }
 }
}
