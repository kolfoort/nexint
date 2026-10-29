begin;

create table public.portal_mcnda_threads(id uuid primary key default gen_random_uuid(),title text not null check(length(title) between 1 and 180),owner_id uuid not null references public.portal_members(user_id),created_at timestamptz not null default now());
create table public.portal_mcnda_versions(id uuid primary key default gen_random_uuid(),thread_id uuid not null references public.portal_mcnda_threads(id),revision integer not null check(revision>0),status text not null default 'draft' check(status in('draft','draft_review','released','awaiting_bundle','completed','superseded','cancelled')),template_version text not null,content_pdf text not null,content_hash text not null check(content_hash ~ '^[0-9a-f]{64}$'),snapshot jsonb not null,created_by uuid not null references public.portal_members(user_id),created_at timestamptz not null default now(),released_at timestamptz,shared_at timestamptz,final_pdf text,final_hash text,completed_at timestamptz,unique(thread_id,revision));
create table public.portal_mcnda_parties(version_id uuid not null references public.portal_mcnda_versions(id),user_id uuid not null references public.portal_members(user_id),position integer not null,company_id uuid references public.portal_companies(id),company_version integer,snapshot jsonb not null,is_nexora boolean not null default false,primary key(version_id,user_id),unique(version_id,position));
create table public.portal_mcnda_signatures(version_id uuid not null,user_id uuid not null,accepted_at timestamptz not null default now(),signer_name text not null,capacity text not null,signature_png text not null,content_hash text not null,email_confirmation jsonb not null,attestation jsonb not null,record_hash text not null,primary key(version_id,user_id),foreign key(version_id,user_id) references public.portal_mcnda_parties(version_id,user_id));
create table public.portal_mcnda_events(id bigint generated always as identity primary key,thread_id uuid not null references public.portal_mcnda_threads(id),version_id uuid references public.portal_mcnda_versions(id),actor uuid references public.portal_members(user_id),at timestamptz not null default now(),event text not null,payload jsonb not null,previous_hash text not null,event_hash text not null);
create index mcnda_events_thread on public.portal_mcnda_events(thread_id,id);
create table portal_private.multi_mcnda_reviews(token uuid primary key default gen_random_uuid(),version_id uuid not null references public.portal_mcnda_versions(id),user_id uuid not null,content_hash text not null,created_at timestamptz not null default now());
alter table portal_private.multi_mcnda_reviews enable row level security;
revoke all on portal_private.multi_mcnda_reviews from public,anon,authenticated,service_role;
create function portal_private.multi_mcnda_visible(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$select portal_private.is_active() and (portal_private.is_admin() or exists(select 1 from public.portal_mcnda_parties p join public.portal_mcnda_versions v on v.id=p.version_id where p.version_id=p_id and p.user_id=auth.uid() and v.shared_at is not null))$$;
revoke all on function portal_private.multi_mcnda_visible(uuid) from public,anon,service_role;grant execute on function portal_private.multi_mcnda_visible(uuid) to authenticated;
create function portal_private.multi_mcnda_unchangeable() returns trigger language plpgsql set search_path='' as $$begin raise exception 'Historical records cannot be edited or deleted';end;$$;
revoke all on function portal_private.multi_mcnda_unchangeable() from public,anon,authenticated,service_role;
create trigger mcnda_signatures_immutable before update or delete on public.portal_mcnda_signatures for each row execute function portal_private.multi_mcnda_unchangeable();
create trigger mcnda_parties_immutable before update or delete on public.portal_mcnda_parties for each row execute function portal_private.multi_mcnda_unchangeable();
create trigger mcnda_events_immutable before update or delete on public.portal_mcnda_events for each row execute function portal_private.multi_mcnda_unchangeable();
create trigger mcnda_version_content_immutable before update of thread_id,revision,template_version,content_pdf,content_hash,snapshot,created_by,created_at or delete on public.portal_mcnda_versions for each row execute function portal_private.multi_mcnda_unchangeable();
create function portal_private.multi_mcnda_log(p_id uuid,p_event text,p_payload jsonb default '{}'::jsonb,p_actor uuid default auth.uid()) returns text language plpgsql security definer set search_path='' as $$
declare v public.portal_mcnda_versions;prev text;stamp timestamptz:=clock_timestamp();h text;
begin
 select * into strict v from public.portal_mcnda_versions where id=p_id;
 perform 1 from public.portal_mcnda_threads where id=v.thread_id for update;
 select event_hash into prev from public.portal_mcnda_events where thread_id=v.thread_id order by id desc limit 1;prev:=coalesce(prev,repeat('0',64));
 h:=encode(sha256(convert_to(jsonb_build_object('thread_id',v.thread_id,'version_id',v.id,'actor',p_actor,'at',stamp,'event',p_event,'payload',p_payload,'previous_hash',prev)::text,'UTF8')),'hex');
 insert into public.portal_mcnda_events(thread_id,version_id,actor,at,event,payload,previous_hash,event_hash) values(v.thread_id,v.id,p_actor,stamp,p_event,p_payload,prev,h);return h;
end;$$;
revoke all on function portal_private.multi_mcnda_log(uuid,text,jsonb,uuid) from public,anon,authenticated,service_role;
do $$declare t text;begin foreach t in array array['portal_mcnda_threads','portal_mcnda_versions','portal_mcnda_parties','portal_mcnda_signatures','portal_mcnda_events'] loop
 execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated',t);execute format('grant select on public.%I to authenticated',t);execute format('grant all on public.%I to service_role',t);execute format('create policy portal_mfa_gate on public.%I as restrictive for all to authenticated using ((select portal_private.session_mfa_allowed())) with check ((select portal_private.session_mfa_allowed()))',t);
 end loop;end;$$;
create policy mcnda_thread_read on public.portal_mcnda_threads for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or exists(select 1 from public.portal_mcnda_versions v where v.thread_id=portal_mcnda_threads.id and portal_private.multi_mcnda_visible(v.id))));
create policy mcnda_version_read on public.portal_mcnda_versions for select to authenticated using(portal_private.multi_mcnda_visible(id));
create policy mcnda_party_read on public.portal_mcnda_parties for select to authenticated using(portal_private.multi_mcnda_visible(version_id));
create policy mcnda_signature_read on public.portal_mcnda_signatures for select to authenticated using(portal_private.multi_mcnda_visible(version_id));
create policy mcnda_event_read on public.portal_mcnda_events for select to authenticated using(portal_private.multi_mcnda_visible(version_id));
create function portal_private.multi_mcnda_queue(p_id uuid,p_event text,p_actor uuid default auth.uid()) returns void language plpgsql security definer set search_path='' as $$
declare p record;v public.portal_mcnda_versions;t text;
begin
 select * into strict v from public.portal_mcnda_versions where id=p_id;select title into t from public.portal_mcnda_threads where id=v.thread_id;
 for p in select mp.user_id,mp.is_nexora from public.portal_mcnda_parties mp join public.portal_members m on m.user_id=mp.user_id where mp.version_id=p_id and m.active and ((p_event='client_signed' and mp.is_nexora) or (p_event<>'client_signed' and not mp.is_nexora)) loop
 insert into public.portal_document_notifications(recipient,kind,entity_id,version_key,document_version,event,title)
 values(p.user_id,'mcnda_multi',v.id,v.revision||':'||p_event||':'||coalesce(p_actor::text,''),v.revision::text,p_event,t) on conflict do nothing;
 perform portal_private.multi_mcnda_log(p_id,'notification_queued',jsonb_build_object('recipient',p.user_id,'event',p_event,'language',public.mail_language_for_email((select email from public.portal_members where user_id=p.user_id))));
 end loop;
 begin perform portal_private.dispatch_document_notifications();exception when others then null;end;
end;$$;
revoke all on function portal_private.multi_mcnda_queue(uuid,text,uuid) from public,anon,authenticated,service_role;
alter table public.portal_document_notifications drop constraint portal_document_notifications_kind_check;
alter table public.portal_document_notifications add constraint portal_document_notifications_kind_check check(kind in('document','mcnda','commission','spa','fco','jv','mcnda_multi'));
-- The existing receipt-language trigger snapshots each recipient's language.
notify pgrst,'reload schema';


create function portal_private.multi_mcnda_snapshot(p_users jsonb,p_owner uuid,p_owner_name text) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb:='[]';person record;u uuid;d jsonb;i integer:=1;seen uuid[]:=array[]::uuid[];owner_email text;
begin
 if p_users is null or jsonb_typeof(p_users)<>'array' or jsonb_array_length(p_users) not between 1 and 20 or coalesce(length(trim(p_owner_name)),0) not between 2 and 120 then raise exception 'Select 1-20 signatories and enter the Nexora signatory name';end if;
 select email into owner_email from public.portal_members where user_id=p_owner and active and is_admin;if not found then raise exception 'Active Nexora administrator required';end if;
 result:=jsonb_build_array(jsonb_build_object('user_id',p_owner,'is_nexora',true,'position',0,'account_email',owner_email,'kind','company','legal_name','La Clava Elit BV, trading as Nexora International','name',trim(p_owner_name),'capacity','Authorised Nexora representative','address','Herengracht 208, 1016 BS Amsterdam','country','The Netherlands','registration','La Clava Elit BV','whatsapp',''));
 for u in select value::uuid from jsonb_array_elements_text(p_users) loop
 if u=p_owner or u=any(seen) then raise exception 'Duplicate signatory';end if;seen:=array_append(seen,u);
 select m.email,c.id company_id,c.version,c.details,c.access_state,c.status into person from public.portal_members m join public.portal_company_members cm on cm.user_id=m.user_id join public.portal_companies c on c.id=cm.company_id join auth.users au on au.id=m.user_id where m.user_id=u and m.active and not m.is_admin and au.email_confirmed_at is not null and lower(au.email)=lower(m.email) for share of c;
 if not found or person.access_state<>'active' then raise exception 'Every counterparty needs an active verified account and saved profile';end if;
 d:=person.details;
 if coalesce(trim(d->>'B_COMPANY'),'')='' or coalesce(trim(d->>'B_ADDRESS'),'')='' or coalesce(trim(d->>'B_COUNTRY'),'')='' then raise exception 'Complete legal name, address and country in each profile first';end if;
 if d->>'ACCOUNT_TYPE' is distinct from 'individual' and (coalesce(trim(d->>'B_REGISTRATION'),'')='' or coalesce(trim(d->>'B_REPRESENTATIVE'),'')='' or coalesce(trim(d->>'B_TITLE'),'')='') then raise exception 'Complete company registration and representative details first';end if;
 result:=result||jsonb_build_array(jsonb_build_object('user_id',u,'is_nexora',false,'position',i,'company_id',person.company_id,'company_version',person.version,'account_email',person.email,'kind',case when d->>'ACCOUNT_TYPE'='individual' then 'individual' else 'company' end,'legal_name',d->>'B_COMPANY','name',case when d->>'ACCOUNT_TYPE'='individual' then d->>'B_COMPANY' else d->>'B_REPRESENTATIVE' end,'capacity',case when d->>'ACCOUNT_TYPE'='individual' then 'Broker / Introducer, personally' else d->>'B_TITLE' end,'address',d->>'B_ADDRESS','country',d->>'B_COUNTRY','registration',case when d->>'ACCOUNT_TYPE'='individual' then 'Not applicable' else d->>'B_REGISTRATION' end,'whatsapp',''));
 i:=i+1;
 end loop;return jsonb_build_object('template','NEX-MCNDA-ICC-MULTI-20261029-R2','parties',result);
end;$$;
revoke all on function portal_private.multi_mcnda_snapshot(jsonb,uuid,text) from public,anon,authenticated,service_role;
create function public.multi_mcnda_action(p_action text,p_id uuid default null,p_expected_revision integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
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
revoke all on function public.multi_mcnda_action(text,uuid,integer,jsonb) from public,anon,service_role;grant execute on function public.multi_mcnda_action(text,uuid,integer,jsonb) to authenticated;
notify pgrst,'reload schema';


alter table portal_private.signing_confirmations drop constraint signing_confirmations_purpose_check;
alter table portal_private.signing_confirmations add constraint signing_confirmations_purpose_check check(purpose in('mcnda_client','mcnda_admin','commission_client','commission_admin','spa_client','spa_admin','jv_client','jv_admin','fco_client','fco_admin','mcnda_multi'));
create function public.issue_multi_mcnda_confirmation(p_user_id uuid,p_id uuid,p_document_id uuid,p_document_hash text,p_code_hash text,p_revision integer,p_review_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
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
revoke all on function public.issue_multi_mcnda_confirmation(uuid,uuid,uuid,text,text,integer,uuid) from public,anon,authenticated;grant execute on function public.issue_multi_mcnda_confirmation(uuid,uuid,uuid,text,text,integer,uuid) to service_role;
create function portal_private.multi_mcnda_confirmation_event() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.purpose<>'mcnda_multi' then return new;end if;
 if new.delivered_at is distinct from old.delivered_at and new.delivered_at is not null then perform portal_private.multi_mcnda_log(new.document_id,'confirmation_mail_submitted',jsonb_build_object('confirmation_id',new.id,'meaning','SMTP accepted; does not prove recipient read'),new.user_id);end if;
 if new.attempts>old.attempts then perform portal_private.multi_mcnda_log(new.document_id,case when new.verified_at is not null then 'confirmation_verified' else 'confirmation_attempt_rejected' end,jsonb_build_object('confirmation_id',new.id,'attempt',new.attempts),new.user_id);end if;
 if new.verified_at is distinct from old.verified_at and new.verified_at is not null and new.attempts=old.attempts then perform portal_private.multi_mcnda_log(new.document_id,'confirmation_verified',jsonb_build_object('confirmation_id',new.id),new.user_id);end if;
 if new.invalidated_at is distinct from old.invalidated_at and new.invalidated_at is not null then perform portal_private.multi_mcnda_log(new.document_id,'confirmation_invalidated',jsonb_build_object('confirmation_id',new.id),new.user_id);end if;
 return new;end;$$;
revoke all on function portal_private.multi_mcnda_confirmation_event() from public,anon,authenticated,service_role;
create trigger mcnda_confirmation_audit after update on portal_private.signing_confirmations for each row execute function portal_private.multi_mcnda_confirmation_event();
create function public.multi_mcnda_delivery_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.portal_document_notifications;v public.portal_mcnda_versions;m public.portal_members;ok boolean:=false;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select * into n from public.portal_document_notifications where id=p_id and lease=p_lease and kind='mcnda_multi' and sent_at is null and skipped_at is null;if not found then return jsonb_build_object('allowed',false);end if;
 select * into m from public.portal_members where user_id=n.recipient and active;if not found then return jsonb_build_object('allowed',false);end if;
 select * into v from public.portal_mcnda_versions where id=n.entity_id;
 if not found or not exists(select 1 from public.portal_mcnda_parties where version_id=v.id and user_id=m.user_id) then return jsonb_build_object('allowed',false);end if;
 if n.event='draft_review' then ok:=v.status='draft_review';
 elsif n.event='released' then ok:=v.status='released' and not exists(select 1 from public.portal_mcnda_signatures where version_id=v.id and user_id=m.user_id);
 elsif n.event='client_signed' then ok:=m.is_admin and v.status in('released','awaiting_bundle');
 elsif n.event='completed' then ok:=v.status='completed' and v.final_pdf is not null;
 elsif n.event in('withdrawn','cancelled') then ok:=v.status in('superseded','cancelled');end if;
 return jsonb_build_object('allowed',ok,'email',m.email,'language',coalesce(n.language,public.mail_language_for_email(m.email)),'event',n.event,'url','https://nexint.eu/mcnda-agreements.html?id='||v.id,'needs_signature',n.event='released');
end;$$;
revoke all on function public.multi_mcnda_delivery_context(uuid,uuid) from public,anon,authenticated;grant execute on function public.multi_mcnda_delivery_context(uuid,uuid) to service_role;
create function portal_private.multi_mcnda_notification_event() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.kind='mcnda_multi' then
 if new.sent_at is distinct from old.sent_at and new.sent_at is not null then perform portal_private.multi_mcnda_log(new.entity_id,'notification_mail_submitted',jsonb_build_object('notification_id',new.id,'recipient',new.recipient,'event',new.event,'language',new.language,'meaning','SMTP accepted; does not prove recipient read'),null);
 elsif new.skipped_at is distinct from old.skipped_at and new.skipped_at is not null then perform portal_private.multi_mcnda_log(new.entity_id,'notification_skipped',jsonb_build_object('notification_id',new.id,'event',new.event,'recipient',new.recipient),null);
 elsif new.last_error is distinct from old.last_error and new.last_error is not null then perform portal_private.multi_mcnda_log(new.entity_id,'notification_delivery_pending',jsonb_build_object('notification_id',new.id,'event',new.event,'recipient',new.recipient),null);end if;end if;return new;end;$$;
revoke all on function portal_private.multi_mcnda_notification_event() from public,anon,authenticated,service_role;
create trigger mcnda_notification_audit after update on public.portal_document_notifications for each row execute function portal_private.multi_mcnda_notification_event();
create function public.multi_mcnda_bundle_input(p_id uuid,p_actor uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.portal_mcnda_versions;rows jsonb;head text;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select * into v from public.portal_mcnda_versions where id=p_id;if not found or v.status not in('awaiting_bundle','completed') or not exists(select 1 from public.portal_mcnda_signatures s join public.portal_mcnda_parties p on p.version_id=s.version_id and p.user_id=s.user_id where s.version_id=v.id and s.user_id=p_actor and p.is_nexora) then raise exception 'Explicit Nexora signature required';end if;
 if exists(select 1 from public.portal_mcnda_parties p where p.version_id=v.id and not exists(select 1 from public.portal_mcnda_signatures s where s.version_id=p.version_id and s.user_id=p.user_id)) then raise exception 'All signatures required';end if;
 select jsonb_agg(to_jsonb(s)||jsonb_build_object('party',p.snapshot) order by s.accepted_at) into rows from public.portal_mcnda_signatures s join public.portal_mcnda_parties p on p.version_id=s.version_id and p.user_id=s.user_id where s.version_id=v.id;
 select event_hash into head from public.portal_mcnda_events where thread_id=v.thread_id order by id desc limit 1;
 return jsonb_build_object('version',to_jsonb(v),'signatures',rows,'audit_checkpoint',head);
end;$$;
revoke all on function public.multi_mcnda_bundle_input(uuid,uuid) from public,anon,authenticated;grant execute on function public.multi_mcnda_bundle_input(uuid,uuid) to service_role;
create function public.multi_mcnda_finish_bundle(p_id uuid,p_actor uuid,p_content_hash text,p_pdf text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.portal_mcnda_versions;bytes bytea;th uuid;h text;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select thread_id into th from public.portal_mcnda_versions where id=p_id;perform 1 from public.portal_mcnda_threads where id=th for update;
 select * into v from public.portal_mcnda_versions where id=p_id for update;
 if v.status='completed' then return jsonb_build_object('completed',true,'hash',v.final_hash);end if;
 if v.status<>'awaiting_bundle' or v.content_hash is distinct from p_content_hash or not exists(select 1 from public.portal_mcnda_signatures s join public.portal_mcnda_parties p on p.version_id=s.version_id and p.user_id=s.user_id where s.version_id=v.id and s.user_id=p_actor and p.is_nexora) then raise exception 'Confirmed signatures required';end if;
 if length(coalesce(p_pdf,'')) not between 500 and 24000000 then raise exception 'Final PDF required';end if;bytes:=decode(p_pdf,'base64');if substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;h:=encode(sha256(bytes),'hex');
 update public.portal_mcnda_versions set status='completed',final_pdf=p_pdf,final_hash=h,completed_at=now() where id=v.id;
 perform portal_private.multi_mcnda_log(v.id,'agreement_completed',jsonb_build_object('content_hash',v.content_hash,'final_bundle_hash',h,'all_signatures_required',true,'generated_by','server_bundle_function'),p_actor);perform portal_private.multi_mcnda_queue(v.id,'completed',p_actor);
 return jsonb_build_object('completed',true,'hash',h);
end;$$;
revoke all on function public.multi_mcnda_finish_bundle(uuid,uuid,text,text) from public,anon,authenticated;grant execute on function public.multi_mcnda_finish_bundle(uuid,uuid,text,text) to service_role;
notify pgrst,'reload schema';

-- Additional public code verification path uses the same lock order as version changes.

create function public.verify_multi_mcnda_confirmation(p_id uuid,p_code text) returns jsonb language plpgsql security definer set search_path='' as $$
declare c portal_private.signing_confirmations;th uuid;tok uuid;
begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() then raise exception 'MFA_REQUIRED';end if;
 select v.thread_id into th from portal_private.signing_confirmations sc join public.portal_mcnda_versions v on v.id=sc.document_id where sc.id=p_id and sc.user_id=auth.uid() and sc.purpose='mcnda_multi';
 if th is null then return jsonb_build_object('verified',false);end if;perform 1 from public.portal_mcnda_threads where id=th for update;
 select * into c from portal_private.signing_confirmations where id=p_id and user_id=auth.uid() and purpose='mcnda_multi' for update;
 if not found or c.delivered_at is null or c.invalidated_at is not null or c.consumed_at is not null or c.verified_at is not null or c.expires_at<now() or c.attempts>=5 or not exists(select 1 from public.portal_mcnda_versions where id=c.document_id and status='released' and content_hash=c.document_hash and revision=c.document_revision) then return jsonb_build_object('verified',false);end if;
 if p_code !~ '^[0-9]{8}$' or c.code_hash is distinct from encode(sha256(convert_to(c.id::text||':'||p_code,'UTF8')),'hex') then
 update portal_private.signing_confirmations set attempts=attempts+1,invalidated_at=case when attempts>=4 then now() else invalidated_at end,code_hash=case when attempts>=4 then null else code_hash end where id=c.id;return jsonb_build_object('verified',false);end if;
 tok:=gen_random_uuid();update portal_private.signing_confirmations set attempts=attempts+1,verified_at=now(),verification_token=tok,code_hash=null where id=c.id;
 return jsonb_build_object('verified',true,'confirmation_id',c.id,'confirmation_token',tok,'verified_at',now());
end;$$;
revoke all on function public.verify_multi_mcnda_confirmation(uuid,text) from public,anon,service_role;grant execute on function public.verify_multi_mcnda_confirmation(uuid,text) to authenticated;
create function public.mark_multi_mcnda_confirmation_delivery(p_id uuid,p_delivered boolean) returns void language plpgsql security definer set search_path='' as $$declare th uuid;begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select v.thread_id into th from portal_private.signing_confirmations sc join public.portal_mcnda_versions v on v.id=sc.document_id where sc.id=p_id and sc.purpose='mcnda_multi';perform 1 from public.portal_mcnda_threads where id=th for update;
 if p_delivered then update portal_private.signing_confirmations set delivered_at=now() where id=p_id and purpose='mcnda_multi' and invalidated_at is null;
 else update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null where id=p_id and purpose='mcnda_multi' and consumed_at is null;end if;
end;$$;
revoke all on function public.mark_multi_mcnda_confirmation_delivery(uuid,boolean) from public,anon,authenticated;grant execute on function public.mark_multi_mcnda_confirmation_delivery(uuid,boolean) to service_role;
notify pgrst,'reload schema';


create function public.multi_mcnda_audit_summary(p_thread uuid) returns jsonb language plpgsql security definer set search_path='' as $$declare e public.portal_mcnda_events;prev text:=repeat('0',64);h text;n integer:=0;ok boolean:=true;begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() then raise exception 'MFA_REQUIRED';end if;
 if not exists(select 1 from public.portal_mcnda_versions where thread_id=p_thread and portal_private.multi_mcnda_visible(id)) then raise exception 'Agreement unavailable';end if;
 for e in select * from public.portal_mcnda_events where thread_id=p_thread order by id loop
 h:=encode(sha256(convert_to(jsonb_build_object('thread_id',e.thread_id,'version_id',e.version_id,'actor',e.actor,'at',e.at,'event',e.event,'payload',e.payload,'previous_hash',e.previous_hash)::text,'UTF8')),'hex');
 if e.previous_hash<>prev or e.event_hash<>h then ok:=false;end if;prev:=e.event_hash;n:=n+1;
 end loop;return jsonb_build_object('valid',ok,'events',n,'head',prev,'scope','thread','method','SHA-256 chained server records; database-owner rewrite remains possible; retain independent exports');end;$$;
revoke all on function public.multi_mcnda_audit_summary(uuid) from public,anon,service_role;grant execute on function public.multi_mcnda_audit_summary(uuid) to authenticated;
create function public.multi_mcnda_export(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$declare v public.portal_mcnda_versions;result jsonb;begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() then raise exception 'MFA_REQUIRED';end if;
 select * into v from public.portal_mcnda_versions where id=p_id and portal_private.multi_mcnda_visible(id);if not found then raise exception 'Agreement unavailable';end if;
 perform portal_private.multi_mcnda_log(v.id,'evidence_exported',jsonb_build_object('content_hash',v.content_hash,'final_hash',v.final_hash));
 result:=jsonb_build_object('exported_at',now(),'agreement_id',v.thread_id,'version_id',v.id,'revision',v.revision,'template',v.template_version,'status',v.status,'content_sha256',v.content_hash,'final_pdf_sha256',v.final_hash,'party_snapshot',v.snapshot,'signatures',(select coalesce(jsonb_agg(to_jsonb(s)-'signature_png' order by accepted_at),'[]') from public.portal_mcnda_signatures s where s.version_id=v.id),'events',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]') from public.portal_mcnda_events e where e.version_id=v.id),'integrity',public.multi_mcnda_audit_summary(v.thread_id),'assurance','Authenticated account, explicit ordinary electronic signature, document-bound registered-email confirmation; not a qualified signature. SMTP submission is not proof of receipt or reading. No passport copies or OTP values in this export.');
 return result;
end;$$;
revoke all on function public.multi_mcnda_export(uuid) from public,anon,service_role;grant execute on function public.multi_mcnda_export(uuid) to authenticated;
notify pgrst,'reload schema';

notify pgrst,'reload schema';
commit;
