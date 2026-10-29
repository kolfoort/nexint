begin;
create function portal_private.multi_mcnda_parties_current(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$select not exists(select 1 from public.portal_mcnda_parties p left join public.portal_companies c on c.id=p.company_id left join public.portal_members m on m.user_id=p.user_id where p.version_id=p_id and not p.is_nexora and (c.id is null or c.version is distinct from p.company_version or c.access_state is distinct from 'active' or m.active is distinct from true))$$;
revoke all on function portal_private.multi_mcnda_parties_current(uuid) from public,anon,authenticated,service_role;

create or replace function public.multi_mcnda_action(p_action text,p_id uuid default null,p_expected_revision integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.portal_mcnda_versions;oldv public.portal_mcnda_versions;thread uuid;num integer;content bytea;snap jsonb;part jsonb;me public.portal_mcnda_parties;proof jsonb;c portal_private.signing_confirmations;sig bytea;rec jsonb;h text;tok uuid;title text;is_admin boolean;
begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() then raise exception 'MFA_REQUIRED';end if;is_admin:=portal_private.is_admin();
 if p_action in ('prepare','create') then
 if not is_admin then raise exception 'Administrator required';end if;
 snap:=portal_private.multi_mcnda_snapshot(p_payload->'users',auth.uid(),p_payload->>'owner_name')||jsonb_build_object('scope',left(coalesce(p_payload->>'scope',''),1200));
 for part in select value from jsonb_array_elements(snap->'parties') loop
 if coalesce(p_payload->'notice_numbers'->>(part->>'user_id'),'')<>'' and p_payload->'notice_numbers'->>(part->>'user_id') !~ '^[+0-9 ()-]{6,32}$' then raise exception 'Invalid designated WhatsApp number';end if;end loop;
 snap:=jsonb_set(snap,'{parties}',(select jsonb_agg(value||jsonb_build_object('whatsapp',coalesce(p_payload->'notice_numbers'->>(value->>'user_id'),'')) order by ord) from jsonb_array_elements(snap->'parties') with ordinality as a(value,ord)));
 if p_action='prepare' then return snap;end if;
 if p_payload->'snapshot' is distinct from snap then raise exception 'Profile changed; prepare and review a new PDF';end if;
 title:=trim(p_payload->>'title');if length(coalesce(title,'')) not between 1 and 180 then raise exception 'Document title required';end if;
 if length(coalesce(p_payload->>'pdf','')) not between 500 and 20000000 then raise exception 'Complete PDF required';end if;
 content:=decode(p_payload->>'pdf','base64');if substring(content from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;
 if p_id is null then insert into public.portal_mcnda_threads(title,owner_id) values(title,auth.uid()) returning id into thread;num:=1;
 else
 select id into thread from public.portal_mcnda_threads where id=p_id for update;if not found then raise exception 'Agreement unavailable';end if;
 select * into oldv from public.portal_mcnda_versions where thread_id=thread order by revision desc limit 1 for update;
 if oldv.revision is distinct from p_expected_revision then raise exception 'Version changed';end if;num:=oldv.revision+1;
 if oldv.status not in ('completed','cancelled','superseded') then
 update public.portal_mcnda_versions set status='superseded' where id=oldv.id;
 update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null where purpose='mcnda_multi' and document_id=oldv.id and consumed_at is null;
 perform portal_private.multi_mcnda_log(oldv.id,'revision_superseded',jsonb_build_object('replacement_revision',num,'prior_signatures_preserved',true));
 if oldv.shared_at is not null then perform portal_private.multi_mcnda_queue(oldv.id,'withdrawn');end if;
 end if;
 end if;
 insert into public.portal_mcnda_versions(thread_id,revision,template_version,content_pdf,content_hash,snapshot,created_by) values(thread,num,snap->>'template',p_payload->>'pdf',encode(sha256(content),'hex'),snap,auth.uid()) returning * into v;
 for part in select value from jsonb_array_elements(snap->'parties') loop
 insert into public.portal_mcnda_parties(version_id,user_id,position,company_id,company_version,snapshot,is_nexora) values(v.id,(part->>'user_id')::uuid,(part->>'position')::integer,(part->>'company_id')::uuid,(part->>'company_version')::integer,part,(part->>'is_nexora')::boolean);
 end loop;
 perform portal_private.multi_mcnda_log(v.id,'revision_created',jsonb_build_object('content_hash',v.content_hash,'template',v.template_version,'snapshot_hash',encode(sha256(convert_to(snap::text,'UTF8')),'hex'),'prior_completed_agreements_unaffected',true));return jsonb_build_object('id',v.id,'thread_id',thread,'revision',num);
 end if;
 select thread_id into thread from public.portal_mcnda_versions where id=p_id;perform 1 from public.portal_mcnda_threads where id=thread for update;
 select * into v from public.portal_mcnda_versions where id=p_id for update;if not found or v.revision is distinct from p_expected_revision or not portal_private.multi_mcnda_visible(v.id) then raise exception 'Current accessible agreement required';end if;
 if p_action='pdf' then
 perform portal_private.multi_mcnda_log(v.id,'document_accessed',jsonb_build_object('content_hash',v.content_hash,'artifact',case when p_payload->>'artifact'='final' then 'final' else 'content' end));
 if p_payload->>'artifact'='final' then if v.final_pdf is null then raise exception 'Final bundle unavailable';end if;return jsonb_build_object('pdf',v.final_pdf,'hash',v.final_hash);end if;
 return jsonb_build_object('pdf',v.content_pdf,'hash',v.content_hash);
 elsif p_action in ('release','share_draft') then
 if not is_admin or v.status not in('draft','draft_review') or p_payload->>'reviewed_hash' is distinct from v.content_hash or p_payload->>'authority_reviewed' is distinct from 'true' then raise exception 'Review the exact PDF, all party identities and authority first';end if;
 for me in select * from public.portal_mcnda_parties where version_id=v.id and not is_nexora loop
 if not exists(select 1 from public.portal_companies where id=me.company_id and version=me.company_version and access_state='active') or not exists(select 1 from public.portal_members where user_id=me.user_id and active) then raise exception 'Counterparty profile changed or access unavailable; create a new revision';end if;
 end loop;
 if p_action='share_draft' then
 update public.portal_mcnda_versions set status='draft_review',shared_at=coalesce(shared_at,now()) where id=v.id;perform portal_private.multi_mcnda_log(v.id,'draft_shared',jsonb_build_object('content_hash',v.content_hash,'authority_reviewed',true));perform portal_private.multi_mcnda_queue(v.id,'draft_review');return jsonb_build_object('shared',true);end if;
 update public.portal_mcnda_versions set status='released',released_at=now(),shared_at=coalesce(shared_at,now()) where id=v.id;
 perform portal_private.multi_mcnda_log(v.id,'released_for_signature',jsonb_build_object('content_hash',v.content_hash,'authority_reviewed',true,'reviewer',auth.uid()));perform portal_private.multi_mcnda_queue(v.id,'released');return jsonb_build_object('released',true);
 elsif p_action='review' then
 if v.status<>'released' or p_payload->>'reviewed_hash' is distinct from v.content_hash or p_payload->>'accept_review' is distinct from 'true' then raise exception 'Review the complete current PDF first';end if;
 if not exists(select 1 from public.portal_mcnda_events where version_id=v.id and actor=auth.uid() and event='document_accessed' and payload->>'content_hash'=v.content_hash and at>now()-interval '24 hours') then raise exception 'Open the complete PDF first';end if;
 select * into me from public.portal_mcnda_parties where version_id=v.id and user_id=auth.uid();if not found then raise exception 'Assigned signatory required';end if;
 insert into portal_private.multi_mcnda_reviews(version_id,user_id,content_hash) values(v.id,auth.uid(),v.content_hash) returning token into tok;
 perform portal_private.multi_mcnda_log(v.id,'review_attested',jsonb_build_object('content_hash',v.content_hash,'attestation','Full English PDF and party schedule reviewed; this records an assertion, not proof of actual reading'));return jsonb_build_object('review_token',tok);
 elsif p_action='sign' then
 if v.status<>'released' or p_payload->>'accept' is distinct from 'true' then raise exception 'Explicit current agreement acceptance required';end if;
 select * into me from public.portal_mcnda_parties where version_id=v.id and user_id=auth.uid();if not found or exists(select 1 from public.portal_mcnda_signatures where version_id=v.id and user_id=auth.uid()) then raise exception 'Unsigned assigned party required';end if;
 if me.is_nexora then
 if not portal_private.multi_mcnda_parties_current(v.id) then raise exception 'A counterparty profile changed or access was paused; review and revise before final approval';end if;
 if not is_admin or exists(select 1 from public.portal_mcnda_parties p where p.version_id=v.id and not p.is_nexora and not exists(select 1 from public.portal_mcnda_signatures s where s.version_id=p.version_id and s.user_id=p.user_id)) then raise exception 'All counterparties must sign before Nexora';end if;
 else
 if not exists(select 1 from public.portal_companies where id=me.company_id and version=me.company_version and access_state='active') then raise exception 'Profile changed; request a revised agreement';end if;
 if me.snapshot->>'kind'='individual' and not exists(select 1 from portal_private.individual_identity i join public.portal_access_requests r on r.id=i.request_id join storage.objects o on o.bucket_id='nexora-private-identity' and o.name=i.copy_path where r.invited_user_id=auth.uid() and length(i.passport_number)>0) then raise exception 'Complete your protected identity record and upload the signed passport copy before signing';end if;
 end if;
 if p_payload->>'name' is distinct from me.snapshot->>'name' or p_payload->>'capacity_confirmed' is distinct from 'true' then raise exception 'Confirm the exact signatory name and capacity';end if;
 if length(coalesce(p_payload->>'signature_png','')) not between 100 and 700000 then raise exception 'Signature image required';end if;sig:=decode(p_payload->>'signature_png','base64');if substring(sig from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'PNG signature required';end if;
 select * into c from portal_private.signing_confirmations where id=(p_payload->>'confirmation_id')::uuid and user_id=auth.uid() for update;
 if not found or c.document_revision is distinct from v.revision or c.review_token is distinct from (p_payload->>'review_token')::uuid then raise exception 'Confirm this reviewed version again';end if;
 proof:=portal_private.consume_signing_confirmation(c.id,(p_payload->>'confirmation_token')::uuid,'mcnda_multi',v.id,v.content_hash,v.revision);
 rec:=jsonb_build_object('account_id',auth.uid(),'account_email',proof->>'account_email','signer_name',me.snapshot->>'name','legal_party',me.snapshot->>'legal_name','capacity',me.snapshot->>'capacity','content_hash',v.content_hash,'signature_image_hash',encode(sha256(sig),'hex'),'accepted_at',now(),'acceptance','Explicit acceptance of the full English agreement and schedule in the recorded capacity','email_confirmation',proof,'method','drawn signature and explicit acceptance with document-bound registered-email code','qualified_signature',false);
 h:=encode(sha256(convert_to(rec::text,'UTF8')),'hex');
 insert into public.portal_mcnda_signatures(version_id,user_id,signer_name,capacity,signature_png,content_hash,email_confirmation,attestation,record_hash) values(v.id,auth.uid(),me.snapshot->>'name',me.snapshot->>'capacity',p_payload->>'signature_png',v.content_hash,proof,rec,h);
 perform portal_private.multi_mcnda_log(v.id,'signature_recorded',rec||jsonb_build_object('record_hash',h));
 if me.is_nexora then update public.portal_mcnda_versions set status='awaiting_bundle' where id=v.id;perform portal_private.multi_mcnda_log(v.id,'all_signatures_recorded',jsonb_build_object('content_hash',v.content_hash));
 else perform portal_private.multi_mcnda_queue(v.id,'client_signed');end if;
 return jsonb_build_object('signed',true,'needs_bundle',me.is_nexora);
 elsif p_action='cancel' then
 if not is_admin or v.status not in ('draft','draft_review','released') then raise exception 'Only an unsigned/in-progress revision can be cancelled';end if;
 update public.portal_mcnda_versions set status='cancelled' where id=v.id;update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null where purpose='mcnda_multi' and document_id=v.id and consumed_at is null;
 perform portal_private.multi_mcnda_log(v.id,'revision_cancelled',jsonb_build_object('reason',left(coalesce(p_payload->>'reason',''),500),'evidence_preserved',true));if v.shared_at is not null then perform portal_private.multi_mcnda_queue(v.id,'cancelled');end if;return jsonb_build_object('cancelled',true);
 end if;raise exception 'Unsupported MCNDA action';
end;$$;
create or replace function public.issue_multi_mcnda_confirmation(p_user_id uuid,p_id uuid,p_document_id uuid,p_document_hash text,p_code_hash text,p_revision integer,p_review_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.portal_members;v public.portal_mcnda_versions;p public.portal_mcnda_parties;th uuid;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 if p_document_hash !~ '^[0-9a-f]{64}$' or p_code_hash !~ '^[0-9a-f]{64}$' then raise exception 'Invalid confirmation';end if;
 select thread_id into th from public.portal_mcnda_versions where id=p_document_id;perform 1 from public.portal_mcnda_threads where id=th for update;
 select * into v from public.portal_mcnda_versions where id=p_document_id for share;
 if not found or v.status<>'released' or v.revision is distinct from p_revision or v.content_hash is distinct from p_document_hash then raise exception 'Current released revision required';end if;
 select * into m from public.portal_members where user_id=p_user_id and active;if not found or not exists(select 1 from auth.users where id=p_user_id and email_confirmed_at is not null and lower(email)=lower(m.email)) then raise exception 'Verified active account required';end if;
 select * into p from public.portal_mcnda_parties where version_id=v.id and user_id=p_user_id;if not found or m.is_admin is distinct from p.is_nexora or exists(select 1 from public.portal_mcnda_signatures where version_id=v.id and user_id=p_user_id) then raise exception 'Assigned unsigned account required';end if;
 if p.is_nexora then
 if not portal_private.multi_mcnda_parties_current(v.id) then raise exception 'Counterparty profile changed or access unavailable';end if;
 if exists(select 1 from public.portal_mcnda_parties x where x.version_id=v.id and not x.is_nexora and not exists(select 1 from public.portal_mcnda_signatures s where s.version_id=x.version_id and s.user_id=x.user_id)) then raise exception 'Counterparty signatures required first';end if;
 elsif not exists(select 1 from public.portal_companies where id=p.company_id and version=p.company_version and access_state='active') then raise exception 'Profile changed; request a new revision';end if;
 if not exists(select 1 from portal_private.multi_mcnda_reviews where token=p_review_token and version_id=v.id and user_id=p_user_id and content_hash=v.content_hash and created_at>now()-interval '1 hour') then raise exception 'Review this exact document first';end if;
 perform pg_advisory_xact_lock(hashtextextended('signing-confirmation:'||p_user_id::text,0));
 if exists(select 1 from portal_private.signing_confirmations where user_id=p_user_id and document_id=v.id and created_at>now()-interval '60 seconds') or (select count(*) from portal_private.signing_confirmations where user_id=p_user_id and document_id=v.id and created_at>now()-interval '1 hour')>=5 or (select count(*) from portal_private.signing_confirmations where user_id=p_user_id and created_at>now()-interval '1 hour')>=30 then raise exception 'RATE_LIMIT';end if;
 update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null where user_id=p_user_id and consumed_at is null and invalidated_at is null and purpose='mcnda_multi' and document_id=v.id;
 insert into portal_private.signing_confirmations(id,user_id,purpose,document_id,document_hash,document_revision,recipient_email,code_hash,review_token,document_kind) values(p_id,p_user_id,'mcnda_multi',v.id,v.content_hash,v.revision,m.email,p_code_hash,p_review_token,'mcnda_multi');
 perform portal_private.multi_mcnda_log(v.id,'confirmation_requested',jsonb_build_object('confirmation_id',p_id,'content_hash',v.content_hash,'expiry_seconds',600),p_user_id);
 return jsonb_build_object('email',m.email,'language',public.mail_language_for_email(m.email),'expires_at',now()+interval '10 minutes');
end;$$;
create or replace function public.multi_mcnda_delivery_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.portal_document_notifications;v public.portal_mcnda_versions;m public.portal_members;ok boolean:=false;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select * into n from public.portal_document_notifications where id=p_id and lease=p_lease and kind='mcnda_multi' and sent_at is null and skipped_at is null;if not found then return jsonb_build_object('allowed',false);end if;
 select * into m from public.portal_members where user_id=n.recipient and active;if not found then return jsonb_build_object('allowed',false);end if;
 select * into v from public.portal_mcnda_versions where id=n.entity_id;
 if not m.is_admin and not exists(select 1 from public.portal_mcnda_parties p join public.portal_companies c on c.id=p.company_id where p.version_id=n.entity_id and p.user_id=m.user_id and c.access_state='active') then return jsonb_build_object('allowed',false);end if;
 if not found or not exists(select 1 from public.portal_mcnda_parties where version_id=v.id and user_id=m.user_id) then return jsonb_build_object('allowed',false);end if;
 if n.event='draft_review' then ok:=v.status='draft_review';
 elsif n.event='released' then ok:=v.status='released' and not exists(select 1 from public.portal_mcnda_signatures where version_id=v.id and user_id=m.user_id);
 elsif n.event='client_signed' then ok:=m.is_admin and v.status in('released','awaiting_bundle');
 elsif n.event='completed' then ok:=v.status='completed' and v.final_pdf is not null;
 elsif n.event in('withdrawn','cancelled') then ok:=v.status in('superseded','cancelled');end if;
 return jsonb_build_object('allowed',ok,'email',m.email,'language',coalesce(n.language,public.mail_language_for_email(m.email)),'event',n.event,'url','https://nexint.eu/mcnda-agreements.html?id='||v.id,'needs_signature',n.event='released');
end;$$;
notify pgrst,'reload schema';commit;