import {getLanguage} from './portal-language.js?v=20261029-whatsapp1';
export async function mountCounterpartyRole({db,userId,container,message,individual=false}){
 if(individual){const p=document.createElement('p');p.textContent=({en:'Personal account · Broker / Introducer in a personal capacity. Any company representation is recorded separately.',nl:'Persoonlijk account · Broker / Introducer op persoonlijke titel. Eventuele bedrijfsvertegenwoordiging wordt afzonderlijk vastgelegd.',de:'Persönliches Konto · Vermittler/Broker in persönlicher Eigenschaft. Eine Unternehmensvertretung wird gesondert erfasst.',es:'Cuenta personal · Intermediario/Broker a título personal. La representación de una empresa se registra por separado.',ar:'حساب شخصي · وسيط بصفة شخصية. يُسجَّل تمثيل الشركة، إن وجد، بشكل منفصل.'})[getLanguage()];container.append(p);return;}
 const labels={introducer_broker:'Introducer / Broker',end_buyer_user:'End Buyer / End User',jv_partner:'JV Partner',trader_reseller:'Trader / Reseller',supplier_seller:'Supplier / Seller'};
 const form=document.createElement('form');form.className='counterparty-role';
 const heading=document.createElement('h3');heading.textContent='Counterparty type';
 const label=document.createElement('label');label.textContent='Role in the transaction';
 const select=document.createElement('select');select.required=true;select.name='counterparty_role';
 const placeholder=new Option('Select counterparty type','');select.add(placeholder);
 for(const [value,text] of Object.entries(labels))select.add(new Option(text,value));label.append(select);
 const note=document.createElement('p');note.className='account';note.textContent='End Buyer / End User means the final purchaser or consumer of the product. This classification does not grant access to another client’s documents or commissions.';
 const status=document.createElement('p');status.setAttribute('role','status');
 const button=document.createElement('button');button.type='submit';button.textContent='Save counterparty type';button.className='secondary';button.disabled=true;
 form.append(heading,label,note,status,button);container.append(form);
 const result=await db.from('portal_counterparty_roles').select('counterparty_role').eq('user_id',userId).maybeSingle();
 if(result.error){status.textContent='Counterparty type could not be loaded. Refresh or contact Nexora.';return;}
 select.value=result.data?.counterparty_role||'';status.textContent=result.data?labels[select.value]:'Not yet specified';button.disabled=false;
 form.addEventListener('submit',async e=>{e.preventDefault();if(!form.reportValidity())return;button.disabled=true;try{const saved=await db.rpc('save_counterparty_role',{p_user_id:userId,p_role:select.value});if(saved.error)throw saved.error;status.textContent=labels[select.value]+' — saved';message?.('Counterparty type saved.');}catch(error){status.textContent=error.message||'Unable to save counterparty type.';}finally{button.disabled=false;}});
}
