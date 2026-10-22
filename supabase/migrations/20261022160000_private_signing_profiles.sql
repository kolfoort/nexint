-- Private reusable signing images; read only by their owner and active Nexora administrators.
create table if not exists public.portal_signing_profiles (
 user_id uuid primary key references public.portal_members(user_id),
 signature text not null, stamp text not null, version uuid not null default gen_random_uuid(), updated_at timestamptz not null default now()
);
alter table public.portal_signing_profiles enable row level security;
revoke all on public.portal_signing_profiles from anon,authenticated;
grant select on public.portal_signing_profiles to authenticated;
create policy signing_profiles_read on public.portal_signing_profiles for select to authenticated using (portal_private.is_active() and (user_id=auth.uid() or portal_private.is_admin()));
create or replace function public.save_my_signing_profile(p_signature text,p_stamp text,p_expected_version uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare previous uuid; fresh uuid:=gen_random_uuid(); img text; raw bytea;
begin
 if auth.uid() is null or not portal_private.is_active() or portal_private.is_admin() then raise exception 'Active client account required';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 select version into previous from public.portal_signing_profiles where user_id=auth.uid() for update;
 if previous is distinct from p_expected_version then raise exception 'Signing images changed; refresh and try again';end if;
 foreach img in array array[p_signature,p_stamp] loop
  if img is null or length(img) not between 50 and 900000 or img not like 'data:image/png;base64,%' then raise exception 'Upload PNG signing images, maximum 650 KB each';end if;
  raw:=decode(substring(img from 23),'base64');
  if substring(raw from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'Invalid PNG image';end if;
 end loop;
 insert into public.portal_signing_profiles(user_id,signature,stamp,version) values(auth.uid(),p_signature,p_stamp,fresh)
 on conflict(user_id) do update set signature=excluded.signature,stamp=excluded.stamp,version=excluded.version,updated_at=now();
 return fresh;
end;$$;
revoke all on function public.save_my_signing_profile(text,text,uuid) from public,anon;
grant execute on function public.save_my_signing_profile(text,text,uuid) to authenticated;

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
   foreach k in array fields loop if k not in ('routing','intermediary') and trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete payment details; mark unused fields Not applicable';end if;end loop;
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
