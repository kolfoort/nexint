begin;
create table public.portal_mcnda_assignments(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.portal_members(user_id),template_version text not null default '2026-10-20',status text not null default 'assigned' check(status in ('assigned','completed','cancelled')),assigned_by uuid,assigned_at timestamptz not null default now(),submission_id uuid references public.portal_submissions(id) on delete set null,completed_at timestamptz);
create unique index mcnda_one_pending on public.portal_mcnda_assignments(user_id) where status='assigned';
alter table public.portal_mcnda_assignments enable row level security;
revoke all on public.portal_mcnda_assignments from public,anon,authenticated;
grant select on public.portal_mcnda_assignments to authenticated;
create policy mcnda_assignment_read on public.portal_mcnda_assignments for select to authenticated using((select portal_private.is_admin()) or (user_id=(select auth.uid()) and (select portal_private.is_active())));
-- Preserve and link previously completed portal MCNDAs. Do not issue new requests.
insert into public.portal_mcnda_assignments(user_id,status,assigned_at,submission_id,completed_at)
select user_id,'completed',created_at,id,created_at from public.portal_submissions where title ~* '^MCNDA[[:space:]]*-' and note like 'Completed and electronically signed via the Nexora portal.%';
create function public.assign_client_mcnda(p_user_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active and not is_admin) then raise exception 'Select an active client';end if;
 insert into public.portal_mcnda_assignments(user_id,assigned_by) values(p_user_id,auth.uid()) returning id into result;return result;
end;$$;
revoke all on function public.assign_client_mcnda(uuid) from public,anon;
grant execute on function public.assign_client_mcnda(uuid) to authenticated;
create function public.cancel_client_mcnda(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 update public.portal_mcnda_assignments set status='cancelled' where id=p_id and status='assigned';
 if not found then raise exception 'Only pending requests can be cancelled';end if;
end;$$;
revoke all on function public.cancel_client_mcnda(uuid) from public,anon;
grant execute on function public.cancel_client_mcnda(uuid) to authenticated;
create or replace function public.submit_company_mcnda(p_id uuid,p_details jsonb,p_expected_version integer,p_note text) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare company public.portal_companies;path text;request_id uuid;
begin
 if not portal_private.is_active() then raise exception 'Active account required';end if;
 select id into request_id from public.portal_mcnda_assignments where user_id=auth.uid() and status='assigned' for update;
 if not found then raise exception 'Nexora must assign an MCNDA to your account before you can submit it';end if;
 path:=auth.uid()::text||'/'||p_id::text||'.pdf';
 if not exists(select 1 from storage.objects where bucket_id='nexora-client-uploads' and name=path) then raise exception 'Upload the PDF first';end if;
 if length(p_note)>2000 then raise exception 'Note too long';end if;
 company:=portal_private.save_company_details(p_details,p_expected_version);
 insert into public.portal_submissions(id,user_id,title,note,storage_path) values(p_id,auth.uid(),left('MCNDA - '||(company.details->>'B_COMPANY'),180),p_note,path);
 update public.portal_mcnda_assignments set status='completed',submission_id=p_id,completed_at=now() where id=request_id;
 return company;
end;$$;
drop policy if exists nda_template_member_read on storage.objects;
create policy nda_template_member_read on storage.objects for select to authenticated using(bucket_id='nexora-documents' and name='nda-template-v20261020.pdf' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_mcnda_assignments where user_id=(select auth.uid()) and status='assigned'))));
create table public.portal_broker_clients(id uuid primary key default gen_random_uuid(),client_user_id uuid not null references public.portal_members(user_id),broker_user_id uuid not null references public.portal_members(user_id),created_by uuid not null,created_at timestamptz not null default now(),active boolean not null default true,unique(client_user_id,broker_user_id),check(client_user_id<>broker_user_id));
alter table public.portal_broker_clients enable row level security;
revoke all on public.portal_broker_clients from public,anon,authenticated;
grant select on public.portal_broker_clients to authenticated;
create policy broker_link_admin_read on public.portal_broker_clients for select to authenticated using((select portal_private.is_admin()));
create function public.link_client_broker(p_client uuid,p_broker uuid,p_active boolean default true) returns void language plpgsql security definer set search_path='' as $$
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_client and active and not is_admin) or not exists(select 1 from public.portal_members where user_id=p_broker and active and not is_admin) or p_client=p_broker then raise exception 'Select two different active registered accounts';end if;
 insert into public.portal_broker_clients(client_user_id,broker_user_id,created_by,active) values(p_client,p_broker,auth.uid(),p_active) on conflict(client_user_id,broker_user_id) do update set active=excluded.active;
end;$$;
revoke all on function public.link_client_broker(uuid,uuid,boolean) from public,anon;
grant execute on function public.link_client_broker(uuid,uuid,boolean) to authenticated;
alter table public.commission_agreements add column client_user_id uuid references public.portal_members(user_id);
alter table public.portal_mcnda_assignments add column client_user_id uuid references public.portal_members(user_id);
create function public.assign_client_mcnda(p_user_id uuid,p_client_user_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active and not is_admin) then raise exception 'Select an active signer';end if;
 if p_user_id<>p_client_user_id and not exists(select 1 from public.portal_broker_clients where client_user_id=p_client_user_id and broker_user_id=p_user_id and active) then raise exception 'Link this broker to the client first';end if;
 insert into public.portal_mcnda_assignments(user_id,client_user_id,assigned_by) values(p_user_id,p_client_user_id,auth.uid()) returning id into result;return result;
end;$$;
revoke all on function public.assign_client_mcnda(uuid,uuid) from public,anon;
grant execute on function public.assign_client_mcnda(uuid,uuid) to authenticated;

create or replace function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;client_id uuid;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active portal membership required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if length(p_payload::text)>3500000 then raise exception 'Request too large';end if;
 if p_action='create' then
  if not adm then raise exception 'Administrator required';end if;
  recipient_id:=(p_payload->>'recipient')::uuid;
  if not exists(select 1 from public.portal_members m where m.user_id=recipient_id and m.active and not m.is_admin) then raise exception 'Select an active registered client';end if;
  client_id:=coalesce((p_payload->>'client_user_id')::uuid,recipient_id);
  if client_id<>recipient_id and not exists(select 1 from public.portal_broker_clients where client_user_id=client_id and broker_user_id=recipient_id and active) then raise exception 'Link the broker to this client first';end if;
  y:=extract(year from now() at time zone 'Europe/Amsterdam');
  insert into public.commission_counters(year,value) values(y,1) on conflict(year) do update set value=public.commission_counters.value+1 returning value into n;
  d:='{}';foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop d:=d||jsonb_build_object(k,left(trim(coalesce(p_payload->>k,'')),2000));end loop;
  d:=d||jsonb_build_object('transaction','NEX-COM-'||y||'-'||case when n<10000 then lpad(n::text,4,'0') else n::text end,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,client_user_id,transaction_code,data) values(recipient_id,client_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;
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
    if jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000 then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(p_payload->'payment'->>k));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete client details';end if;end loop;
   if d->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose a payment method';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   foreach k in array fields loop if trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete payment details; mark unused fields Not applicable';end if;end loop;
   if p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->>'name' is distinct from d->>'representative' or p_payload->'reviewed' is distinct from 'true'::jsonb then raise exception 'Review the agreement and confirm authority, name and acceptance';end if;
   d:=d||jsonb_build_object('signed_payload_hash',encode(sha256(convert_to(d::text,'UTF8')),'hex'),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'account',email,'user_id',uid,'authority',true,'accepted',true,'method','typed name with authenticated portal acceptance'));
   a.status:='awaiting_approval';
  when 'approve' then
   if a.status<>'awaiting_approval' or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Review beneficiary and verify payment instructions before approval';end if;
   if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Signature assets are not configured';end if;
   if length(coalesce(p_payload->>'pdf','')) not between 100 and 3000000 then raise exception 'Final PDF required';end if;
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

drop policy if exists submission_insert on public.portal_submissions;
create policy submission_insert on public.portal_submissions for insert to authenticated with check(user_id=(select auth.uid()) and (select portal_private.is_active()) and status='received' and title !~* '^MCNDA' and note not like 'Completed and electronically signed via the Nexora portal.%');
commit;
select 'Client file and personal MCNDA assignment installed' as result;
