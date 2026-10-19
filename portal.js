import { config } from './portal-config.js';

const $ = id => document.getElementById(id);
const page = document.body.dataset.page;
let db, member, documents = [], members = [], submissions = [];
let generation = 0;
function message(text) { $('status').textContent = text; $('status').hidden = !text; }
function node(tag, text, cls) { const e = document.createElement(tag); if(text !== undefined) e.textContent = text; if(cls) e.className = cls; return e; }
function fail(error) { console.error(error); message('Unable to complete this request. Please try again or contact info@nexint.eu.'); }
function check(result) { if(result.error) throw result.error; return result.data; }
function resetPrivateView() { generation++; documents = []; members = []; submissions = []; for(const id of ['document-list','member-list','admin-documents','submission-list','incoming-list']) if($(id)) $(id).replaceChildren(); if($('protected')) $('protected').hidden = true; }
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
async function downloadPDF(bucket, path, title) {
  const blob = check(await db.storage.from(bucket).download(path));
  const url = URL.createObjectURL(blob), a = document.createElement('a');
  a.href = url; a.download = title.replace(/[^a-zA-Z0-9 _.-]/g,'_')+'.pdf'; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}
async function validPDF(file) {
  if(!file || file.size===0 || file.size>20*1024*1024 || !file.name.toLowerCase().endsWith('.pdf')) return false;
  // Convenience validation only: private storage and database RLS enforce access.
  const signature = new TextDecoder().decode(await file.slice(0,5).arrayBuffer());
  return signature === '%PDF-';
}
function missingUploadSetup(error) { return ['PGRST205','42P01'].includes(error?.code); }
async function loadSubmissions() {
  const current=generation;
  const result=await db.from('portal_submissions').select('id,user_id,title,note,storage_path,status,created_at').order('created_at',{ascending:false});
  if(current!==generation) return;
  if(result.error && missingUploadSetup(result.error)) {
    if($('client-upload-section')) $('client-upload-section').hidden=true;
    if($('incoming-list')) $('incoming-list').replaceChildren(node('p','Client uploads are being prepared.'));
    return;
  }
  submissions=check(result);
  if(page==='documents') {
    $('client-upload-section').hidden=false;
    renderSubmissions($('submission-list'),false);
  } else renderSubmissions($('incoming-list'),true);
}
function renderSubmissions(container, admin) {
  container.replaceChildren();
  if(!submissions.length) { container.append(node('p',admin?'No client documents have been received yet.':'You have not shared any documents with Nexora yet.')); return; }
  for(const item of submissions) {
    const row=node('article',undefined,'submission');
    const labels={received:'Received',in_review:'In review',reviewed:'In review',approved:'Approved',denied:'Denied'};
    const status=labels[item.status] || 'Received';
    row.append(node('div',status,'tag status-'+(item.status==='reviewed'?'in_review':item.status)),node('h3',item.title));
    if(admin) row.append(node('div',members.find(p=>p.user_id===item.user_id)?.email || 'Client account','account'));
    row.append(node('div',new Date(item.created_at).toLocaleString('en-GB',{dateStyle:'medium',timeStyle:'short'}),'meta'));
    if(item.note) row.append(node('p',item.note));
    const controls=node('div',undefined,'submission-actions'), download=node('button','Download PDF','secondary'); download.type='button';
    download.addEventListener('click',()=>action(download,()=>downloadPDF('nexora-client-uploads',item.storage_path,item.title))); controls.append(download);
    if(admin) {
      const reviewLabel=node('label','Document status','status-control');
      const select=document.createElement('select');select.setAttribute('aria-label','Status for '+item.title);
      for(const value of ['received','in_review','approved','denied']) {
        const option=node('option',labels[value]); option.value=value;select.append(option);
      }
      select.value=item.status==='reviewed'?'in_review':item.status;
      reviewLabel.append(select);
      const save=node('button','Save status');save.type='button';
      save.addEventListener('click',()=>action(save,async()=>{
        check(await db.from('portal_submissions').update({status:select.value}).eq('id',item.id).select('id').single());
        await loadSubmissions();message('Document status updated. The client can see the new status after refreshing.');
      }));
      const remove=node('button','Delete','danger');remove.type='button';
      remove.addEventListener('click',()=>{
        if(!window.confirm('Permanently delete “'+item.title+'” and its PDF? This cannot be undone.')) return;
        action(remove,async()=>{
          // Remove the actual private PDF first, so a failed delete cannot leave an accessible orphan.
          check(await db.storage.from('nexora-client-uploads').remove([item.storage_path]));
          check(await db.from('portal_submissions').delete().eq('id',item.id).select('id').single());
          await loadSubmissions();message('Document and PDF deleted.');
        });
      });
      controls.append(reviewLabel,save,remove);
    }
    row.append(controls);container.append(row);
  }
}
function bindClientUpload() {
  $('client-upload').addEventListener('submit',event=>{
    event.preventDefault(); action($('client-upload-button'),async()=>{
      const form=event.target,file=form.elements.file.files[0];
      if(!await validPDF(file)){message('Please select a valid PDF smaller than 20 MB.');return;}
      const title=form.elements.title.value.trim();
      if(!title){message('Please enter a document title.');return;}
      const id=crypto.randomUUID(),path=member.user_id+'/'+id+'.pdf';
      check(await db.storage.from('nexora-client-uploads').upload(path,file,{contentType:'application/pdf',upsert:false}));
      const result=await db.from('portal_submissions').insert({id,user_id:member.user_id,title,note:form.elements.note.value.trim(),storage_path:path});
      if(result.error) { await db.storage.from('nexora-client-uploads').remove([path]); throw result.error; }
      form.reset(); message('Your document has been shared with Nexora. It is visible only to your account and authorized Nexora administrators.'); await loadSubmissions();
    });
  });
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
      await downloadPDF('nexora-documents',doc.storage_path,doc.title);
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
      if(!await validPDF(file)) { message('Please select a valid PDF smaller than 20 MB.'); return; }
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
    if($('refresh-submissions')) $('refresh-submissions').addEventListener('click',()=>action($('refresh-submissions'),loadSubmissions));
    if(page==='documents') { $('search').addEventListener('input',renderDocuments);$('category').addEventListener('change',renderDocuments);bindClientUpload();await loadDocuments();await loadSubmissions(); }
    if(page==='admin') {bindAdmin();await loadAdmin();await loadSubmissions();}
  }
}
start().catch(fail);
