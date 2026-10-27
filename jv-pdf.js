import {PDFDocument,StandardFonts,rgb} from './assets/vendor/pdf-lib.esm.min.js';
import {fields} from './jv-fields.js?v=20261027-jv1';
const norm=s=>String(s??'').replace(/<br\s*\/?\s*>/gi,'\n').replace(/<[^>]*>/g,'').replace(/[\u2011\u2013\u2014]/g,'-').replace(/[\u2018\u2019]/g,"'").replace(/[\u201c\u201d]/g,'"').replace(/[^\x20-\x7e\xa0-\xff\n]/g,'?');
export async function createJVPDF(a,template,assets=null,previewImages=null,review=null){
 const d=a.data||{};
 if(assets&&(!d.client_signature?.schedules_accepted||!d.client_signing_assets||!d.approval_request))throw Error('Party B must sign the entire agreement before Nexora countersigns.');
 const pdf=await PDFDocument.create(),font=await pdf.embedFont(StandardFonts.Helvetica),bold=await pdf.embedFont(StandardFonts.HelveticaBold),serif=await pdf.embedFont(StandardFonts.TimesRomanBold);
 const bytes=await(await fetch('nexora-logo.jpg')).arrayBuffer();const logo=await pdf.embedPng(bytes);let page,y;
 const navy=rgb(.024,.11,.188),grey=rgb(.32,.38,.44),gold=rgb(.85,.67,.25),g=k=>d[k]===undefined||d[k]===''?'[TO COMPLETE]':String(d[k]);
 function newPage(){page=pdf.addPage([595,842]);page.drawImage(logo,{x:44,y:785,width:152,height:50});page.drawText('JOINT VENTURE AGREEMENT',{x:350,y:812,size:8,font:bold,color:navy});page.drawText('NEXORA INTERNATIONAL',{x:385,y:798,size:7,font,color:grey});page.drawLine({start:{x:44,y:773},end:{x:551,y:773},thickness:1,color:gold});y=749}
 function lines(t,size,width,f=font){const out=[];for(const para of norm(t).split('\n')){let line='';for(const word of para.split(/\s+/)){if(f.widthOfTextAtSize(line+(line?' ':'')+word,size)>width&&line){out.push(line);line=''}if(f.widthOfTextAtSize(word,size)>width){for(const c of word){if(f.widthOfTextAtSize(line+c,size)>width){out.push(line);line=''}line+=c}}else line+=(line?' ':'')+word}out.push(line)}return out}
 function text(t,size=9,f=font){for(const l of lines(t,size,507,f)){if(y<63)newPage();page.drawText(l,{x:44,y,size,font:f,color:navy});y-=size*1.43}y-=7}
 function heading(t){if(y<118)newPage();y-=7;text(t,14,serif)}
 function row(label,value){const ls=lines(label,8.3,145,bold),vs=lines(value||'[TO COMPLETE]',8.5,335);while(ls.length||vs.length){if(y<95)newPage();const max=Math.max(1,Math.floor((y-70)/12)),l=ls.splice(0,max),v=vs.splice(0,max),h=Math.max(l.length,v.length)*12+12;page.drawRectangle({x:44,y:y-h+4,width:159,height:h,color:rgb(.95,.96,.975)});page.drawLine({start:{x:44,y:y-h+4},end:{x:551,y:y-h+4},thickness:.3,color:rgb(.85,.88,.91)});l.forEach((t,i)=>page.drawText(t,{x:50,y:y-8-i*12,size:8.3,font:bold,color:navy}));v.forEach((t,i)=>page.drawText(t,{x:212,y:y-8-i*12,size:8.5,font,color:navy}));y-=h}}
 newPage();heading('Joint Venture Agreement');text('Nexora International & '+(d.buyer||'Party B'),17,serif);text(a.transaction_code+' | Version '+a.version+' | Terms '+template.version,8);
 text(assets?'FINAL - BOTH PARTIES SIGNED':d.client_signature?'PARTY B SIGNED - AWAITING NEXORA COUNTERSIGNATURE':a.status==='draft'?'DRAFT - FOR REVIEW ONLY - NOT FOR SIGNATURE':'UNSIGNED - FOR REVIEW',9,bold);
 row('Party A','Nexora International\nHerengracht 208, 1016 BS Amsterdam, The Netherlands\n'+g('a_identity')+'\nJ.P. Kolfoort | MD | info@nexint.eu');
 row('Party B',[d.buyer,d.registration,d.buyer_address,d.buyer_country,[d.representative,d.buyer_role].filter(Boolean).join(' | '),d.buyer_email].filter(Boolean).join('\n')||'[Approved company profile required]');
 row('Project',g('project_ref'));row('Net profit allocation','Nexora '+g('a_percent')+'% / Party B '+g('b_percent')+'%');row('Governing law / forum','Dutch law | Competent court of Amsterdam, subject to mandatory jurisdiction rules');
 text('These percentages apply to Net Distributable Profit, not company shares. Funding, losses and liability are separately agreed in Schedule A. This entire agreement and Schedules A and B require Party B acceptance before Nexora final approval.',9);
 if(d.buyer_profile_id)text('Frozen company profile: '+d.buyer_profile_id+' | Version '+d.buyer_profile_version,7);
 newPage();heading('Contractual terms');
 for(let i=0;i<template.terms.length;i++){
  const [h,body]=template.terms[i];let t=body;
  if(i===0)t='This Joint Venture Agreement (Agreement) is entered into on '+g('effective_date')+' between Nexora International (Nexora or Party A), identified above and in Schedule A, represented by J.P. Kolfoort, MD; and '+(d.buyer||'[PARTY B]')+' (Party B), identified above from its approved company profile. Each is a Party and together the Parties.\n'+body.slice(body.indexOf("Party B's details"));
  if(i===9)t=t.replace('Nexora: [___]%','Nexora: '+g('a_percent')+'%').replace('Party B: [___]%','Party B: '+g('b_percent')+'%');
  if(y<150)newPage();text(h,11,bold);text(t,9);
 }
 newPage();heading('Schedule A | Signed commercial terms');text('All financial selections below form part of this exact agreement. No unspecified default percentage applies. Any agreed changes require a newly signed version.',9);
 for(const [key,label] of fields.filter(f=>f[2]!=='operating'&&f[0]!=='introductions'))row(label,g(key));
 newPage();heading('Schedule A | Operating arrangements');for(const [key,label] of fields.filter(f=>f[2]==='operating'&&f[0]!=='introductions'))row(label,g(key));
 newPage();heading('Schedule B | Protected introductions');text(g('introductions'));text('Each protected introduction must identify the introducing Party, contact and organisation, specific opportunity, introduction date and evidence, exclusions, agreed remuneration reference and acknowledgement by both Parties. None means no introductions are protected under this schedule. Clause 16 governs scope and duration.',9);
 heading('Electronic execution record');text('Each signatory confirms authority, receipt and acceptance of the complete Agreement and both Schedules, and express consent to apply its saved signature and company stamp to this exact version. Later company-profile edits do not alter this signed record.',9);
 async function imagePair(images){if(y<185)newPage();for(const [key,x,mw,mh] of [['signature',46,190,65],['stamp',350,90,85]]){if(!images?.[key])continue;const raw=images[key].split(',').pop(),img=await pdf.embedPng(Uint8Array.from(atob(raw),c=>c.charCodeAt(0))),s=Math.min(mw/img.width,mh/img.height);page.drawImage(img,{x,y:y-88,width:img.width*s,height:img.height*s})}y-=99}
 heading('Party B | '+(d.buyer||'[COMPANY]'));text(g('representative')+' | '+g('buyer_role')+'\nAcceptance: '+(d.client_signature?.at||'Not signed'),9);
 const images=d.client_signing_assets||previewImages;if(images){await imagePair(images);text(d.client_signature?'Party B accepted the entire Agreement and both Schedules.':'Preview of your saved signing images only. This document is not yet signed.',8)}
 heading('Nexora International');text('J.P. Kolfoort | MD | info@nexint.eu',9);
 if(assets){await imagePair(assets);text('Nexora final approval: '+d.approval_request.at+'\nBy: '+d.approval_request.by,8)}else text('NOT COUNTERSIGNED. JP\'s signature and Nexora stamp are added only after Party B has signed the entire Agreement and both Schedules, followed by Nexora final approval.',9,bold);
 text('Party B reviewed-content SHA256: '+(d.signed_payload_hash||review?.hash||'[not yet signed]'),6.8);text('Authenticated electronic acceptance with retained audit history. No qualified electronic-signature certificate is asserted.',7);
 pdf.getPages().forEach((p,i)=>{p.drawLine({start:{x:44,y:44},end:{x:551,y:44},thickness:.5,color:gold});p.drawText(norm(a.transaction_code+' | v'+a.version+' | '+(assets?'FINAL':'PREVIEW')),{x:44,y:29,size:7,font,color:grey});p.drawText((i+1)+' / '+pdf.getPageCount(),{x:520,y:29,size:7,font,color:grey})});pdf.setTitle('Joint Venture Agreement | '+a.transaction_code);pdf.setAuthor('Nexora International');return pdf.save();
}
