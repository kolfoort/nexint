begin;
alter table public.portal_companies add column access_state text not null default 'active' check(access_state in ('active','paused','archived'));
create table public.portal_company_events (
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.portal_companies(id),actor_id uuid references public.portal_members(user_id),event text not null,metadata jsonb not null default '{}'::jsonb,created_at timestamptz not null default now()
);
create index company_events_by_company on public.portal_company_events(company_id,created_at desc);
alter table public.portal_company_events enable row level security;
revoke all on public.portal_company_events from public,anon,authenticated;
grant select on public.portal_company_events to authenticated;
create policy company_event_admin_read on public.portal_company_events for select to authenticated using((select portal_private.is_admin()));
-- Company suspension applies on every database and storage request that uses is_active.
-- Existing individual suspensions stay intact when a company is resumed.
create or replace function portal_private.is_active() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.portal_members p where p.user_id=(select auth.uid()) and p.active and (p.is_admin or not exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=p.user_id and c.access_state<>'active')));
$$;
create function public.my_portal_access_allowed() returns boolean language sql stable security definer set search_path='' as $$select portal_private.is_active();$$;
revoke all on function public.my_portal_access_allowed() from public,anon;
grant execute on function public.my_portal_access_allowed() to authenticated;

create function public.manage_company_access(p_company_id uuid,p_expected_version integer,p_expected_state text,p_action text) returns void language plpgsql security definer set search_path='' as $$
declare c public.portal_companies;next_state text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select * into c from public.portal_companies where id=p_company_id for update;
 if not found or c.version<>p_expected_version or c.access_state<>p_expected_state then raise exception 'Company changed; refresh and try again';end if;
 if exists(select 1 from public.portal_company_members m join public.portal_members p on p.user_id=m.user_id where m.company_id=c.id and p.is_admin) then raise exception 'Unlink administrator accounts before changing company access';end if;
 if p_action='pause' and c.access_state='active' then next_state:='paused';
 elsif p_action='resume' and c.access_state='paused' then next_state:='active';
 elsif p_action='archive' and c.access_state in ('active','paused') then next_state:='archived';
 elsif p_action='restore' and c.access_state='archived' then next_state:='paused';
 else raise exception 'Invalid company action';end if;
 update public.portal_companies set access_state=next_state,updated_at=now() where id=c.id;
 insert into public.portal_company_events(company_id,actor_id,event,metadata) values(c.id,auth.uid(),p_action,jsonb_build_object('from',c.access_state,'to',next_state));
end;$$;
revoke all on function public.manage_company_access(uuid,integer,text,text) from public,anon;
grant execute on function public.manage_company_access(uuid,integer,text,text) to authenticated;

create function public.admin_save_company_details(p_company_id uuid,p_expected_version integer,p_details jsonb) returns void language plpgsql security definer set search_path='' as $$
declare c public.portal_companies;normalized jsonb:='{}'::jsonb;k text;v text;max_length integer;changed text[]:='{}';
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select * into c from public.portal_companies where id=p_company_id for update;
 if not found or c.version<>p_expected_version then raise exception 'Profile changed; refresh and try again';end if;
 if c.access_state='archived' then raise exception 'Restore this company before editing';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->k) is distinct from 'string' then raise exception 'Missing company field';end if;
  v:=trim(p_details->>k);max_length:=case k when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(v)>max_length or (k<>'B_WEBSITE' and v='') then raise exception 'Complete all required company details';end if;
  if k='B_EMAIL' and v !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid business email';end if;
  normalized:=normalized||jsonb_build_object(k,v);
  if v is distinct from c.details->>k then changed:=array_append(changed,k);end if;
 end loop;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',coalesce(c.details->>'B_STAMP_PATH',''));
 if normalized is distinct from c.details then
  update public.portal_companies set details=normalized,version=version+1,status='pending',approved_by=null,approved_at=null,updated_at=now() where id=c.id;
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(c.id,auth.uid(),'details_updated',jsonb_build_object('version',c.version+1,'fields',changed));
 end if;
end;$$;
revoke all on function public.admin_save_company_details(uuid,integer,jsonb) from public,anon;
grant execute on function public.admin_save_company_details(uuid,integer,jsonb) to authenticated;

-- Audit client edits and profile approvals.
create function portal_private.audit_company_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='approved' and (old.status is distinct from new.status or old.approved_at is distinct from new.approved_at) then
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(new.id,auth.uid(),'profile_approved',jsonb_build_object('version',new.version));
 elsif new.version<>old.version and not (select portal_private.is_admin()) then
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(new.id,auth.uid(),'client_details_updated',jsonb_build_object('version',new.version));
 end if;
 return new;
end;$$;
revoke all on function portal_private.audit_company_change() from public,anon,authenticated;
create trigger audit_company_change after update on public.portal_companies for each row execute function portal_private.audit_company_change();
create or replace function public.approve_company_profile(p_company_id uuid,p_expected_version integer) returns void language plpgsql security definer set search_path='' as $$
declare details jsonb;k text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select c.details into details from public.portal_companies c where c.id=p_company_id and c.version=p_expected_version for update;
 if not found then raise exception 'Profile changed; refresh first';end if;
 if exists(select 1 from public.portal_companies where id=p_company_id and access_state='archived') then raise exception 'Restore this company before approval';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL'] loop
  if trim(coalesce(details->>k,''))='' then raise exception 'Client must complete company details before approval';end if;
 end loop;
 update public.portal_companies set status='approved',approved_by=auth.uid(),approved_at=now() where id=p_company_id and version=p_expected_version;
end;$$;
commit;
