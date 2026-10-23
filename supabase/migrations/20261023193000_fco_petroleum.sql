begin;
create table public.fco_templates(version text primary key,terms jsonb not null,products jsonb not null,created_at timestamptz not null default now());
create table public.fco_counters(year integer primary key,value integer not null);
create table public.fco_agreements(id uuid primary key default gen_random_uuid(),recipient uuid not null references public.portal_members(user_id),company_id uuid not null references public.portal_companies(id),template_version text not null references public.fco_templates(version),transaction_code text not null,version integer not null default 1,revision integer not null default 1,status text not null default 'draft' check(status in ('draft','awaiting_client','awaiting_approval','completed','cancelled')),data jsonb not null,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),created_by uuid not null references public.portal_members(user_id),unique(transaction_code,version));
create index fco_recipient on public.fco_agreements(recipient,created_at desc);
create table public.fco_events(id bigint generated always as identity primary key,agreement_id uuid not null references public.fco_agreements(id),actor uuid not null,actor_email text not null,event text not null,details jsonb not null default '{}',created_at timestamptz not null default now());
create table public.fco_final_pdfs(agreement_id uuid primary key references public.fco_agreements(id),pdf_base64 text not null,pdf_sha256 text not null,created_at timestamptz not null default now());
create table public.fco_reviews(token uuid primary key default gen_random_uuid(),agreement_id uuid not null references public.fco_agreements(id),actor uuid not null,revision integer not null,payload_hash text not null,asset_version uuid,created_at timestamptz not null default now());
alter table public.fco_templates enable row level security;
alter table public.fco_agreements enable row level security;
alter table public.fco_events enable row level security;
alter table public.fco_final_pdfs enable row level security;
alter table public.fco_counters enable row level security;
alter table public.fco_reviews enable row level security;
revoke all on public.fco_templates,public.fco_agreements,public.fco_events,public.fco_final_pdfs,public.fco_counters,public.fco_reviews from public,anon,authenticated;
grant select on public.fco_templates,public.fco_agreements,public.fco_events,public.fco_final_pdfs to authenticated;
create policy fco_template_read on public.fco_templates for select to authenticated using((select portal_private.is_active()));
create policy fco_agreement_read on public.fco_agreements for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or (recipient=(select auth.uid()) and status<>'draft')));
create policy fco_event_read on public.fco_events for select to authenticated using(exists(select 1 from public.fco_agreements a where a.id=agreement_id));
create policy fco_pdf_read on public.fco_final_pdfs for select to authenticated using(exists(select 1 from public.fco_agreements a where a.id=agreement_id and a.status='completed'));
insert into public.fco_templates(version,terms,products) values('2026-10-23-fco-v1',$terms$[{"title": "Commercial and supply terms", "blocks": [{"text": "Pricing and invoicing", "heading": true}, {"text": "The price is the arithmetic average of S&P Global Platts Diesel 10 ppm FOB ARA quotations, code AAXRW00, less USD 40 per MT, for the bill of lading date minus one day, the bill of lading date and the bill of lading date plus one day. The SPA must specify the treatment of non-publication days. The final invoice is based on independently certified loaded quantity and the agreed pricing formula.", "heading": false}, {"text": "Supply programme", "heading": true}, {"text": "The proposed programme runs for thirty-six months, with an initial trial cargo of 100,000 MT and subsequent supply of up to 100,000 MT per month. Monthly quantities are proposed supply capability, subject to a mutually agreed lifting schedule and a \u00b15% tolerance unless the SPA states otherwise. Any extension requires mutual written agreement.", "heading": false}, {"text": "Each lifting depends on refinery allocation, terminal scheduling, operational readiness, destination approval, suitable vessel availability and the final SPA. This FCO does not guarantee an allocation, vessel or monthly volume.", "heading": false}, {"text": "Delivery and destination costs", "heading": true}, {"text": "CFR delivery includes cargo supply and ocean transportation to the agreed discharge port. Unless otherwise stated in the SPA or included in the contract of carriage, the Buyer bears discharge and receiving terminal costs, import duties, taxes, customs clearance and destination-specific charges. The SPA must allocate these costs expressly.", "heading": false}, {"text": "Houston (USHOU) is the indicated destination. The exact port, receiving terminal, destination fuel requirements and acceptance conditions must be confirmed before contracting. Delivery remains subject to route safety, vessel and terminal acceptance and compliance clearance.", "heading": false}, {"text": "Product quality and inspection", "heading": true}, {"text": "The proposed product is export-grade ULSD EN590 10 PPM from a refinery allocation subject to compliance clearance. Appendix I contains the offered indicative parameters. The complete contractual specification, applicable edition of EN590 and destination-specific seasonal requirements must be agreed in the SPA.", "heading": false}, {"text": "Cargo must be free from contamination, adulteration and prohibited substances. Blending, commingling or additive modification requires the parties\u2019 written agreement. SGS, Intertek, Bureau Veritas or a mutually agreed equivalent shall perform independent quantity and quality inspection. Loading certificates are final and binding subject to the re-testing and dispute procedures agreed in the SPA.", "heading": false}]}, {"title": "Transaction and payment procedure", "blocks": [{"text": "1  Buyer qualification", "heading": true}, {"text": "Buyer submits an LOI addressed to Nexora International, corporate profile, KYC package and a bank comfort letter covering the estimated value of three months of proposed deliveries. Nexora conducts corporate, banking, AML, sanctions and commercial due diligence.", "heading": false}, {"text": "2  Transaction meeting and SPA", "heading": true}, {"text": "Following satisfactory due diligence, Nexora arranges a transaction meeting remotely or at a mutually agreed location. The parties confirm specifications, logistics, inspection, documentation, payment milestones and the definitive SPA.", "heading": false}, {"text": "3  Advance payment and nomination", "heading": true}, {"text": "After both parties execute the SPA, Buyer transfers 30% of the estimated value of the relevant monthly lifting to the verified account designated in the SPA. After cleared receipt, Nexora arranges a suitable tanker and coordinates loading, subject to operational availability and terminal acceptance.", "heading": false}, {"text": "4  Loading and independent inspection", "heading": true}, {"text": "Independent quantity and quality inspection is completed after loading. Inspection is at Buyer\u2019s expense unless the SPA states otherwise. Nexora provides the certificates and other documents required for the balance payment under the SPA.", "heading": false}, {"text": "5  Balance payment and sailing", "heading": true}, {"text": "Buyer transfers the remaining 70%, adjusted to the final invoice, following issuance of the agreed independent quantity and quality certificates. Sailing proceeds after confirmed cleared payment, subject to port clearance and operational requirements.", "heading": false}, {"text": "6  Recurring monthly liftings", "heading": true}, {"text": "The agreed 30% / 70% mechanism repeats for each monthly lifting. Nexora coordinates cargo tracking, voyage updates and operational support to the nominated discharge port.", "heading": false}, {"text": "Payments are by bank transfer. The BCL is evidence of financial capability; it is not a payment instrument or a substitute for cleared funds. No DLC or SBLC forms part of the offered payment mechanism.", "heading": false}]}, {"title": "Qualification and documentation", "blocks": [{"text": "Buyer qualification package", "heading": true}, {"text": "The Buyer provides the following documents for verification before SPA execution. Nexora may request additional evidence appropriate to the Buyer, bank, jurisdiction or proposed transaction.", "heading": false}, {"text": "\u2022 Letter of intent confirming product, quantity, delivery basis and proposed destination.", "heading": false}, {"text": "\u2022 Corporate profile, certificate of incorporation and recent registry extract or certificate of good standing.", "heading": false}, {"text": "\u2022 Ownership and ultimate beneficial owner declaration.", "heading": false}, {"text": "\u2022 Authorized representative identification and board resolution or power of attorney, where applicable.", "heading": false}, {"text": "\u2022 Bank comfort letter from a financial institution acceptable to Nexora, covering three months of proposed deliveries; additional proof of funds or banking readiness as agreed.", "heading": false}, {"text": "\u2022 Sanctions, AML and anti-corruption declarations; destination and end-use declaration.", "heading": false}, {"text": "\u2022 Bank details and banking officer contact information, subject to verification.", "heading": false}, {"text": "Shipment documentation", "heading": true}, {"text": "The definitive SPA shall state the exact documents, timing and delivery method. The indicative package comprises:", "heading": false}, {"text": "\u2022 Commercial invoice; certificate of origin; certificates of quantity and quality; independent inspection report.", "heading": false}, {"text": "\u2022 Full set clean on-board ocean bills of lading; cargo manifest; ullage report; notice of readiness.", "heading": false}, {"text": "\u2022 Port clearance and export authorizations; vessel particulars and Q88 where applicable.", "heading": false}, {"text": "\u2022 Insurance documentation where applicable and additional documents required by law, terminal rules or the agreed destination.", "heading": false}, {"text": "Maritime coordination", "heading": true}, {"text": "Nexora coordinates vessel nomination, voyage planning, port agency liaison, loading, documentation and voyage reporting through appointed carriers and service providers. Suitable product tankers remain subject to vetting, flag state requirements, chartering availability, terminal acceptance and voyage feasibility. No particular fleet size or dedicated vessel allocation is represented.", "heading": false}]}, {"title": "Conditions and acknowledgment", "blocks": [{"text": "Compliance and withdrawal", "heading": true}, {"text": "Transactions are subject to applicable EU, UK, US and UN sanctions, AML and KYC controls, anti-bribery requirements and relevant maritime, environmental and safety rules. Nexora may reject any Buyer, bank, payment route, vessel, jurisdiction or destination that does not meet its compliance and commercial requirements. Nexora may amend, suspend or withdraw this indicative offer before SPA execution.", "heading": false}, {"text": "Confidentiality and introduced relationships", "heading": true}, {"text": "This FCO and related transaction information are intended for the named recipient and must not be disclosed without Nexora\u2019s written consent. The parties shall not circumvent relationships introduced in connection with the programme. Any separately executed confidentiality or non-circumvention agreement governs those obligations according to its terms.", "heading": false}, {"text": "Governing law and dispute resolution", "heading": true}, {"text": "The proposed governing law is the law of England and Wales. Disputes under the definitive SPA shall be referred to LCIA arbitration seated in London, in English. The parties must expressly confirm the governing law and forum in that SPA. This FCO remains subject to contract and does not itself create a binding sale and purchase agreement.", "heading": false}, {"text": "Buyer acknowledgment", "heading": true}, {"text": "Buyer may indicate its intention to proceed by submitting an LOI and the qualification package. Acknowledgment of this FCO does not replace the definitive SPA or create a cargo allocation or payment obligation.", "heading": false}]}, {"title": "Appendix I  Product specification", "blocks": [{"text": "ULSD EN590 10 PPM automotive diesel. Origin and refinery are allocation dependent. These offered parameters must be read with the complete specification agreed in the SPA; this summary is not an exhaustive statement of EN590 conformity.", "heading": false}, {"text": "Destination and seasonal requirements", "heading": true}, {"text": "The SPA must confirm the applicable climate grade, seasonal cold-flow limits, destination fuel regulations and any additional contractual tests. The independent loading certificate of quality confirms the tested cargo parameters, subject to the sampling, re-testing and dispute procedures in the SPA.", "heading": false}]}]$terms$::jsonb,$products${"EN590": {"name": "EN590 10 ppm ULSD", "standard": "EN 590:2025", "fields": [["sulphur", "Maximum sulphur / unit"], ["fame", "FAME grade / maximum"], ["cfpp", "Seasonal class / CFPP"], ["density", "Density range / reference temperature"]]}, "RON95": {"name": "RON95 unleaded petrol", "standard": "EN 228:2025", "fields": [["ron", "Minimum RON"], ["mon", "Minimum MON"], ["ethanol", "E5 / E10 and oxygen limits"], ["vapour", "Seasonal vapour-pressure class"]]}, "JET_A1": {"name": "Jet A-1 aviation turbine fuel", "standard": "ASTM D1655-26b", "fields": [["freeze", "Maximum freezing point"], ["flash", "Minimum flash point"], ["additives", "Approved additives / limits"], ["aviation", "Aviation quality / release requirements"]]}}$products$::jsonb);
create function portal_private.fco_edit_fields(p_data jsonb) returns jsonb language plpgsql set search_path='' as $$
declare d jsonb:='{}'; k text; t jsonb:='{}';
begin
 if jsonb_typeof(p_data) is distinct from 'object' or length(p_data::text)>4500000 then raise exception 'Invalid commercial details';end if;
 foreach k in array array['title','product','standard','incoterm','quantity','months','lot','issue_date','validity','benchmark','quotation_code','differential','price_calendar','specification','destination','spec_filename','spec_pdf','spec_sha256'] loop
 if jsonb_typeof(p_data->k) not in ('string','number') and p_data ? k then raise exception 'Invalid field %',k;end if;
 if length(coalesce(p_data->>k,''))>(case when k='spec_pdf' then 4200000 when k='specification' then 12000 else 2000 end) then raise exception 'Field % is too long',k;end if;
 d:=d||jsonb_build_object(k,trim(coalesce(p_data->>k,'')));end loop;
 if coalesce(d->>'spec_pdf','')<>'' then
 if length(decode(d->>'spec_pdf','base64'))>3000000 or substring(decode(d->>'spec_pdf','base64') from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Upload a PDF smaller than 3 MB';end if;
 d:=d||jsonb_build_object('spec_sha256',encode(sha256(decode(d->>'spec_pdf','base64')),'hex'));
 end if;
 d:=d||jsonb_build_object('spec_confirmed',coalesce(p_data->'spec_confirmed'='true'::jsonb,false),'commercial_confirmed',coalesce(p_data->'commercial_confirmed'='true'::jsonb,false));
 return d;
end;$$;
revoke all on function portal_private.fco_edit_fields(jsonb) from public,anon,authenticated;
create function portal_private.fco_validate(d jsonb) returns void language plpgsql set search_path='' as $$
declare k text;
begin
 foreach k in array array['buyer','registration','buyer_address','buyer_country','representative','buyer_role','buyer_email','product','standard','quantity','months','lot','issue_date','validity','incoterm','destination','benchmark','quotation_code','differential','price_calendar','spec_filename','spec_pdf','spec_sha256'] loop
 if trim(coalesce(d->>k,''))='' then raise exception 'Complete % before assignment',replace(k,'_',' ');end if;end loop;
 if d->>'product' not in ('EN590','RON95','JET_A1') or d->>'incoterm' not in ('FOB','CFR','CIF') then raise exception 'Select product and delivery rule';end if;
 foreach k in array array['quantity','months','lot','validity'] loop
 if d->>k !~ '^[0-9]+([.][0-9]+)?$' or (d->>k)::numeric<=0 or (d->>k)::numeric>1000000000 then raise exception 'Invalid %',k;end if;end loop;
 if (d->>'months')::numeric<>trunc((d->>'months')::numeric) or (d->>'months')::numeric>120 then raise exception 'Duration must be 1 to 120 whole months';end if;
 if (d->>'validity')::numeric<>trunc((d->>'validity')::numeric) or (d->>'validity')::numeric>365 then raise exception 'Validity must be 1 to 365 whole days';end if;
 if d->>'differential' !~ '^-?[0-9]+([.][0-9]+)?$' then raise exception 'Differential must be numeric';end if;
 if (d->>'issue_date')::date<date '2020-01-01' or (d->>'issue_date')::date+(d->>'validity')::integer<current_date then raise exception 'Set a current issue date and validity';end if;
 if d->>'buyer_email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'Company business email is invalid';end if;
 foreach k in array array['standard','destination','benchmark','quotation_code','price_calendar'] loop if d->>k like '%[%' then raise exception 'Replace the placeholder in % before assignment',k;end if;end loop;
 if d->'spec_confirmed' is distinct from 'true'::jsonb or d->'commercial_confirmed' is distinct from 'true'::jsonb then raise exception 'Confirm the attached specification and commercial terms';end if;
 if encode(sha256(decode(d->>'spec_pdf','base64')),'hex') is distinct from d->>'spec_sha256' then raise exception 'Specsheet checksum mismatch';end if;
end;$$;
revoke all on function portal_private.fco_validate(jsonb) from public,anon,authenticated;
create function public.fco_review(p_id uuid,p_revision integer,p_asset_version uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.fco_agreements; r public.fco_reviews; profile public.portal_signing_profiles; h text;
begin
 if not portal_private.is_active() then raise exception 'Active account required';end if;
 select * into a from public.fco_agreements where id=p_id;
 if not found or (not portal_private.is_admin() and (a.recipient<>auth.uid() or a.status='draft')) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh';end if;
 if not portal_private.is_admin() and a.status='awaiting_client' then
 select * into profile from public.portal_signing_profiles where user_id=auth.uid();
 if not found or profile.version is distinct from p_asset_version then raise exception 'Save signature and stamp, then review again';end if;
 end if;
 h:=encode(sha256(convert_to(a.data::text,'UTF8')),'hex');
 insert into public.fco_reviews(agreement_id,actor,revision,payload_hash,asset_version) values(a.id,auth.uid(),a.revision,h,p_asset_version) returning * into r;
 return jsonb_build_object('token',r.token,'hash',h,'revision',r.revision,'created_at',r.created_at);
end;$$;
revoke all on function public.fco_review(uuid,integer,uuid) from public,anon;
grant execute on function public.fco_review(uuid,integer,uuid) to authenticated;
create function public.fco_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}') returns uuid language plpgsql security definer set search_path='' as $$
declare a public.fco_agreements; d jsonb; profile jsonb; adm boolean; uid uuid:=auth.uid(); email text; rid uuid; y integer; n integer; k text; signing public.portal_signing_profiles; review public.fco_reviews; final_bytes bytea; result uuid; comp public.portal_companies;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active account required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>22000000 then raise exception 'Invalid request';end if;
 if p_action='create' then
 if not adm then raise exception 'Administrator required';end if;
 rid:=(p_payload->>'recipient')::uuid;
 if not exists(select 1 from public.portal_members where user_id=rid and active and not is_admin) then raise exception 'Select an active client';end if;
 profile:=portal_private.spa_profile(rid);
 y:=extract(year from now() at time zone 'Europe/Amsterdam');insert into public.fco_counters values(y,1) on conflict(year) do update set value=public.fco_counters.value+1 returning value into n;
 d:=profile||jsonb_build_object('product','EN590','standard','EN 590:2025','incoterm','CFR','law','ENGLISH','title','FCO Petroleum','months','36','quantity','100000','lot','100000','issue_date',to_char(current_date,'YYYY-MM-DD'),'validity','10','benchmark','S&P Global Platts Diesel 10 ppm FOB ARA','quotation_code','AAXRW00','differential','-40','price_calendar','B/L date minus one publication day, B/L date and B/L date plus one publication day. Confirm publication calendar, time zone and non-publication day treatment.','destination','','spec_pdf','','spec_filename','','specification','','seller',jsonb_build_object('legal_name','La Clava Elit B.V.','business_name','Nexora International','registration','84285699','vat','NL863159825B01','registered_address','Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands','address','Herengracht 208, 1016 BS Amsterdam, The Netherlands','representative','J.P. Kolfoort','role','MD','email','info@nexint.eu'));
 insert into public.fco_agreements(recipient,company_id,template_version,transaction_code,data,created_by) values(rid,(profile->>'buyer_profile_id')::uuid,'2026-10-23-fco-v1','NEX-FCO-'||y||'-'||n,d,uid) returning * into a;
 else
 select * into a from public.fco_agreements where id=p_id for update;
 if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;d:=a.data;
 if p_action<>'sign' and not adm then raise exception 'Administrator required';end if;
 case p_action
 when 'save' then
 if a.status<>'draft' then raise exception 'Only a draft may be edited';end if;
 d:=d||portal_private.fco_edit_fields(p_payload->'data');
 when 'sync_profile' then
 if a.status<>'draft' then raise exception 'Signed or assigned profile snapshots cannot change';end if;
 profile:=portal_private.spa_profile(a.recipient);d:=d||profile;a.company_id:=(profile->>'buyer_profile_id')::uuid;
 when 'issue' then
 if a.status<>'draft' then raise exception 'Only draft agreements may be assigned';end if;
 profile:=portal_private.spa_profile(a.recipient);
 if profile->>'buyer_profile_status'<>'approved' then raise exception 'Approve the company profile before assigning the FCO';end if;
 if profile->>'buyer_profile_id' is distinct from d->>'buyer_profile_id' or profile->>'buyer_profile_version' is distinct from d->>'buyer_profile_version' then raise exception 'Company profile changed; refresh the draft snapshot first';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Client account is disabled';end if;
 perform portal_private.fco_validate(d);a.status:='awaiting_client';
 when 'sign' then
 if adm or uid<>a.recipient or a.status<>'awaiting_client' then raise exception 'Only the assigned buyer may sign';end if;
 perform portal_private.fco_validate(d);
 select * into comp from public.portal_companies where id=a.company_id;
 if comp.access_state<>'active' then raise exception 'Company access is disabled';end if;
 if p_payload->>'name' is distinct from d->>'representative' or p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->'use_saved_assets' is distinct from 'true'::jsonb then raise exception 'Confirm exact authorized name, authority, acceptance and use of saved signing images';end if;
 select * into signing from public.portal_signing_profiles where user_id=uid for share;
 if not found or p_payload->>'asset_version' is distinct from signing.version::text then raise exception 'Signing images changed; save and review again';end if;
 select * into review from public.fco_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.asset_version is distinct from signing.version or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Preview this exact version and signing images before signing';end if;
 d:=d||jsonb_build_object('client_signing_assets',jsonb_build_object('signature',signing.signature,'stamp',signing.stamp,'version',signing.version,'confirmed_at',now(),'confirmed_by',uid),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'user_id',uid,'account',email,'authority',true,'accepted',true,'use_saved_assets',true,'review_token',review.token,'content_hash',review.payload_hash),'signed_payload_hash',review.payload_hash);
 a.status:='awaiting_approval';
 when 'prepare_approval' then
 if a.status<>'awaiting_approval' or not (d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Buyer must sign and admin must verify the exact agreement';end if;
 select * into review from public.fco_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Review the client-signed PDF before final approval';end if;
 if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Nexora signature and stamp are unavailable';end if;
 d:=d||jsonb_build_object('approval_request',jsonb_build_object('token',gen_random_uuid(),'at',now(),'by',email,'user_id',uid));
 when 'approve' then
 if a.status<>'awaiting_approval' or not(d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb or p_payload->>'approval_token' is distinct from d->'approval_request'->>'token' or d->'approval_request'->>'user_id' is distinct from uid::text or (d->'approval_request'->>'at')::timestamptz<now()-interval '15 minutes' then raise exception 'Final approval request expired or invalid';end if;
 if length(coalesce(p_payload->>'pdf','')) not between 100 and 20000000 then raise exception 'Final PDF required';end if;
 final_bytes:=decode(p_payload->>'pdf','base64');if substring(final_bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid final PDF';end if;
 insert into public.fco_final_pdfs(agreement_id,pdf_base64,pdf_sha256) values(a.id,p_payload->>'pdf',encode(sha256(final_bytes),'hex'));
 d:=d||jsonb_build_object('seller_signature',d->'approval_request','pdf_sha256',encode(sha256(final_bytes),'hex'));d:=d-'approval_request';a.status:='completed';
 when 'cancel' then
 if a.status in ('completed','cancelled') then raise exception 'Completed records cannot be cancelled';end if;a.status:='cancelled';
 when 'revise' then
 if a.status='draft' then raise exception 'Save the existing draft';end if;
 d:=d-'client_signature'-'client_signing_assets'-'signed_payload_hash'-'seller_signature'-'approval_request'-'pdf_sha256';
 perform pg_advisory_xact_lock(hashtextextended(a.transaction_code,0));select coalesce(max(version),0)+1 into n from public.fco_agreements where transaction_code=a.transaction_code;
 d:=d||portal_private.spa_profile(a.recipient)||jsonb_build_object('previous_id',a.id);
 insert into public.fco_agreements(recipient,company_id,template_version,transaction_code,version,data,created_by) values(a.recipient,(d->>'buyer_profile_id')::uuid,a.template_version,a.transaction_code,n,d,uid) returning id into result;
 insert into public.fco_events(agreement_id,actor,actor_email,event) values(result,uid,email,'revision_created');return result;
 else raise exception 'Unknown FCO action';end case;
 update public.fco_agreements set company_id=a.company_id,status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.fco_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;
revoke all on function public.fco_action(text,uuid,integer,jsonb) from public,anon;
grant execute on function public.fco_action(text,uuid,integer,jsonb) to authenticated;
commit;
