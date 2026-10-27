begin;
drop policy spa_agreement_read on public.spa_agreements;
create policy spa_agreement_read on public.spa_agreements for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or (recipient=(select auth.uid()) and (status<>'draft' or coalesce(data->>'draft_shared','false')='true'))));
create or replace function public.spa_review(p_id uuid,p_revision integer,p_asset_version uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_agreements; r public.spa_reviews; profile public.portal_signing_profiles; h text;
begin
 if not portal_private.is_active() then raise exception 'Active account required';end if;
 select * into a from public.spa_agreements where id=p_id;
 if not found or (not portal_private.is_admin() and (a.recipient<>auth.uid() or (a.status='draft' and coalesce(a.data->>'draft_shared','false')<>'true'))) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh';end if;
 if not portal_private.is_admin() and a.status='awaiting_client' then
 select * into profile from public.portal_signing_profiles where user_id=auth.uid();
 if not found or profile.version is distinct from p_asset_version then raise exception 'Save signature and stamp, then review again';end if;
 end if;
 h:=encode(sha256(convert_to(a.data::text,'UTF8')),'hex');
 insert into public.spa_reviews(agreement_id,actor,revision,payload_hash,asset_version) values(a.id,auth.uid(),a.revision,h,p_asset_version) returning * into r;
 return jsonb_build_object('token',r.token,'hash',h,'revision',r.revision,'created_at',r.created_at);
end;$$;
create or replace function public.spa_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}') returns uuid language plpgsql security definer set search_path='' as $$
declare a public.spa_agreements; d jsonb; profile jsonb; adm boolean; uid uuid:=auth.uid(); email text; rid uuid; y integer; n integer; k text; signing public.portal_signing_profiles; review public.spa_reviews; final_bytes bytea; result uuid; comp public.portal_companies;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active account required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>12000000 then raise exception 'Invalid request';end if;
 if p_action='create' then
 if not adm then raise exception 'Administrator required';end if;
 rid:=(p_payload->>'recipient')::uuid;
 if not exists(select 1 from public.portal_members where user_id=rid and active and not is_admin) then raise exception 'Select an active client';end if;
 profile:=portal_private.spa_profile(rid);
 y:=extract(year from now() at time zone 'Europe/Amsterdam');insert into public.spa_counters values(y,1) on conflict(year) do update set value=public.spa_counters.value+1 returning value into n;
 d:=profile||jsonb_build_object('product','EN590','standard','EN 590:2025','incoterm','CFR','law','ENGLISH','months','12','bank_holder','La Clava Elit B.V.','technical','{}'::jsonb,'seller',jsonb_build_object('legal_name','La Clava Elit B.V.','business_name','Nexora International','registration','84285699','vat','NL863159825B01','registered_address','Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands','address','Herengracht 208, 1016 BS Amsterdam, The Netherlands','representative','J.P. Kolfoort','role','MD','email','info@nexint.eu'));
 insert into public.spa_agreements(recipient,company_id,template_version,transaction_code,data,created_by) values(rid,(profile->>'buyer_profile_id')::uuid,'2026-10-23-v1','NEX-SPA-'||y||'-'||n,d,uid) returning * into a;
 else
 select * into a from public.spa_agreements where id=p_id for update;
 if not found or (not adm and (a.recipient<>uid or (a.status='draft' and coalesce(a.data->>'draft_shared','false')<>'true'))) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;d:=a.data;
 if p_action<>'sign' and not adm then raise exception 'Administrator required';end if;
 case p_action
 when 'share_draft' then
 if a.status<>'draft' then raise exception 'Only drafts may be shared';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Active client required';end if;
 d:=d||jsonb_build_object('draft_shared',true,'draft_shared_at',now());
 when 'unshare_draft' then
 if a.status<>'draft' then raise exception 'Only draft review access may be withdrawn';end if;
 d:=d-'draft_shared'-'draft_shared_at';
 when 'save' then
 if a.status<>'draft' then raise exception 'Only a draft may be edited';end if;
 d:=(d-'draft_shared'-'draft_shared_at')||portal_private.spa_edit_fields(p_payload->'data');
 when 'sync_profile' then
 if a.status<>'draft' then raise exception 'Signed or assigned profile snapshots cannot change';end if;
 profile:=portal_private.spa_profile(a.recipient);d:=(d-'draft_shared'-'draft_shared_at')||profile;a.company_id:=(profile->>'buyer_profile_id')::uuid;
 when 'issue' then
 if a.status<>'draft' then raise exception 'Only draft agreements may be assigned';end if;
 profile:=portal_private.spa_profile(a.recipient);
 if profile->>'buyer_profile_status'<>'approved' then raise exception 'Approve the company profile before assigning the SPA';end if;
 if profile->>'buyer_profile_id' is distinct from d->>'buyer_profile_id' or profile->>'buyer_profile_version' is distinct from d->>'buyer_profile_version' then raise exception 'Company profile changed; refresh the draft snapshot first';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Client account is disabled';end if;
 perform portal_private.spa_validate(d);a.status:='awaiting_client';
 when 'sign' then
 if adm or uid<>a.recipient or a.status<>'awaiting_client' then raise exception 'Only the assigned buyer may sign';end if;
 perform portal_private.spa_validate(d);
 select * into comp from public.portal_companies where id=a.company_id;
 if comp.access_state<>'active' then raise exception 'Company access is disabled';end if;
 if p_payload->>'name' is distinct from d->>'representative' or p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->'use_saved_assets' is distinct from 'true'::jsonb then raise exception 'Confirm exact authorized name, authority, acceptance and use of saved signing images';end if;
 select * into signing from public.portal_signing_profiles where user_id=uid for share;
 if not found or p_payload->>'asset_version' is distinct from signing.version::text then raise exception 'Signing images changed; save and review again';end if;
 select * into review from public.spa_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.asset_version is distinct from signing.version or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Preview this exact version and signing images before signing';end if;
 d:=d||jsonb_build_object('client_signing_assets',jsonb_build_object('signature',signing.signature,'stamp',signing.stamp,'version',signing.version,'confirmed_at',now(),'confirmed_by',uid),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'user_id',uid,'account',email,'authority',true,'accepted',true,'use_saved_assets',true,'review_token',review.token,'content_hash',review.payload_hash),'signed_payload_hash',review.payload_hash);
 a.status:='awaiting_approval';
 when 'prepare_approval' then
 if a.status<>'awaiting_approval' or not (d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Buyer must sign and admin must verify the exact agreement';end if;
 select * into review from public.spa_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Review the client-signed PDF before final approval';end if;
 if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Nexora signature and stamp are unavailable';end if;
 d:=d||jsonb_build_object('approval_request',jsonb_build_object('token',gen_random_uuid(),'at',now(),'by',email,'user_id',uid));
 when 'approve' then
 if a.status<>'awaiting_approval' or not(d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb or p_payload->>'approval_token' is distinct from d->'approval_request'->>'token' or d->'approval_request'->>'user_id' is distinct from uid::text or (d->'approval_request'->>'at')::timestamptz<now()-interval '15 minutes' then raise exception 'Final approval request expired or invalid';end if;
 if length(coalesce(p_payload->>'pdf','')) not between 100 and 10000000 then raise exception 'Final PDF required';end if;
 final_bytes:=decode(p_payload->>'pdf','base64');if substring(final_bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid final PDF';end if;
 insert into public.spa_final_pdfs(agreement_id,pdf_base64,pdf_sha256) values(a.id,p_payload->>'pdf',encode(sha256(final_bytes),'hex'));
 d:=d||jsonb_build_object('seller_signature',d->'approval_request','pdf_sha256',encode(sha256(final_bytes),'hex'));d:=d-'approval_request';a.status:='completed';
 when 'cancel' then
 if a.status in ('completed','cancelled') then raise exception 'Completed records cannot be cancelled';end if;a.status:='cancelled';
 when 'revise' then
 if a.status='draft' then raise exception 'Save the existing draft';end if;
 d:=d-'draft_shared'-'draft_shared_at'-'client_signature'-'client_signing_assets'-'signed_payload_hash'-'seller_signature'-'approval_request'-'pdf_sha256';
 perform pg_advisory_xact_lock(hashtextextended(a.transaction_code,0));select coalesce(max(version),0)+1 into n from public.spa_agreements where transaction_code=a.transaction_code;
 d:=d||portal_private.spa_profile(a.recipient)||jsonb_build_object('previous_id',a.id);
 insert into public.spa_agreements(recipient,company_id,template_version,transaction_code,version,data,created_by) values(a.recipient,(d->>'buyer_profile_id')::uuid,a.template_version,a.transaction_code,n,d,uid) returning id into result;
 insert into public.spa_events(agreement_id,actor,actor_email,event) values(result,uid,email,'revision_created');return result;
 else raise exception 'Unknown SPA action';end case;
 update public.spa_agreements set company_id=a.company_id,status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.spa_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;
drop policy fco_agreement_read on public.fco_agreements;
create policy fco_agreement_read on public.fco_agreements for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or (recipient=(select auth.uid()) and (status<>'draft' or coalesce(data->>'draft_shared','false')='true'))));
create or replace function public.fco_review(p_id uuid,p_revision integer,p_asset_version uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.fco_agreements; r public.fco_reviews; profile public.portal_signing_profiles; h text;
begin
 if not portal_private.is_active() then raise exception 'Active account required';end if;
 select * into a from public.fco_agreements where id=p_id;
 if not found or (not portal_private.is_admin() and (a.recipient<>auth.uid() or (a.status='draft' and coalesce(a.data->>'draft_shared','false')<>'true'))) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh';end if;
 if not portal_private.is_admin() and a.status='awaiting_client' then
 select * into profile from public.portal_signing_profiles where user_id=auth.uid();
 if not found or profile.version is distinct from p_asset_version then raise exception 'Save signature and stamp, then review again';end if;
 end if;
 h:=encode(sha256(convert_to(a.data::text,'UTF8')),'hex');
 insert into public.fco_reviews(agreement_id,actor,revision,payload_hash,asset_version) values(a.id,auth.uid(),a.revision,h,p_asset_version) returning * into r;
 return jsonb_build_object('token',r.token,'hash',h,'revision',r.revision,'created_at',r.created_at);
end;$$;
create or replace function public.fco_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}') returns uuid language plpgsql security definer set search_path='' as $$
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
 if not found or (not adm and (a.recipient<>uid or (a.status='draft' and coalesce(a.data->>'draft_shared','false')<>'true'))) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;d:=a.data;
 if p_action<>'sign' and not adm then raise exception 'Administrator required';end if;
 case p_action
 when 'share_draft' then
 if a.status<>'draft' then raise exception 'Only drafts may be shared';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Active client required';end if;
 d:=d||jsonb_build_object('draft_shared',true,'draft_shared_at',now());
 when 'unshare_draft' then
 if a.status<>'draft' then raise exception 'Only draft review access may be withdrawn';end if;
 d:=d-'draft_shared'-'draft_shared_at';
 when 'save' then
 if a.status<>'draft' then raise exception 'Only a draft may be edited';end if;
 d:=(d-'draft_shared'-'draft_shared_at')||portal_private.fco_edit_fields(p_payload->'data');
 when 'sync_profile' then
 if a.status<>'draft' then raise exception 'Signed or assigned profile snapshots cannot change';end if;
 profile:=portal_private.spa_profile(a.recipient);d:=(d-'draft_shared'-'draft_shared_at')||profile;a.company_id:=(profile->>'buyer_profile_id')::uuid;
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
 d:=d-'draft_shared'-'draft_shared_at'-'client_signature'-'client_signing_assets'-'signed_payload_hash'-'seller_signature'-'approval_request'-'pdf_sha256';
 perform pg_advisory_xact_lock(hashtextextended(a.transaction_code,0));select coalesce(max(version),0)+1 into n from public.fco_agreements where transaction_code=a.transaction_code;
 d:=d||portal_private.spa_profile(a.recipient)||jsonb_build_object('previous_id',a.id);
 insert into public.fco_agreements(recipient,company_id,template_version,transaction_code,version,data,created_by) values(a.recipient,(d->>'buyer_profile_id')::uuid,a.template_version,a.transaction_code,n,d,uid) returning id into result;
 insert into public.fco_events(agreement_id,actor,actor_email,event) values(result,uid,email,'revision_created');return result;
 else raise exception 'Unknown FCO action';end case;
 update public.fco_agreements set company_id=a.company_id,status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.fco_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;
drop policy commission_read on public.commission_agreements;
create policy commission_read on public.commission_agreements for select to authenticated using((select portal_private.is_admin()) or (recipient=(select auth.uid()) and (select portal_private.is_active()) and (status<>'draft' or coalesce(data->>'draft_shared','false')='true')));
create or replace function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;client_id uuid;signing public.portal_signing_profiles;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active portal membership required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if length(p_payload::text)>10000000 then raise exception 'Request too large';end if;
 if p_action='create' then
  if not adm then raise exception 'Administrator required';end if;
  recipient_id:=(p_payload->>'recipient')::uuid;
  if not exists(select 1 from public.portal_members m where m.user_id=recipient_id and m.active and not m.is_admin) then raise exception 'Select an active registered client';end if;
  client_id:=coalesce((p_payload->>'client_user_id')::uuid,recipient_id);
  if client_id<>recipient_id and not exists(select 1 from public.portal_broker_clients where client_user_id=client_id and broker_user_id=recipient_id and active) then raise exception 'Link the broker to this client first';end if;
  y:=extract(year from now() at time zone 'Europe/Amsterdam');
  insert into public.commission_counters(year,value) values(y,1) on conflict(year) do update set value=public.commission_counters.value+1 returning value into n;
  d:='{}';foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop d:=d||jsonb_build_object(k,left(trim(coalesce(p_payload->>k,'')),2000));end loop;
  d:=d||jsonb_build_object('transaction','NEX-COM-'||y||'-'||n::text,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,client_user_id,transaction_code,data) values(recipient_id,client_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or (a.status='draft' and coalesce(a.data->>'draft_shared','false')<>'true'))) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise','share_draft','unshare_draft') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'share_draft' then
   if a.status<>'draft' then raise exception 'Only drafts may be shared';end if;
   if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Active client required';end if;
   d:=d||jsonb_build_object('draft_shared',true,'draft_shared_at',now());
  when 'unshare_draft' then
   if a.status<>'draft' then raise exception 'Only draft review access may be withdrawn';end if;
   d:=d-'draft_shared'-'draft_shared_at';
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;d:=d-'draft_shared'-'draft_shared_at';
   foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop d:=d||jsonb_build_object(k,left(trim(coalesce(p_payload->>k,'')),2000));end loop;
  when 'issue' then
   if a.status<>'draft' then raise exception 'Only drafts can be issued';end if;
   foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete all commercial fields';end if;end loop;
   if d->>'deadline' !~ '^[0-9]{1,3}$' or (d->>'deadline')::integer not between 1 and 365 then raise exception 'Deadline must be 1 to 365 business days';end if;
   if not exists(select 1 from public.portal_members m where m.user_id=a.recipient and m.active) then raise exception 'Client access is disabled';end if;
   a.status:='awaiting_client';
  when 'client-save' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop
    if jsonb_typeof(p_payload->k) is distinct from 'string' or length(p_payload->>k)>500 then raise exception 'Invalid client details';end if;
    d:=d||jsonb_build_object(k,trim(p_payload->>k));end loop;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose bank or crypto';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   v:='{}';foreach k in array fields loop
    if ((p_payload->'payment') ? k) and (jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000) then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(coalesce(p_payload->'payment'->>k,'')));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete client details';end if;end loop;
   if d->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose a payment method';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   foreach k in array fields loop if ((method='bank' and k not in ('routing','intermediary')) or (method='crypto' and k in ('wallet','network'))) and trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete the required payment details';end if;end loop;
   if p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->>'name' is distinct from d->>'representative' or p_payload->'reviewed' is distinct from 'true'::jsonb then raise exception 'Review the agreement and confirm authority, name and acceptance';end if;
   select * into signing from public.portal_signing_profiles where user_id=uid for share;
   if not found then raise exception 'Save your private signature and company stamp before signing';end if;
   if p_payload->'use_saved_assets' is distinct from 'true'::jsonb or p_payload->>'asset_version' is distinct from signing.version::text then raise exception 'Review your saved signing images and explicitly authorize their use for this agreement';end if;
   d:=d||jsonb_build_object('beneficiary_signing_assets',jsonb_build_object('signature',signing.signature,'stamp',signing.stamp,'version',signing.version,'confirmed_at',now(),'confirmed_by',uid));
   d:=d||jsonb_build_object('signed_payload_hash',encode(sha256(convert_to(d::text,'UTF8')),'hex'),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'account',email,'user_id',uid,'authority',true,'accepted',true,'method','typed name with authenticated portal acceptance'));
   a.status:='awaiting_approval';
  when 'approve' then
   if a.status<>'awaiting_approval' or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Review beneficiary and verify payment instructions before approval';end if;
   if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Signature assets are not configured';end if;
   if length(coalesce(p_payload->>'pdf','')) not between 100 and 8000000 then raise exception 'Final PDF required';end if;
   pdf_bytes:=decode(p_payload->>'pdf','base64');if substring(pdf_bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;
   insert into public.commission_final_pdfs values(a.id,p_payload->>'pdf',encode(sha256(pdf_bytes),'hex'));
   d:=d||jsonb_build_object('approved_at',now(),'approved_by',email,'approved_user_id',uid,'pdf_sha256',encode(sha256(pdf_bytes),'hex'));
   a.status:='completed';
  when 'cancel' then
   if a.status in ('completed','cancelled') then raise exception 'Completed records cannot be cancelled';end if;a.status:='cancelled';
  when 'revise' then
   if a.status not in ('completed','cancelled','awaiting_approval') then raise exception 'Revision unavailable';end if;
   v:='{}';foreach k in array array['title','services','scope','covered','formula','trigger','deadline','transaction','terms_version'] loop v:=v||jsonb_build_object(k,d->k);end loop;
   v:=v||jsonb_build_object('previous_id',a.id);
   insert into public.commission_agreements(recipient,client_user_id,version,transaction_code,data) values(a.recipient,a.client_user_id,a.version+1,a.transaction_code,v) returning id into new_id;
   insert into public.commission_events(agreement_id,actor,actor_email,event) values(new_id,uid,email,'revision_created');return new_id;
  else raise exception 'Unknown action';end case;
  update public.commission_agreements set status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.commission_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;

alter table public.portal_mcnda_assignments drop constraint portal_mcnda_assignments_status_check;
alter table public.portal_mcnda_assignments add constraint portal_mcnda_assignments_status_check check(status in ('draft_review','assigned','completed','cancelled'));
drop index public.mcnda_one_pending;
create unique index mcnda_one_pending on public.portal_mcnda_assignments(user_id) where status in ('draft_review','assigned');
create function public.mcnda_review_assignment(p_action text,p_id uuid default null,p_user_id uuid default null,p_client_user_id uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.portal_mcnda_assignments; result uuid;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if p_action='share_draft' then
 if p_user_id is null or p_client_user_id is null then raise exception 'Select a signer and client';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active and not is_admin) then raise exception 'Active signer required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_client_user_id and active and not is_admin) then raise exception 'Active client required';end if;
 if p_user_id<>p_client_user_id and not exists(select 1 from public.portal_broker_clients where client_user_id=p_client_user_id and broker_user_id=p_user_id and active) then raise exception 'Link this broker first';end if;
 insert into public.portal_mcnda_assignments(user_id,client_user_id,status,assigned_by) values(p_user_id,p_client_user_id,'draft_review',auth.uid()) returning id into result;
 return result;
 end if;
 select * into a from public.portal_mcnda_assignments where id=p_id for update;
 if not found or a.status<>'draft_review' then raise exception 'A draft review assignment is required';end if;
 if p_action='release' then
 if not exists(select 1 from public.portal_members where user_id=a.user_id and active and not is_admin) then raise exception 'Active signer required';end if;
 update public.portal_mcnda_assignments set status='assigned' where id=a.id;
 elsif p_action='withdraw' then
 update public.portal_mcnda_assignments set status='cancelled' where id=a.id;
 else raise exception 'Unknown action';end if;
 return a.id;
end;$$;
revoke all on function public.mcnda_review_assignment(text,uuid,uuid,uuid) from public,anon;
grant execute on function public.mcnda_review_assignment(text,uuid,uuid,uuid) to authenticated;
drop policy nda_template_member_read on storage.objects;
create policy nda_template_member_read on storage.objects for select to authenticated using(bucket_id='nexora-documents' and name='nda-template-v20261020.pdf' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_mcnda_assignments where user_id=(select auth.uid()) and status in ('draft_review','assigned')))));
notify pgrst, 'reload schema';
commit;
