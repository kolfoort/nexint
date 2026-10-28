begin;
create table portal_private.individual_identity(request_id uuid primary key references public.portal_access_requests(id),passport_number text not null,copy_path text not null,created_at timestamptz not null default now());
alter table portal_private.individual_identity enable row level security;
revoke all on portal_private.individual_identity from public,anon,authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('nexora-private-identity','nexora-private-identity',false,4194304,array['application/pdf','image/jpeg','image/png']);
create function portal_private.can_read_identity(p_path text) returns boolean language sql stable security definer set search_path='' as $$
select (select portal_private.is_active()) and exists(select 1 from portal_private.individual_identity i join public.portal_access_requests r on r.id=i.request_id where i.copy_path=p_path and ((select portal_private.is_admin()) or r.invited_user_id=auth.uid()));$$;
revoke all on function portal_private.can_read_identity(text) from public,anon;grant execute on function portal_private.can_read_identity(text) to authenticated;
create policy private_identity_read on storage.objects for select to authenticated using(bucket_id='nexora-private-identity' and (select portal_private.can_read_identity(name)));
create function public.individual_identity(p_user_id uuid default null,p_request_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 if not (select portal_private.is_admin()) and (p_request_id is not null or p_user_id is distinct from auth.uid()) then raise exception 'Access denied';end if;
 select jsonb_build_object('passport_number',i.passport_number,'copy_path',i.copy_path) into result from portal_private.individual_identity i join public.portal_access_requests r on r.id=i.request_id where (p_request_id is not null and r.id=p_request_id) or (p_request_id is null and r.invited_user_id=p_user_id) limit 1;
 return result;
end;$$;
revoke all on function public.individual_identity(uuid,uuid) from public,anon;grant execute on function public.individual_identity(uuid,uuid) to authenticated;
-- The passport never enters general profile JSON, authentication metadata or notification payloads.
create function public.register_individual_access(p_details jsonb,p_message text,p_source_key text,p_passport text,p_copy_path text) returns uuid language plpgsql security definer set search_path='' as $$
declare new_request_id uuid;k text;
begin
 if p_details->>'ACCOUNT_TYPE' is distinct from 'individual' or length(trim(p_passport)) not between 3 and 30 then raise exception 'Invalid personal application';end if;
 foreach k in array array['P_FIRST_NAME','P_LAST_NAME','P_ADDRESS','P_POSTCODE','P_CITY','P_COUNTRY'] loop
 if trim(coalesce(p_details->>k,''))='' then raise exception 'Required personal detail missing';end if;end loop;
 if p_copy_path !~ '^[0-9a-f-]{36}\.(pdf|jpg|png)$' or not exists(select 1 from storage.objects where bucket_id='nexora-private-identity' and name=p_copy_path) then raise exception 'Signed passport copy required';end if;
 new_request_id:=public.register_access_request(p_details,p_message,p_source_key);
 if new_request_id is not null then
 update public.portal_access_requests set details=details||jsonb_build_object('ACCOUNT_TYPE','individual','P_FIRST_NAME',p_details->>'P_FIRST_NAME','P_LAST_NAME',p_details->>'P_LAST_NAME','P_ADDRESS',p_details->>'P_ADDRESS','P_POSTCODE',p_details->>'P_POSTCODE','P_CITY',p_details->>'P_CITY','P_COUNTRY',p_details->>'P_COUNTRY') where portal_access_requests.id=new_request_id;
 insert into portal_private.individual_identity values(new_request_id,trim(p_passport),p_copy_path,now());
 end if;return new_request_id;
end;$$;
revoke all on function public.register_individual_access(jsonb,text,text,text,text) from public,anon,authenticated;grant execute on function public.register_individual_access(jsonb,text,text,text,text) to service_role;
create function portal_private.personal_profile_extra(p_details jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb:='{}';k text;
begin
 if p_details->>'ACCOUNT_TYPE'='individual' then
 foreach k in array array['P_FIRST_NAME','P_LAST_NAME','P_ADDRESS','P_POSTCODE','P_CITY','P_COUNTRY'] loop
 if length(trim(coalesce(p_details->>k,'')))=0 or length(p_details->>k)>100 then raise exception 'Invalid personal profile';end if;result:=result||jsonb_build_object(k,trim(p_details->>k));end loop;
 result:=result||jsonb_build_object('ACCOUNT_TYPE','individual');end if;return result;
end;$$;
revoke all on function portal_private.personal_profile_extra(jsonb) from public,anon,authenticated;
create or replace function portal_private.save_company_details(p_details jsonb,p_expected_version integer) returns public.portal_companies
language plpgsql security definer set search_path='' as $$
declare company public.portal_companies; normalized jsonb;key text;max_length integer;stamp text;
begin
 if p_details->>'ACCOUNT_TYPE'='individual' and not exists(select 1 from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() and c.details->>'ACCOUNT_TYPE'='individual') then raise exception 'Individual account required';end if;
 if exists(select 1 from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() and c.details->>'ACCOUNT_TYPE'='individual') and p_details->>'ACCOUNT_TYPE' is distinct from 'individual' then raise exception 'Individual account type cannot be changed';end if;
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 -- Serialize first profile creation as well as edits for one account.
 perform 1 from public.portal_members where user_id=auth.uid() for update;
 normalized:='{}'::jsonb;
 foreach key in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->key) is distinct from 'string' then raise exception 'Missing company detail: %',key;end if;
  max_length:=case key when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(trim(p_details->>key))>max_length or (key<>'B_WEBSITE' and not (coalesce(p_details->>'ACCOUNT_TYPE','company')='individual' and key in('B_REGISTRATION','B_TITLE')) and length(trim(p_details->>key))=0) then raise exception 'Invalid company detail: %',key;end if;
  normalized:=normalized||jsonb_build_object(key,trim(p_details->>key));
 end loop;
 select c.* into company from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() for update of c;
 if coalesce(company.id::text,'') is distinct from coalesce(p_details->>'B_PROFILE_ID','') then raise exception 'Company link changed; refresh first';end if;
 stamp:=coalesce(p_details->>'B_STAMP_PATH','');
 if stamp<>'' then
  if stamp is distinct from coalesce(company.details->>'B_STAMP_PATH','') and stamp !~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}\.png$') then raise exception 'Invalid company stamp';end if;
  if not exists(select 1 from storage.objects where bucket_id='nexora-company-assets' and name=stamp) then raise exception 'Company stamp not found';end if;
 end if;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',stamp)||portal_private.personal_profile_extra(p_details);
 if company.id is null then
  if p_expected_version<>0 then raise exception 'Profile changed; refresh first';end if;
  insert into public.portal_companies(details,created_by) values(normalized,auth.uid()) returning * into company;
  insert into public.portal_company_members(user_id,company_id) values(auth.uid(),company.id);
 else
  if company.version is distinct from p_expected_version then raise exception 'Profile changed; refresh first';end if;
  if company.details is distinct from normalized then
   update public.portal_companies set details=normalized,version=version+1,status='pending',approved_by=null,approved_at=null,updated_at=now() where id=company.id returning * into company;
  end if;
 end if;
 return company;
end;$$;
create or replace function public.admin_save_company_details(p_company_id uuid,p_expected_version integer,p_details jsonb) returns void language plpgsql security definer set search_path='' as $$
declare c public.portal_companies;normalized jsonb:='{}'::jsonb;k text;v text;max_length integer;changed text[]:='{}';
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select * into c from public.portal_companies where id=p_company_id for update;
 if not found or c.version<>p_expected_version then raise exception 'Profile changed; refresh and try again';end if;
 if c.access_state='archived' then raise exception 'Restore this company before editing';end if;
 if coalesce(c.details->>'ACCOUNT_TYPE','company') is distinct from coalesce(p_details->>'ACCOUNT_TYPE','company') then raise exception 'Account type cannot be changed';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->k) is distinct from 'string' then raise exception 'Missing company field';end if;
  v:=trim(p_details->>k);max_length:=case k when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(v)>max_length or (k<>'B_WEBSITE' and not (coalesce(p_details->>'ACCOUNT_TYPE','company')='individual' and k in('B_REGISTRATION','B_TITLE')) and v='') then raise exception 'Complete all required company details';end if;
  if k='B_EMAIL' and v !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid business email';end if;
  normalized:=normalized||jsonb_build_object(k,v);
  if v is distinct from c.details->>k then changed:=array_append(changed,k);end if;
 end loop;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',coalesce(c.details->>'B_STAMP_PATH',''))||portal_private.personal_profile_extra(p_details);
 if normalized is distinct from c.details then
  update public.portal_companies set details=normalized,version=version+1,status='pending',approved_by=null,approved_at=null,updated_at=now() where id=c.id;
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(c.id,auth.uid(),'details_updated',jsonb_build_object('version',c.version+1,'fields',changed));
 end if;
end;$$;
create or replace function public.approve_company_profile(p_company_id uuid,p_expected_version integer) returns void language plpgsql security definer set search_path='' as $$
declare details jsonb;k text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select c.details into details from public.portal_companies c where c.id=p_company_id and c.version=p_expected_version for update;
 if not found then raise exception 'Profile changed; refresh first';end if;
 if exists(select 1 from public.portal_companies where id=p_company_id and access_state='archived') then raise exception 'Restore this company before approval';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL'] loop
  if not (coalesce(details->>'ACCOUNT_TYPE','company')='individual' and k in('B_REGISTRATION','B_TITLE')) and trim(coalesce(details->>k,''))='' then raise exception 'Client must complete company details before approval';end if;
 end loop;
 update public.portal_companies set status='approved',approved_by=auth.uid(),approved_at=now() where id=p_company_id and version=p_expected_version;
end;$$;
create function portal_private.individual_broker_role() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='invited' and new.details->>'ACCOUNT_TYPE'='individual' and new.invited_user_id is not null then
 insert into public.portal_counterparty_roles(user_id,counterparty_role,updated_by) values(new.invited_user_id,'introducer_broker',new.invited_user_id) on conflict(user_id) do update set counterparty_role='introducer_broker',updated_at=now();end if;
 return new;end;$$;
revoke all on function portal_private.individual_broker_role() from public,anon,authenticated;
create trigger individual_broker_role after update of status on public.portal_access_requests for each row execute function portal_private.individual_broker_role();
create or replace function public.save_counterparty_role(p_user_id uuid,p_role text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 if p_user_id is distinct from auth.uid() and not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 if p_role not in ('introducer_broker','end_buyer_user','jv_partner','trader_reseller','supplier_seller') or p_role is null then raise exception 'Select a valid counterparty type';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active) then raise exception 'Active registered account required';end if;
 if p_role<>'introducer_broker' and exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=p_user_id and c.details->>'ACCOUNT_TYPE'='individual') then raise exception 'Private individuals are Introducer / Broker';end if;
 insert into public.portal_counterparty_roles(user_id,counterparty_role,updated_by) values(p_user_id,p_role,auth.uid()) on conflict(user_id) do update set counterparty_role=excluded.counterparty_role,updated_by=excluded.updated_by,updated_at=now();
end;$$;
alter function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) rename to submit_mcnda_before_individuals;
revoke all on function public.submit_mcnda_before_individuals(uuid,jsonb,integer,text,text,jsonb) from public,anon,authenticated,service_role;
create function public.submit_mcnda_for_approval(p_id uuid,p_details jsonb,p_expected_version integer,p_note text,p_pdf text,p_attestation jsonb) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare identity jsonb;
begin
 if exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=auth.uid() and c.details->>'ACCOUNT_TYPE'='individual') then
 identity:=public.individual_identity(auth.uid(),null);
 if p_details->>'ACCOUNT_TYPE' is distinct from 'individual' or identity->>'passport_number' is null or p_details->>'PASSPORT_NUMBER' is distinct from identity->>'passport_number' then raise exception 'Personal passport details must match the registered application';end if;
 end if;
 return public.submit_mcnda_before_individuals(p_id,p_details,p_expected_version,p_note,p_pdf,p_attestation);
end;$$;
revoke all on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) from public,anon;
grant execute on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
