import { config } from './portal-config.js';

const $ = id => document.getElementById(id);
const page = document.body.dataset.page;
let db, member, documents = [], members = [];
let generation = 0;
function message(text) { $('status').textContent = text; $('status').hidden = !text; }
function node(tag, text, cls) { const e = document.createElement(tag); if(text !== undefined) e.textContent = text; if(cls) e.className = cls; return e; }
function fail(error) { console.error(error); message('Unable to complete this request. Please try again or contact info@nexint.eu.'); }
function check(result) { if(result.error) throw result.error; return result.data; }
function resetPrivateView() { generation++; documents = []; members = []; for(const id of ['document-list','member-list','admin-documents']) if($(id)) $(id).replaceChildren(); if($('protected')) $('protected').hidden = true; }
function date(value) { return value ? new Date(value+'T12:00:00').toLocaleDateString('en-GB',{day:'numeric',month:'short',year:'numeric'}) : '—'; }
async function action(button, work) { button.disabled = true; try { await work(); } catch(error) { fail(error); } finally { button.disabled = false; } }
async function authorize() {
  const {user} = check(await db.auth.getUser());
  if(!user) { location.replace('client-login.html'); return false; }
  member = check(await db.from('portal_members').select('user_id,email,is_admin,active').eq('user_id',user.id).maybeSingle());
  if(!member?.active) { resetPrivateView(); message('Your access has not been enabled. Please contact Nexora International.'); return false; }
  if(page === 'admin' && !member.is_admin) { resetPrivateView(); message('This page is reserved for Nexora administrators.'); return false; }
  $('account').textContent = member.email;
  $('protected').hidden = false;
  if(member.is_admin && $('admin-link')) $('admin-link').hidden = false;
  return true;
}
async function loadDocuments() {
  const current = generation;
  const data = check(await db.from('portal_documents').select('id,title,description,category,version_date,is_draft,storage_path').eq('published',true).order('version_date',{ascending:false}));
  if(current !== generation) return;
  documents = data;
  renderDocuments();
}
function renderDocuments() {
  const term = $('search').value.trim().toLowerCase(), category = $('category').value;
  const visible = documents.filter(d => (!category || d.category === category) && (d.title+' '+d.description).toLowerCase().includes(term));
  $('document-list').replaceChildren();
  if(!visible.length) { $('document-list').append(node('p', documents.length ? 'No documents match your search.' : 'No documents have been assigned to your account yet.')); return; }
  for(const doc of visible) {
    const card = node('article',undefined,'card');
    card.append(node('div',doc.category+(doc.is_draft?' · DRAFT':''),'tag'),node('h2',doc.title),node('p',doc.description),node('div','Version: '+date(doc.version_date),'meta'));
    const button = node('button','Download PDF'); button.type='button';
    button.addEventListener('click', () => action(button, async () => {
      // Download with the user's JWT; never create public or reusable file URLs.
      const blob = check(await db.storage.from('nexora-documents').download(doc.storage_path));
      const url = URL.createObjectURL(blob), a = document.createElement('a');
      a.href = url; a.download = doc.title.replace(/[^a-zA-Z0-9 _.-]/g,'_')+'.pdf'; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    }));
    card.append(button); $('document-list').append(card);
  }
}
async function loadAdmin() {
  const current = generation;
  const [people, docs, grants] = await Promise.all([
    db.from('portal_members').select('user_id,email,active,is_admin').order('email'),
    db.from('portal_documents').select('*').order('created_at',{ascending:false}),
    db.from('portal_document_access').select('document_id,user_id')
  ]);
  if(current !== generation) return;
  members=check(people); documents=check(docs); const access=check(grants);
  $('member-list').replaceChildren(); $('admin-documents').replaceChildren();
  for(const person of members) {
    const row=node('div',undefined,'member');
    row.append(node('strong',person.email),node('div',(person.is_admin?'Administrator':'Client')+' · '+(person.active?'Active':'Disabled'),'account'));
    if(person.user_id !== member.user_id && !person.is_admin) {
      const b=node('button',person.active?'Disable access':'Enable access','secondary'); b.type='button';
      b.addEventListener('click',()=>action(b,async()=>{check(await db.from('portal_members').update({active:!person.active}).eq('user_id',person.user_id));await loadAdmin();})); row.append(b);
    }
    $('member-list').append(row);
  }
  if(!documents.length) $('admin-documents').append(node('p','No documents uploaded yet.'));
  for(const doc of documents) {
    const row=node('section',undefined,'admin-doc'); row.append(node('h3',doc.title),node('p',doc.category+' · '+date(doc.version_date)+(doc.is_draft?' · DRAFT':'')));
    const toggle=node('button',doc.published?'Unpublish':'Publish','secondary'); toggle.type='button';
    toggle.addEventListener('click',()=>action(toggle,async()=>{check(await db.from('portal_documents').update({published:!doc.published}).eq('id',doc.id));await loadAdmin();})); row.append(toggle);
    row.append(node('p','Client access'));
    for(const person of members.filter(p=>!p.is_admin)) {
      const label=node('label',undefined,'check'), box=document.createElement('input'); box.type='checkbox'; box.checked=access.some(a=>a.document_id===doc.id && a.user_id===person.user_id);
      box.addEventListener('change',async()=>{
        box.disabled=true;
        try { if(box.checked) check(await db.from('portal_document_access').insert({document_id:doc.id,user_id:person.user_id})); else check(await db.from('portal_document_access').delete().eq('document_id',doc.id).eq('user_id',person.user_id)); }
        catch(error){box.checked=!box.checked;fail(error);} finally{box.disabled=false;}
      }); label.append(box,document.createTextNode(person.email+(person.active?'':' (disabled)'))); row.append(label);
    }
    $('admin-documents').append(row);
  }
}
function bindAdmin() {
  $('upload').addEventListener('submit',event=>{
    event.preventDefault(); action($('upload-button'),async()=>{
      const form=event.target, file=form.elements.file.files[0];
      if(!file || file.type!=='application/pdf' || file.size>20*1024*1024) { message('Please select a PDF smaller than 20 MB.'); return; }
      const id=crypto.randomUUID(), path=id+'.pdf';
      check(await db.storage.from('nexora-documents').upload(path,file,{contentType:'application/pdf',upsert:false}));
      try { check(await db.from('portal_documents').insert({id,title:form.elements.title.value.trim(),description:form.elements.description.value.trim(),category:form.elements.category.value,version_date:form.elements.version_date.value,is_draft:form.elements.is_draft.checked,storage_path:path,published:false})); }
      catch(error) { await db.storage.from('nexora-documents').remove([path]); throw error; }
      form.reset(); message('PDF uploaded. Assign client access and publish when ready.'); await loadAdmin();
    });
  });
}
async function start() {
  if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(config.url) || !config.publishableKey) { message('The Nexora client portal is being prepared. Please contact info@nexint.eu for document requests.'); return; }
  // An explicit guard prevents accidentally linking the Black Pearl project.
  if(config.url.includes('bibzafctpkekixsevqfx')) throw new Error('Nexora requires its own Supabase project.');
  const {createClient} = await import('https://esm.sh/@supabase/supabase-js@2.102.0');
  db=createClient(config.url,config.publishableKey,{auth:{storage:window.sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:'implicit'}});
  db.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'){resetPrivateView();if(page!=='login')location.replace('client-login.html');}});
  const {session}=check(await db.auth.getSession());
  if($('logout')) $('logout').addEventListener('click',()=>action($('logout'),async()=>{check(await db.auth.signOut());location.replace('client-login.html');}));
  if(page==='login') {
    $('login-form').hidden=false;
    if(session) { location.replace('documents.html'); return; }
    $('login-form').addEventListener('submit',event=>{event.preventDefault();action($('login-button'),async()=>{
      const result=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});
      if(result.error){message('Sign-in unsuccessful. Check your email and password, or contact Nexora.');return;}
      location.replace('documents.html');
    });});
    $('reset').addEventListener('click',()=>action($('reset'),async()=>{
      if(!$('email').reportValidity() || !$('email').value.trim()){message('Enter your email address first.');return;}
      check(await db.auth.resetPasswordForEmail($('email').value.trim(),{redirectTo:new URL('set-password.html',location.href).href}));
      message('If your account is eligible, you will receive an email with the next steps.');
    }));
  } else if(page==='password') {
    if(!session) {message('This invitation or reset link is invalid or has expired. Please contact Nexora for a new link.');return;}
    // Remove credentials from the address bar after Supabase has processed the link.
    history.replaceState(null,'',location.pathname);
    $('password-form').hidden=false;
    $('password-form').addEventListener('submit',event=>{event.preventDefault();action($('save-password'),async()=>{
      if($('password').value!==$('confirm').value){message('The passwords do not match.');return;}
      check(await db.auth.updateUser({password:$('password').value})); location.replace('documents.html');
    });});
  } else if(await authorize()) {
    if(page==='documents') { $('search').addEventListener('input',renderDocuments);$('category').addEventListener('change',renderDocuments);await loadDocuments(); }
    if(page==='admin') {bindAdmin();await loadAdmin();}
  }
}
start().catch(fail);
