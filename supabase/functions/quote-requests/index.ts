import {createClient} from 'npm:@supabase/supabase-js@2.102.0';
import nodemailer from 'npm:nodemailer@7.0.11';
const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const db=createClient(Deno.env.get('SUPABASE_URL')!,secret,{auth:{persistSession:false}});
const uuid=(s:unknown)=>typeof s==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
const escape=(s:unknown)=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const digest=async(s:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)))).map(b=>b.toString(16).padStart(2,'0')).join('');
const statuses:Record<string,string>={received:'Received',in_review:'Under review',information_required:'Additional information required',quoted:'Quote available',closed:'Closed'};
const products=['Premium Gasoline RON 95/98','Ultra-Low Sulphur Diesel (ULSD)','Jetfuel','Group I Base Oils','Group II Base Oils','Group III Base Oils','(Heavy) Fuel Oil (Marine Fuels, Fuel Oil, HFO)','Hydrotreated Vegetable Oil (HVO)','Sustainable Aviation Fuel (SAF)','Naphtha','Automotive Grade Urea (AGU)','Bitumen','Calcium Ammonium Nitrate (CAN)','Urea 46%','Diammonium Phosphate (DAP)','Nitrogen Phosphorus Potassium (NPK)','Rock Phosphate','Sulphur','Bonny Light Crude Oil (BLCO)','Crude Oil from the GCC','SOMO Medium Crude','ULCC','VLCC','OBO','Suezmax','Aframax','LNG | LPG','Chemical | Product Tanker','MR Tanker','Oil Tanker'];
function mailHtml(title:string,intro:string,rows:[string,string][],label:string,url:string){return `<!doctype html><html lang="en"><body style="margin:0;background:#f3f6f9;color:#002040;font-family:Arial,Helvetica,sans-serif"><table role="presentation" width="100%"><tr><td align="center" style="padding:30px 15px"><table role="presentation" width="600" style="width:100%;max-width:600px;background:white;border:1px solid #d7e0e9" cellpadding="0" cellspacing="0"><tr><td style="padding:28px 32px;border-bottom:3px solid #bd9a45"><img src="https://inndqvdryjiupfzkzsdl.supabase.co/storage/v1/object/public/nexora-brand-assets/nexora-email-logo.png" width="200" alt="Nexora International"></td></tr><tr><td style="padding:32px"><p style="font-size:11px;letter-spacing:2px;color:#96752a">NEXORA INTERNATIONAL</p><h1 style="font:normal 30px/1.2 Georgia,serif">${escape(title)}</h1><p style="font-size:15px;line-height:1.7">${escape(intro)}</p><table role="presentation" width="100%" style="background:#f3f6f9;border-top:2px solid #bd9a45">${rows.map(([k,v])=>`<tr><td style="padding:12px 18px;font-size:13px">${escape(k)}<br><strong>${escape(v)}</strong></td></tr>`).join('')}</table><p style="margin-top:30px"><a href="${escape(url)}" style="display:inline-block;background:#002040;color:white;padding:16px 22px;text-decoration:none;font-weight:bold;font-size:13px">${escape(label)}</a></p><p style="font-size:12px;color:#64758a;line-height:1.7">This message confirms a request or status update. It is not an offer, contract or confirmation of supply. Access to commercial documents is granted separately by Nexora.</p></td></tr><tr><td style="background:#002040;color:white;padding:22px 32px;font-size:11px;line-height:1.8"><strong>NEXORA INTERNATIONAL</strong><br>Herengracht 208 · 1016 BS Amsterdam · The Netherlands<br>info@nexint.eu · www.nexint.eu</td></tr></table></td></tr></table></body></html>`;}
Deno.serve(async req=>{
 const origin=req.headers.get('origin'),allowed=!origin||['https://nexint.eu','https://www.nexint.eu'].includes(origin);
 const headers={'Access-Control-Allow-Origin':origin&&allowed?origin:'https://nexint.eu','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin'};
 const response=(code:number,data:unknown)=>Response.json(data,{status:code,headers});
 if(!allowed)return response(403,{message:'Origin not allowed'});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return response(405,{message:'POST required'});
 let body;try{const text=await req.text();if(text.length>16000)throw 0;body=JSON.parse(text);}catch{return response(400,{message:'Invalid request'});}
 if(body.action==='notify'){
  if(!uuid(body.id)||typeof body.token!=='string'||!/^[0-9a-f]{64}$/.test(body.token))return response(401,{message:'Unauthorized'});
  const claimed=await db.rpc('claim_quote_email',{p_id:body.id,p_hash:await digest(body.token)});
  if(claimed.error)return response(500,{message:'Unable to claim notification'});if(!claimed.data?.length)return response(200,{message:'No message to send'});
  const job=claimed.data[0],update=async(v:Record<string,unknown>)=>{const r=await db.from('portal_quote_emails').update(v).eq('id',job.id).eq('lease',job.lease);if(r.error)throw r.error;};
  const password=Deno.env.get('NEXORA_SMTP_PASSWORD');
  const transport=nodemailer.createTransport({host:'smtp.transip.email',port:465,secure:true,auth:{user:'info@nexint.eu',pass:password},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000,tls:{minVersion:'TLSv1.2',rejectUnauthorized:true}});
  try{
   if(!password)throw new Error('SMTP unavailable');
   const loaded=await db.from('portal_quote_requests').select('*').eq('id',job.quote_id).single();if(loaded.error)throw loaded.error;const q=loaded.data;
   if(job.kind==='status'&&job.revision!==q.revision){await update({sent_at:new Date().toISOString(),leased_at:null});return response(200,{message:'Superseded notification skipped'});}
   const marine=q.transaction.kind==='marine',category=marine?'Marine Chartering':q.transaction.kind==='crude'?'Crude Oils':'Performance Fluids',type=category+' request';
   let title=job.kind==='admin'?'New '+type:job.kind==='receipt'?'Your request has been received.':'An update on your request.';
   let intro=job.kind==='admin'?'Review the new request in Nexora administration.':job.kind==='receipt'?'Thank you for your interest in Nexora International. Our team will review your requirements and contact you.':'The status of your request has changed. Sign in to your Client Portal for details.';
   let url='https://nexint.eu/quote-requests.html',label='View request',recipient=q.email;
   if(job.kind==='admin'){recipient='info@nexint.eu';label='Review request';}
   if(job.kind==='receipt'&&!q.recipient){
    // Recover a prior invitation after a mail retry; never reset an existing user's password.
    const found=await db.from('portal_members').select('user_id').eq('email',q.email).maybeSingle();if(found.error)throw found.error;
    if(found.data){const user=await db.auth.admin.getUserById(found.data.user_id);if(user.data.user?.user_metadata?.nexora_quote_request!==q.id)throw new Error('Account requires manual linking');}
    const link=await db.auth.admin.generateLink({type:found.data?'magiclink':'invite',email:q.email,options:{redirectTo:'https://nexint.eu/set-password.html',data:{nexora_quote_request:q.id,company_name:q.details.B_COMPANY}}});
    if(link.error||!link.data.properties?.action_link)throw new Error('Activation link unavailable');
    url=link.data.properties.action_link;label='Activate your client profile';intro+=' Use the secure link below to verify your email address and set your password. The link is personal; do not forward it.';
   }
   const rows:[string,string][]=[['Reference',q.reference],['Request type',category],[marine?'Vessel':'Product',q.transaction.product],['Company',q.details.B_COMPANY],['Status',statuses[q.status]]];
   await transport.sendMail({from:'Nexora International <info@nexint.eu>',to:recipient,subject:`Nexora | ${q.reference} | ${title}`,text:intro+'\n\n'+rows.map(([k,v])=>k+': '+v).join('\n')+'\n\n'+label+': '+url,html:mailHtml(title,intro,rows,label,url),messageId:`<quote-${job.id}@nexint.eu>`});
   await update({sent_at:new Date().toISOString(),leased_at:null});return response(200,{message:'Notification sent'});
  }catch{await update({leased_at:null,next_at:new Date(Date.now()+300000).toISOString()}).catch(()=>{});return response(502,{message:'Notification delivery pending'});}finally{transport.close();}
 }
 if(body.action!=='submit'||!uuid(body.key)||body.privacy!==true)return response(400,{message:'Please complete the required fields.'});
 if(body.website_trap)return response(400,{message:'Unable to submit request.'});
 const tx=body.transaction,d=body.details;if(!tx||!d||typeof tx!=='object'||typeof d!=='object'||Array.isArray(tx)||Array.isArray(d))return response(400,{message:'Please complete the form.'});
 const limits:Record<string,number>={B_COMPANY:100,B_REGISTRATION:60,B_ADDRESS:150,B_COUNTRY:60,B_REPRESENTATIVE:80,B_TITLE:80,B_PHONE:50,B_EMAIL:100,B_WEBSITE:100};
 const details:Record<string,string>={};for(const [k,max]of Object.entries(limits)){if(typeof d[k]!=='string'||d[k].length>max)return response(400,{message:'Please check your company details.'});details[k]=d[k].trim();}
 if(['B_COMPANY','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_PHONE','B_EMAIL'].some(k=>!details[k])||!/^\S+@[^\s@]+\.[^\s@]+$/.test(details.B_EMAIL))return response(400,{message:'Please complete your company details.'});details.B_EMAIL=details.B_EMAIL.toLowerCase();
 const fields:Record<string,number>={kind:20,product:150,quantity:30,unit:20,basis:20,frequency:50,destination:150,delivery:10,notes:3000,cargo:150,loading:150,laycan_end:10,charter:40};
 const transaction:Record<string,string>={};for(const[k,max]of Object.entries(fields)){const value=tx[k]??'';if(typeof value!=='string'||value.length>max)return response(400,{message:'Please check your request details.'});transaction[k]=value.trim();}
 if(!['product','performance','crude','marine'].includes(transaction.kind)||!products.includes(transaction.product)||!Number.isFinite(Number(transaction.quantity))||Number(transaction.quantity)<=0||!['MT','KMT','BBL','KBBL','Litres','m³'].includes(transaction.unit)||!transaction.destination)return response(400,{message:'Please check the product, quantity, unit and destination.'});
 if((transaction.kind==='performance'&&!products.slice(0,18).includes(transaction.product))||(transaction.kind==='crude'&&!products.slice(18,21).includes(transaction.product)))return response(400,{message:'Please select a product from this range.'});
 if(transaction.kind==='marine'&&(!products.slice(21).includes(transaction.product)||!transaction.cargo||!transaction.loading||!/^\d{4}-\d{2}-\d{2}$/.test(transaction.delivery)||!/^\d{4}-\d{2}-\d{2}$/.test(transaction.laycan_end)||transaction.laycan_end<transaction.delivery))return response(400,{message:'Please complete the vessel, cargo and port details.'});
 let userId:string|null=null;
 const jwt=req.headers.get('Authorization')?.replace(/^Bearer /i,'');
 if(jwt){const result=await db.auth.getUser(jwt);if(result.error||!result.data.user?.email_confirmed_at)return response(401,{message:'Please sign in again.'});const u=result.data.user;
  const member=await db.from('portal_members').select('active').eq('user_id',u.id).maybeSingle();if(!member.data?.active)return response(403,{message:'Please contact Nexora about your portal access.'});
  const access=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:'Bearer '+jwt}}});const permission=await access.rpc('my_portal_access_allowed');if(permission.error||!permission.data)return response(403,{message:'Please contact Nexora about your portal access.'});
  userId=u.id;details.B_EMAIL=u.email!.toLowerCase();
  const link=await db.from('portal_company_members').select('company_id').eq('user_id',u.id).maybeSingle();if(link.data){const company=await db.from('portal_companies').select('details').eq('id',link.data.company_id).single();if(company.error)throw company.error;for(const k of Object.keys(limits))if(company.data.details[k])details[k]=company.data.details[k];details.B_EMAIL=u.email!.toLowerCase();}
 }else{const existing=await db.from('portal_members').select('user_id').eq('email',details.B_EMAIL).maybeSingle();if(existing.error)return response(503,{message:'Please try again shortly.'});if(existing.data)return response(409,{message:'Please sign in to submit this request using your existing client profile.',signin:true});}
 const ip=req.headers.get('x-forwarded-for')?.split(',')[0].trim()||req.headers.get('x-real-ip')||'unknown';const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);const source=Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(ip)))).map(b=>b.toString(16).padStart(2,'0')).join('');
 const saved=await db.rpc('register_quote_request',{p_key:body.key,p_recipient:userId,p_details:details,p_transaction:transaction,p_source:source});if(saved.error)return response(503,{message:'Your request could not be saved. Please wait a moment and try again.'});
 const record=await db.from('portal_quote_requests').select('reference').eq('id',saved.data).single();return response(201,{reference:record.data?.reference,message:'Your request has been saved. You will receive an email shortly.'});
});
