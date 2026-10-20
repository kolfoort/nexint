import { PDFDocument, StandardFonts, rgb } from './assets/vendor/pdf-lib.esm.min.js';
import { layout } from './nda-layout.js';
const $=id=>document.getElementById(id);
const specs=[['B_COMPANY','Legal company name',100,true],['B_REGISTRATION','Company registration number',60,true],['B_ADDRESS','Registered address',150,true],['B_COUNTRY','Country of incorporation',60,true],['B_REPRESENTATIVE','Authorized representative',80,true],['B_TITLE','Position / title',80,true],['B_PHONE','Telephone',50,true],['B_EMAIL','Business email',100,true],['B_WEBSITE','Website',100,false]];
const dateText=d=>new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Amsterdam',day:'numeric',month:'long',year:'numeric'}).format(d);
function fit(page,text,font,rect,size=9){let [x,y,r,t]=rect;while(font.widthOfTextAtSize(text,size)>r-x && size>6)size-=.25;if(font.widthOfTextAtSize(text,size)>r-x)throw new Error('A company detail is too long to fit. Please shorten the address or company name.');font.encodeText(text);page.drawText(text,{x,y:y+2,size,font,color:rgb(0,.125,.25)});}
export async function createNda(values,signature,stamp,{now=new Date(),reference='',email='',loadTemplate}={}){
 if(!loadTemplate)throw new Error('The private NDA template is not available. Please contact Nexora.');
 const pdf=await PDFDocument.load(await loadTemplate()),font=await pdf.embedFont(StandardFonts.Helvetica),datesFont=await pdf.embedFont(StandardFonts.TimesRoman),pages=pdf.getPages();
 const day=dateText(now);
 for(const field of layout.fields){if(field.signature)continue;fit(pages[field.page],field.key==='B_SIGNATURE_DATE'?day:values[field.key]||'',font,field.rect,field.page===1?8:9);}
 for(const d of layout.dates){let size=d.size;while(datesFont.widthOfTextAtSize(day,size)>d.width)size-=.1;pages[d.page].drawText(day,{x:d.x,y:d.y+1,size,font:datesFont,color:rgb(0,.125,.25)});}
 const last=pages[7];
 // A separate signature and stamp area replaces only the original blank Party B signing lines.
 last.drawRectangle({x:35,y:276,width:510,height:139,color:rgb(1,1,1)});
 last.drawText('Signature of authorized representative',{x:36,y:400,size:8,font,color:rgb(0,.125,.25)});
 last.drawText('Company stamp',{x:325,y:400,size:8,font,color:rgb(0,.125,.25)});
 async function imageIn(data,box){const img=await pdf.embedPng(data),scale=Math.min(box.w/img.width,box.h/img.height);last.drawImage(img,{x:box.x+(box.w-img.width*scale)/2,y:box.y+(box.h-img.height*scale)/2,width:img.width*scale,height:img.height*scale});}
 if(signature)await imageIn(signature,{x:36,y:316,w:255,h:78});
 if(stamp)await imageIn(stamp,{x:325,y:300,w:180,h:94});
 last.drawLine({start:{x:36,y:313},end:{x:290,y:313},thickness:.4,color:rgb(.65,.7,.75)});
 last.drawText('Date: '+day,{x:36,y:296,size:9,font});
 last.drawText('Portal submission: '+reference,{x:36,y:264,size:7,font});
 last.drawText('Account: '+email+' | Submitted: '+now.toISOString(),{x:36,y:252,size:7,font});
 last.drawText('Electronic signature: drawn by the representative; no certificate-based digital signature.',{x:36,y:240,size:7,font});
 pdf.setTitle('Nexora MCNDA - '+values.B_COMPANY);pdf.setCreationDate(now);pdf.setModificationDate(now);
 return new Blob([await pdf.save()],{type:'application/pdf'});
}
async function imageFile(file){
 if(!file || !['image/png','image/jpeg'].includes(file.type)||file.size>5*1024*1024)throw new Error('Choose a PNG or JPG smaller than 5 MB.');
 const bitmap=await createImageBitmap(file);try{if(bitmap.width*bitmap.height>24000000)throw new Error('This image is too large. Please use a smaller image.');const c=document.createElement('canvas');const scale=Math.min(1,1400/Math.max(bitmap.width,bitmap.height));c.width=Math.round(bitmap.width*scale);c.height=Math.round(bitmap.height*scale);c.getContext('2d').drawImage(bitmap,0,0,c.width,c.height);return c.toDataURL('image/png');}finally{bitmap.close();}
}
export function bindNda({db,member,check,action,message,onSubmitted}){
 const form=$('nda-form'),container=$('nda-fields');let signed=false,stamp=null,signatureImage=null,review=null,revision=0,stampLoading=false,stampRevision=0;
 for(const [key,label,max,required] of specs){const wrap=document.createElement('div'),l=document.createElement('label'),input=document.createElement('input');l.htmlFor=key;l.textContent=label+(required?'':' (optional)');input.id=key;input.name=key;input.maxLength=max;input.required=required;if(key==='B_EMAIL'){input.type='email';input.value=member.email;}wrap.append(l,input);container.append(wrap);}
 const canvas=$('nda-signature'),ctx=canvas.getContext('2d');ctx.strokeStyle='#002040';ctx.lineWidth=2.4;ctx.lineCap='round';ctx.lineJoin='round';let drawing=false,last=null;
 function invalidate(){revision++;if(review){URL.revokeObjectURL(review.url);review=null;}$('nda-review').hidden=true;$('nda-frame').src='about:blank';$('nda-confirm').checked=false;}
 form.addEventListener('input',e=>{if(e.target.id!=='nda-confirm')invalidate();});
 function point(e){const r=canvas.getBoundingClientRect();return[(e.clientX-r.left)*canvas.width/r.width,(e.clientY-r.top)*canvas.height/r.height];}
 canvas.addEventListener('pointerdown',e=>{if(e.button!==0)return;e.preventDefault();canvas.setPointerCapture(e.pointerId);drawing=true;last=point(e);invalidate();signatureImage=null;$('nda-signature-file').value='';});
 canvas.addEventListener('pointermove',e=>{if(!drawing)return;const p=point(e);ctx.beginPath();ctx.moveTo(...last);ctx.lineTo(...p);ctx.stroke();last=p;signed=true;});
 for(const ev of ['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(ev,()=>{drawing=false;});
 $('nda-clear').addEventListener('click',()=>{ctx.clearRect(0,0,canvas.width,canvas.height);signed=false;signatureImage=null;$('nda-signature-file').value='';invalidate();});
 $('nda-signature-file').addEventListener('change',()=>action($('nda-preview'),async()=>{invalidate();signed=false;signatureImage=null;ctx.clearRect(0,0,canvas.width,canvas.height);if(!$('nda-signature-file').files[0])return;try{const data=await imageFile($('nda-signature-file').files[0]);const img=new Image();img.src=data;await img.decode();const s=Math.min(canvas.width/img.width,canvas.height/img.height);ctx.drawImage(img,(canvas.width-img.width*s)/2,(canvas.height-img.height*s)/2,img.width*s,img.height*s);signatureImage=data;signed=true;}catch(e){message(e.message);}}));
 $('nda-stamp').addEventListener('change',async()=>{invalidate();stamp=null;$('nda-stamp-preview').hidden=true;const f=$('nda-stamp').files[0];if(!f)return;const current=++stampRevision;stampLoading=true;$('nda-preview').disabled=true;try{const data=await imageFile(f);if(current!==stampRevision)return;stamp=data;$('nda-stamp-preview').src=data;$('nda-stamp-preview').hidden=false;}catch(e){message(e.message);$('nda-stamp').value='';}finally{stampLoading=false;$('nda-preview').disabled=false;}});
 form.addEventListener('submit',e=>{e.preventDefault();action($('nda-preview'),async()=>{
  if(!form.reportValidity())return;if(!signed){message('Please draw your signature or upload a signature image.');return;}if(stampLoading)return;
  invalidate();const current=revision,values=Object.fromEntries(specs.map(([k])=>[k,form.elements[k].value.trim()]));if(specs.some(([k,,,required])=>required&&!values[k])){message('Please complete all required company details.');return;}
  const id=crypto.randomUUID(),now=new Date();let blob;
  try{blob=await createNda(values,signatureImage||canvas.toDataURL('image/png'),stamp,{now,reference:id,email:member.email,loadTemplate:async()=>{const result=await db.storage.from('nexora-documents').download('nda-template-v20261020.pdf');if(result.error)throw new Error('The private NDA template has not been enabled for your account. Please contact Nexora.');return result.data.arrayBuffer();}});}catch(error){message(error.message.includes('WinAnsi')?'A character cannot be included in the PDF. Please use Latin characters for the company details.':error.message);return;}
  if(current!==revision)return;const url=URL.createObjectURL(blob);review={id,blob,url,values,now,hasStamp:!!stamp};$('nda-frame').src=url;$('nda-download').href=url;$('nda-download').download='Nexora_MCNDA_Review.pdf';$('nda-review').hidden=false;message('Review all pages of the PDF, then confirm and submit.');$('nda-review').scrollIntoView({behavior:'smooth'});
 });});
 $('nda-submit').addEventListener('click',()=>action($('nda-submit'),async()=>{
  if(!review||!$('nda-confirm').checked){message('Review the PDF and confirm your authority and agreement before submitting.');return;}
  if(dateText(review.now)!==dateText(new Date())){invalidate();message('The date has changed. Please generate a new preview.');return;}
  const current=review,path=member.user_id+'/'+current.id+'.pdf';if(current.blob.size>20*1024*1024){message('The PDF exceeds 20 MB. Please use smaller images.');return;}
  check(await db.storage.from('nexora-client-uploads').upload(path,current.blob,{contentType:'application/pdf',upsert:false}));
  const result=await db.from('portal_submissions').insert({id:current.id,user_id:member.user_id,title:('MCNDA - '+current.values.B_COMPANY).slice(0,180),note:'Completed and electronically signed via the Nexora portal. Template 2026-10-20. Reference: '+current.id+'. Account: '+member.email+'. Submitted: '+current.now.toISOString()+'. Company stamp: '+(current.hasStamp?'included':'not supplied')+'. Representative confirmed authority and agreement.',storage_path:path});
  if(result.error){await db.storage.from('nexora-client-uploads').remove([path]);throw result.error;}
  $('nda-result-download').href=current.url;$('nda-result-download').download='Nexora_MCNDA_Submitted.pdf';$('nda-success').hidden=false;$('nda-review').hidden=true;form.hidden=true;message('Your signed NDA has been submitted to Nexora for review. You can download it below or from Your shared documents.');await onSubmitted();
 }));
 window.addEventListener('pagehide',()=>{if(review)URL.revokeObjectURL(review.url);});
}
