begin;
drop policy jv_agreement_read on public.jv_agreements;
create policy jv_agreement_read on public.jv_agreements for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or (recipient=(select auth.uid()) and (status<>'draft' or coalesce(data->>'draft_shared','false')='true'))));
create or replace function public.jv_review(p_id uuid,p_revision integer,p_asset_version uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.jv_agreements; r public.jv_reviews; profile public.portal_signing_profiles; h text;
begin
 if not portal_private.is_active() then raise exception 'Active account required';end if;
 select * into a from public.jv_agreements where id=p_id;
 if not found or (not portal_private.is_admin() and (a.recipient<>auth.uid() or (a.status='draft' and coalesce(a.data->>'draft_shared','false')<>'true'))) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh';end if;
 if not portal_private.is_admin() and a.status='awaiting_client' then
 select * into profile from public.portal_signing_profiles where user_id=auth.uid();
 if not found or profile.version is distinct from p_asset_version then raise exception 'Save signature and stamp, then review again';end if;
 end if;
 h:=encode(sha256(convert_to(a.data::text,'UTF8')),'hex');
 insert into public.jv_reviews(agreement_id,actor,revision,payload_hash,asset_version) values(a.id,auth.uid(),a.revision,h,p_asset_version) returning * into r;
 return jsonb_build_object('token',r.token,'hash',h,'revision',r.revision,'created_at',r.created_at);
end;$$;
create or replace function public.jv_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}') returns uuid language plpgsql security definer set search_path='' as $$
declare a public.jv_agreements; d jsonb; profile jsonb; adm boolean; uid uuid:=auth.uid(); email text; rid uuid; y integer; n integer; k text; signing public.portal_signing_profiles; review public.jv_reviews; final_bytes bytea; result uuid; comp public.portal_companies;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active account required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>12000000 then raise exception 'Invalid request';end if;
 if p_action='create' then
 if not adm then raise exception 'Administrator required';end if;
 rid:=(p_payload->>'recipient')::uuid;
 if not exists(select 1 from public.portal_members where user_id=rid and active and not is_admin) then raise exception 'Select an active client';end if;
 profile:=portal_private.jv_profile(rid);
 y:=extract(year from now() at time zone 'Europe/Amsterdam');insert into public.jv_counters values(y,1) on conflict(year) do update set value=public.jv_counters.value+1 returning value into n;
 d:=profile||jsonb_build_object('title','Joint Venture Agreement','frequency','Monthly','a_email','info@nexint.eu','b_email',profile->>'buyer_email','seller',jsonb_build_object('business_name','Nexora International','registration','84285699','address','Herengracht 208, 1016 BS Amsterdam, The Netherlands','representative','J.P. Kolfoort','role','MD','email','info@nexint.eu'));
 insert into public.jv_agreements(recipient,company_id,template_version,transaction_code,data,created_by) values(rid,(profile->>'buyer_profile_id')::uuid,'2026-10-27-v1','NEX-JV-'||y||'-'||n,d,uid) returning * into a;
 else
 select * into a from public.jv_agreements where id=p_id for update;
 if not found or (not adm and (a.recipient<>uid or (a.status='draft' and coalesce(a.data->>'draft_shared','false')<>'true'))) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;d:=a.data;
 if p_action<>'sign' and not adm then raise exception 'Administrator required';end if;
 case p_action
 when 'share_draft' then
 if a.status<>'draft' then raise exception 'Only draft agreements may be shared for review';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Active client required';end if;
 d:=d||jsonb_build_object('draft_shared',true,'draft_shared_at',now());
 when 'unshare_draft' then
 if a.status<>'draft' then raise exception 'Only draft review access may be withdrawn';end if;
 d:=d-'draft_shared'-'draft_shared_at';
 when 'save' then
 if a.status<>'draft' then raise exception 'Only a draft may be edited';end if;
 d:=(d-'draft_shared'-'draft_shared_at')||portal_private.jv_edit_fields(p_payload->'data');
 when 'sync_profile' then
 if a.status<>'draft' then raise exception 'Signed or assigned profile snapshots cannot change';end if;
 profile:=portal_private.jv_profile(a.recipient);d:=(d-'draft_shared'-'draft_shared_at')||profile;a.company_id:=(profile->>'buyer_profile_id')::uuid;
 when 'issue' then
 if a.status<>'draft' then raise exception 'Only draft agreements may be assigned';end if;
 profile:=portal_private.jv_profile(a.recipient);
 if profile->>'buyer_profile_status'<>'approved' then raise exception 'Approve the company profile before assigning the JV';end if;
 if profile->>'buyer_profile_id' is distinct from d->>'buyer_profile_id' or profile->>'buyer_profile_version' is distinct from d->>'buyer_profile_version' then raise exception 'Company profile changed; refresh the draft snapshot first';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Client account is disabled';end if;
 perform portal_private.jv_validate(d);a.status:='awaiting_client';
 when 'sign' then
 if adm or uid<>a.recipient or a.status<>'awaiting_client' then raise exception 'Only the assigned buyer may sign';end if;
 perform portal_private.jv_validate(d);
 select * into comp from public.portal_companies where id=a.company_id;
 if comp.access_state is distinct from 'active' then raise exception 'Company access is disabled';end if;
 if p_payload->'schedules_accepted' is distinct from 'true'::jsonb then raise exception 'Accept the complete Agreement and both schedules';end if;
 if p_payload->>'name' is distinct from d->>'representative' or p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->'use_saved_assets' is distinct from 'true'::jsonb then raise exception 'Confirm exact authorized name, authority, acceptance and use of saved signing images';end if;
 select * into signing from public.portal_signing_profiles where user_id=uid for share;
 if not found or p_payload->>'asset_version' is distinct from signing.version::text then raise exception 'Signing images changed; save and review again';end if;
 select * into review from public.jv_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.asset_version is distinct from signing.version or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Preview this exact version and signing images before signing';end if;
 d:=d||jsonb_build_object('client_signing_assets',jsonb_build_object('signature',signing.signature,'stamp',signing.stamp,'version',signing.version,'confirmed_at',now(),'confirmed_by',uid),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'user_id',uid,'account',email,'authority',true,'accepted',true,'schedules_accepted',true,'use_saved_assets',true,'review_token',review.token,'content_hash',review.payload_hash),'signed_payload_hash',review.payload_hash);
 a.status:='awaiting_approval';
 when 'prepare_approval' then
 if a.status<>'awaiting_approval' or d->'client_signature'->'schedules_accepted' is distinct from 'true'::jsonb or not (d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Buyer must sign and admin must verify the exact agreement';end if;
 select * into review from public.jv_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Review the client-signed PDF before final approval';end if;
 if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Nexora signature and stamp are unavailable';end if;
 d:=d||jsonb_build_object('approval_request',jsonb_build_object('token',gen_random_uuid(),'at',now(),'by',email,'user_id',uid));
 when 'approve' then
 if a.status<>'awaiting_approval' or d->'client_signature'->'schedules_accepted' is distinct from 'true'::jsonb or not(d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb or p_payload->>'approval_token' is distinct from d->'approval_request'->>'token' or d->'approval_request'->>'user_id' is distinct from uid::text or (d->'approval_request'->>'at')::timestamptz<now()-interval '15 minutes' then raise exception 'Final approval request expired or invalid';end if;
 if length(coalesce(p_payload->>'pdf','')) not between 100 and 10000000 then raise exception 'Final PDF required';end if;
 final_bytes:=decode(p_payload->>'pdf','base64');if substring(final_bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid final PDF';end if;
 insert into public.jv_final_pdfs(agreement_id,pdf_base64,pdf_sha256) values(a.id,p_payload->>'pdf',encode(sha256(final_bytes),'hex'));
 d:=d||jsonb_build_object('seller_signature',d->'approval_request','pdf_sha256',encode(sha256(final_bytes),'hex'));d:=d-'approval_request';a.status:='completed';
 when 'cancel' then
 if a.status in ('completed','cancelled') then raise exception 'Completed records cannot be cancelled';end if;a.status:='cancelled';
 when 'revise' then
 if a.status='draft' then raise exception 'Save the existing draft';end if;
 d:=d-'draft_shared'-'draft_shared_at'-'client_signature'-'client_signing_assets'-'signed_payload_hash'-'seller_signature'-'approval_request'-'pdf_sha256';
 perform pg_advisory_xact_lock(hashtextextended(a.transaction_code,0));select coalesce(max(version),0)+1 into n from public.jv_agreements where transaction_code=a.transaction_code;
 d:=d||portal_private.jv_profile(a.recipient)||jsonb_build_object('previous_id',a.id);
 insert into public.jv_agreements(recipient,company_id,template_version,transaction_code,version,data,created_by) values(a.recipient,(d->>'buyer_profile_id')::uuid,a.template_version,a.transaction_code,n,d,uid) returning id into result;
 insert into public.jv_events(agreement_id,actor,actor_email,event) values(result,uid,email,'revision_created');return result;
 else raise exception 'Unknown JV action';end case;
 update public.jv_agreements set company_id=a.company_id,status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.jv_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;
notify pgrst, 'reload schema';
commit;
