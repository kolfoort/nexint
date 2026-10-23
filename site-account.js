import {config} from './portal-config.js';

const root=document.querySelector('[data-client-account]');
if(root && config.url && config.publishableKey && !config.url.includes('bibzafctpkekixsevqfx')) {
  const copy={nl:{login:"KLANTENPORTAAL",documents:"KLANTENPORTAAL",logout:"Uitloggen"},ar:{login:'بوابة العملاء',documents:'بوابة العملاء',logout:'تسجيل الخروج'},en:{login:'CLIENT PORTAL',documents:'CLIENT PORTAL',logout:'Sign out'},de:{login:'KUNDENLOGIN',documents:'MEINE DOKUMENTE',logout:'Abmelden'},es:{login:'ACCESO CLIENTES',documents:'MIS DOCUMENTOS',logout:'Cerrar sesión'}};
  const labels=copy[document.documentElement.lang] || copy.en;
  const link=root.querySelector('[data-account-link]'),details=root.querySelector('[data-account-details]'),email=root.querySelector('[data-account-email]'),logout=root.querySelector('[data-account-logout]');
  function render(user) {
    link.textContent=user?labels.documents:labels.login;
    link.href=user?'documents.html?v=20261020-profile2':'client-login.html?v=20261020-profile2';
    details.hidden=!user;
    email.textContent=user?.email || '';
    email.title=user?.email || '';
    logout.textContent=labels.logout;
  }
  async function start() {
    const {createClient}=await import('https://esm.sh/@supabase/supabase-js@2.102.0');
    // Use the same tab-scoped session as the portal. This preserves separate admin/client test tabs.
    const db=createClient(config.url,config.publishableKey,{auth:{storage:window.sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:false,flowType:'implicit'}});
    let revision=0;
    async function refresh() {
      const current=++revision;
      const {data:{session},error}=await db.auth.getSession();
      if(error || !session) {if(current===revision)render(null);return;}
      const result=await db.auth.getUser();
      if(current===revision)render(result.error?null:result.data.user);
    }
    db.auth.onAuthStateChange((_event,session)=>{revision++;render(session?.user || null);});
    logout.addEventListener('click',async()=>{
      logout.disabled=true;
      const {error}=await db.auth.signOut();
      logout.disabled=false;
      if(error){logout.textContent=labels.logout+' — retry';return;}
      revision++;render(null);
    });
    window.addEventListener('pageshow',refresh);
    document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')refresh();});
    await refresh();
  }
  start().catch(()=>render(null));
}
