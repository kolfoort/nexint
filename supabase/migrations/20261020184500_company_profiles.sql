begin;
create table public.portal_companies (
 id uuid primary key default gen_random_uuid(),
 details jsonb not null,
 version integer not null default 1,
 status text not null default 'pending' check(status in ('pending','approved')),
 approved_by uuid references public.portal_members(user_id),
 approved_at timestamptz,
 updated_at timestamptz not null default now(),
 created_by uuid not null references public.portal_members(user_id)
);
create table public.portal_company_members (
 user_id uuid primary key references public.portal_members(user_id) on delete cascade,
 company_id uuid not null references public.portal_companies(id)
);
create index portal_company_members_company on public.portal_company_members(company_id);
create table public.portal_document_profiles (
 submission_id uuid primary key references public.portal_submissions(id) on delete cascade,
 company_id uuid not null references public.portal_companies(id),
 company_version integer not null,
 company_status text not null,
 details jsonb not null,
 captured_at timestamptz not null default now()
);
alter table public.portal_companies enable row level security;
alter table public.portal_company_members enable row level security;
alter table public.portal_document_profiles enable row level security;
revoke all on public.portal_companies,public.portal_company_members,public.portal_document_profiles from public,anon,authenticated;
grant select on public.portal_companies,public.portal_company_members,public.portal_document_profiles to authenticated;
grant insert,update,delete on public.portal_company_members to authenticated;
create policy company_read on public.portal_companies for select to authenticated using((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_company_members m where m.user_id=(select auth.uid()) and m.company_id=portal_companies.id)));
create policy company_member_read on public.portal_company_members for select to authenticated using((select portal_private.is_admin()) or (user_id=(select auth.uid()) and (select portal_private.is_active())));
create policy company_member_manage on public.portal_company_members for all to authenticated using((select portal_private.is_admin())) with check((select portal_private.is_admin()));
create policy document_profile_read on public.portal_document_profiles for select to authenticated using((select portal_private.is_admin()) or exists(select 1 from public.portal_submissions s where s.id=submission_id and s.user_id=(select auth.uid()) and (select portal_private.is_active())));

create function portal_private.save_company_details(p_details jsonb,p_expected_version integer) returns public.portal_companies
language plpgsql security definer set search_path='' as $$
declare company public.portal_companies; normalized jsonb;key text;max_length integer;stamp text;
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 -- Serialize first profile creation as well as edits for one account.
 perform 1 from public.portal_members where user_id=auth.uid() for update;
 normalized:='{}'::jsonb;
 foreach key in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->key) is distinct from 'string' then raise exception 'Missing company detail: %',key;end if;
  max_length:=case key when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(trim(p_details->>key))>max_length or (key<>'B_WEBSITE' and length(trim(p_details->>key))=0) then raise exception 'Invalid company detail: %',key;end if;
  normalized:=normalized||jsonb_build_object(key,trim(p_details->>key));
 end loop;
 select c.* into company from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() for update of c;
 if coalesce(company.id::text,'') is distinct from coalesce(p_details->>'B_PROFILE_ID','') then raise exception 'Company link changed; refresh first';end if;
 stamp:=coalesce(p_details->>'B_STAMP_PATH','');
 if stamp<>'' then
  if stamp is distinct from coalesce(company.details->>'B_STAMP_PATH','') and stamp !~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}\.png$') then raise exception 'Invalid company stamp';end if;
  if not exists(select 1 from storage.objects where bucket_id='nexora-company-assets' and name=stamp) then raise exception 'Company stamp not found';end if;
 end if;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',stamp);
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
revoke all on function portal_private.save_company_details(jsonb,integer) from public,anon,authenticated;
create function public.save_my_company_profile(p_details jsonb,p_expected_version integer) returns public.portal_companies
language sql security definer set search_path='' as $$select portal_private.save_company_details(p_details,p_expected_version);$$;
revoke all on function public.save_my_company_profile(jsonb,integer) from public,anon;
grant execute on function public.save_my_company_profile(jsonb,integer) to authenticated;

create function public.approve_company_profile(p_company_id uuid,p_expected_version integer) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 update public.portal_companies set status='approved',approved_by=auth.uid(),approved_at=now() where id=p_company_id and version=p_expected_version;
 if not found then raise exception 'Profile changed; refresh first';end if;
end;$$;
revoke all on function public.approve_company_profile(uuid,integer) from public,anon;
grant execute on function public.approve_company_profile(uuid,integer) to authenticated;

create function portal_private.capture_document_profile() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.portal_document_profiles(submission_id,company_id,company_version,company_status,details)
 select new.id,c.id,c.version,c.status,c.details from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=new.user_id;
 return new;
end;$$;
revoke all on function portal_private.capture_document_profile() from public,anon,authenticated;
create trigger capture_company_profile after insert on public.portal_submissions for each row execute function portal_private.capture_document_profile();

create function public.submit_company_mcnda(p_id uuid,p_details jsonb,p_expected_version integer,p_note text) returns public.portal_companies
language plpgsql security definer set search_path='' as $$
declare company public.portal_companies;path text;
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 path:=auth.uid()::text||'/'||p_id::text||'.pdf';
 if not exists(select 1 from storage.objects where bucket_id='nexora-client-uploads' and name=path) then raise exception 'Upload the PDF first';end if;
 if length(p_note)>2000 then raise exception 'Note too long';end if;
 company:=portal_private.save_company_details(p_details,p_expected_version);
 insert into public.portal_submissions(id,user_id,title,note,storage_path) values(p_id,auth.uid(),left('MCNDA - '||(company.details->>'B_COMPANY'),180),p_note,path);
 return company;
end;$$;
revoke all on function public.submit_company_mcnda(uuid,jsonb,integer,text) from public,anon;
grant execute on function public.submit_company_mcnda(uuid,jsonb,integer,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('nexora-company-assets','nexora-company-assets',false,5242880,array['image/png']);
create function portal_private.can_read_company_stamp(p_name text) returns boolean language sql stable security definer set search_path='' as $$
 select (select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() and c.details->>'B_STAMP_PATH'=p_name));
$$;
revoke all on function portal_private.can_read_company_stamp(text) from public,anon;
grant execute on function portal_private.can_read_company_stamp(text) to authenticated;
create function portal_private.company_stamp_unreferenced(p_name text) returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.portal_companies where details->>'B_STAMP_PATH'=p_name) and not exists(select 1 from public.portal_document_profiles where details->>'B_STAMP_PATH'=p_name);
$$;
revoke all on function portal_private.company_stamp_unreferenced(text) from public,anon;
grant execute on function portal_private.company_stamp_unreferenced(text) to authenticated;
create policy company_stamp_cleanup on storage.objects for delete to authenticated using(bucket_id='nexora-company-assets' and (select portal_private.is_active()) and (storage.foldername(name))[1]=(select auth.uid())::text and (select portal_private.company_stamp_unreferenced(name)));
create policy company_stamp_read on storage.objects for select to authenticated using(bucket_id='nexora-company-assets' and ((select portal_private.can_read_company_stamp(name)) or ((select portal_private.is_active()) and (storage.foldername(name))[1]=(select auth.uid())::text)));
create policy company_stamp_insert on storage.objects for insert to authenticated with check(bucket_id='nexora-company-assets' and (select portal_private.is_active()) and name ~ ('^'||(select auth.uid())::text||'/[0-9a-f-]{36}\.png$'));
commit;
