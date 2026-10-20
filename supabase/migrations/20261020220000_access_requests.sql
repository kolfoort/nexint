begin;
create table public.portal_access_requests (
 id uuid primary key default gen_random_uuid(),details jsonb not null,message text not null default '',source_key text not null,
 status text not null default 'pending' check(status in ('pending','inviting','invited','declined','invitation_failed','existing_account')),
 reviewed_by uuid references public.portal_members(user_id),reviewed_at timestamptz,
 invite_lease uuid,invite_started_at timestamptz,invited_user_id uuid references public.portal_members(user_id),invitation_error text,
 admin_notified boolean not null default false,applicant_notified boolean not null default false,
 notify_attempts integer not null default 0,notify_token_hash text,notify_lease uuid,notify_leased_at timestamptz,next_notification_at timestamptz not null default now(),
 created_at timestamptz not null default now()
);
create index access_request_email on public.portal_access_requests((details->>'B_EMAIL'),created_at desc);
create index access_request_source on public.portal_access_requests(source_key,created_at desc);
alter table public.portal_access_requests enable row level security;
revoke all on public.portal_access_requests from public,anon,authenticated;
grant select on public.portal_access_requests to authenticated;
grant all on public.portal_access_requests to service_role;
create policy access_request_admin_read on public.portal_access_requests for select to authenticated using((select portal_private.is_admin()));

create function public.register_access_request(p_details jsonb,p_message text,p_source_key text) returns uuid
language plpgsql security definer set search_path='' as $$
declare new_id uuid;k text;v text;normalized jsonb:='{}'::jsonb;
begin
 if length(p_source_key)<>64 or p_source_key !~ '^[0-9a-f]+$' or length(p_message)>2000 then raise exception 'Invalid request';end if;
 perform pg_advisory_xact_lock(hashtextextended('nexora-access-global',0));
 if (select count(*) from public.portal_access_requests where created_at>now()-interval '1 hour')>=50 then return null;end if;
 if (select count(*) from public.portal_access_requests where source_key=p_source_key and created_at>now()-interval '1 hour')>=5 then return null;end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  v:=trim(coalesce(p_details->>k,''));
  if length(v)>(case k when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end) then raise exception 'Field too long';end if;
  if k in ('B_COMPANY','B_COUNTRY','B_REPRESENTATIVE','B_EMAIL') and v='' then raise exception 'Required field missing';end if;
  if k='B_EMAIL' then v:=lower(v);if v !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;end if;
  normalized:=normalized||jsonb_build_object(k,v);
 end loop;
 if exists(select 1 from public.portal_access_requests where details->>'B_EMAIL'=normalized->>'B_EMAIL' and (status in ('pending','inviting','invitation_failed','existing_account') or created_at>now()-interval '24 hours')) then return null;end if;
 insert into public.portal_access_requests(details,message,source_key) values(normalized,p_message,p_source_key) returning id into new_id;
 return new_id;
end;$$;
revoke all on function public.register_access_request(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.register_access_request(jsonb,text,text) to service_role;

create function public.claim_access_notification(p_id uuid,p_token_hash text) returns setof public.portal_access_requests
language plpgsql security definer set search_path='' as $$
begin
 return query update public.portal_access_requests set notify_token_hash=null,notify_lease=gen_random_uuid(),notify_leased_at=now(),notify_attempts=notify_attempts+1,next_notification_at=now()+interval '5 minutes'
 where id=p_id and notify_token_hash=p_token_hash and notify_attempts<5 and (notify_leased_at is null or notify_leased_at<now()-interval '5 minutes') returning *;
end;$$;
revoke all on function public.claim_access_notification(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_access_notification(uuid,text) to service_role;
create function portal_private.dispatch_access_notifications() returns void language plpgsql security definer set search_path='' as $$
declare item record;token text;
begin
 for item in select id from public.portal_access_requests where (not admin_notified or not applicant_notified) and notify_attempts<5 and next_notification_at<=now() and (notify_leased_at is null or notify_leased_at<now()-interval '5 minutes') order by created_at limit 10 for update skip locked loop
  token:=encode(extensions.gen_random_bytes(32),'hex');
  update public.portal_access_requests set notify_token_hash=encode(extensions.digest(token,'sha256'),'hex'),next_notification_at=now()+interval '5 minutes' where id=item.id;
  perform net.http_post(url:='https://inndqvdryjiupfzkzsdl.supabase.co/functions/v1/access-requests',headers:=jsonb_build_object('Content-Type','application/json'),body:=jsonb_build_object('action','notify','id',item.id,'token',token),timeout_milliseconds:=45000);
 end loop;
end;$$;
revoke all on function portal_private.dispatch_access_notifications() from public,anon,authenticated;
create function portal_private.queue_access_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin
 begin perform portal_private.dispatch_access_notifications();exception when others then null;end;
 return new;
end;$$;
revoke all on function portal_private.queue_access_notification() from public,anon,authenticated;
create trigger notify_access_request after insert on public.portal_access_requests for each row execute function portal_private.queue_access_notification();

create function public.review_access_request(p_id uuid,p_admin uuid,p_action text) returns setof public.portal_access_requests
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.portal_members where user_id=p_admin and active and is_admin) then raise exception 'Administrator required';end if;
 if p_action='decline' then
  return query update public.portal_access_requests set status='declined',reviewed_by=p_admin,reviewed_at=now() where id=p_id and status in ('pending','invitation_failed','existing_account') returning *;
 elsif p_action='approve' then
  return query update public.portal_access_requests set status='inviting',reviewed_by=p_admin,reviewed_at=now(),invite_lease=gen_random_uuid(),invite_started_at=now(),invitation_error=null where id=p_id and (status in ('pending','invitation_failed') or (status='inviting' and invite_started_at<now()-interval '10 minutes')) returning *;
 else raise exception 'Invalid action';end if;
end;$$;
revoke all on function public.review_access_request(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.review_access_request(uuid,uuid,text) to service_role;

create function public.finish_access_invitation(p_id uuid,p_lease uuid,p_user_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare r public.portal_access_requests;company_id uuid;
begin
 select * into r from public.portal_access_requests where id=p_id and invite_lease=p_lease and status='inviting' for update;
 if not found then raise exception 'Invitation changed';end if;
 if not exists(select 1 from auth.users where id=p_user_id and lower(email)=r.details->>'B_EMAIL' and raw_user_meta_data->>'nexora_access_request'=r.id::text) then raise exception 'Invitee mismatch';end if;
 if exists(select 1 from public.portal_company_members where user_id=p_user_id) then raise exception 'User already linked; review manually';end if;
 insert into public.portal_companies(details,created_by) values(r.details||jsonb_build_object('B_STAMP_PATH',''),p_user_id) returning id into company_id;
 insert into public.portal_company_members(user_id,company_id) values(p_user_id,company_id);
 update public.portal_access_requests set status='invited',invited_user_id=p_user_id,invitation_error=null where id=p_id;
end;$$;
revoke all on function public.finish_access_invitation(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.finish_access_invitation(uuid,uuid,uuid) to service_role;

create function public.find_access_invitee(p_id uuid) returns uuid language sql security definer set search_path='' as $$
 select u.id from auth.users u join public.portal_access_requests r on lower(u.email)=r.details->>'B_EMAIL' where r.id=p_id and u.raw_user_meta_data->>'nexora_access_request'=r.id::text limit 1;
$$;
revoke all on function public.find_access_invitee(uuid) from public,anon,authenticated;
grant execute on function public.find_access_invitee(uuid) to service_role;

create or replace function public.approve_company_profile(p_company_id uuid,p_expected_version integer) returns void language plpgsql security definer set search_path='' as $$
declare details jsonb;k text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select c.details into details from public.portal_companies c where c.id=p_company_id and c.version=p_expected_version for update;
 if not found then raise exception 'Profile changed; refresh first';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL'] loop
  if trim(coalesce(details->>k,''))='' then raise exception 'Client must complete company details before approval';end if;
 end loop;
 update public.portal_companies set status='approved',approved_by=auth.uid(),approved_at=now() where id=p_company_id and version=p_expected_version;
end;$$;
select cron.schedule('nexora-access-email-retry','*/5 * * * *',$$select portal_private.dispatch_access_notifications();$$);
commit;
