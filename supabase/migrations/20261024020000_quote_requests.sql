begin;
create table public.portal_quote_requests (
 id uuid primary key default gen_random_uuid(), reference text generated always as ('NX-'||upper(left(id::text,8))) stored,
 request_key uuid not null unique, recipient uuid references auth.users(id), company_id uuid references public.portal_companies(id),
 email text not null, details jsonb not null, transaction jsonb not null,
 status text not null default 'received' check(status in ('received','in_review','information_required','quoted','closed')),
 revision integer not null default 1, source_key text not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index quote_recipient on public.portal_quote_requests(recipient,created_at desc);
create index quote_source on public.portal_quote_requests(source_key,created_at desc);
alter table public.portal_quote_requests enable row level security;
revoke all on public.portal_quote_requests from public,anon,authenticated;
grant select on public.portal_quote_requests to authenticated;
grant all on public.portal_quote_requests to service_role;
create policy quote_read on public.portal_quote_requests for select to authenticated using((select portal_private.is_admin()) or (recipient=(select auth.uid()) and (select portal_private.is_active())));
create table public.portal_quote_emails(id uuid primary key default gen_random_uuid(),quote_id uuid not null references public.portal_quote_requests(id),revision integer not null,kind text not null check(kind in ('admin','receipt','status')), sent_at timestamptz,attempts integer not null default 0,token_hash text,lease uuid,leased_at timestamptz,next_at timestamptz not null default now(),unique(quote_id,revision,kind));
alter table public.portal_quote_emails enable row level security;
revoke all on public.portal_quote_emails from public,anon,authenticated;
grant all on public.portal_quote_emails to service_role;
create function public.register_quote_request(p_key uuid,p_recipient uuid,p_details jsonb,p_transaction jsonb,p_source text) returns uuid language plpgsql security definer set search_path='' as $$
declare q uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('nexora-quote-submit',0));
 select id into q from public.portal_quote_requests where request_key=p_key;
 if found then return q;end if;
 if (select count(*) from public.portal_quote_requests where created_at>now()-interval '1 hour')>=50 or (select count(*) from public.portal_quote_requests where source_key=p_source and created_at>now()-interval '1 hour')>=5 then raise exception 'Please try again later';end if;
 insert into public.portal_quote_requests(request_key,recipient,email,details,transaction,source_key) values(p_key,p_recipient,lower(p_details->>'B_EMAIL'),p_details,p_transaction,p_source) returning id into q;
 insert into public.portal_quote_emails(quote_id,revision,kind) values(q,1,'admin'),(q,1,'receipt');
 return q;
end;$$;
revoke all on function public.register_quote_request(uuid,uuid,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function public.register_quote_request(uuid,uuid,jsonb,jsonb,text) to service_role;
create function public.claim_my_quotes() returns void language plpgsql security definer set search_path='' as $$
declare u auth.users; q public.portal_quote_requests; c uuid;
begin
 select * into u from auth.users where id=auth.uid() and email_confirmed_at is not null;
 if not found or not (select portal_private.is_active()) then return;end if;
 select company_id into c from public.portal_company_members where user_id=u.id;
 for q in select * from public.portal_quote_requests where recipient=u.id or (recipient is null and id::text=u.raw_user_meta_data->>'nexora_quote_request' and email=lower(u.email)) order by created_at for update loop
  if c is null then
   insert into public.portal_companies(details,created_by) values(q.details||jsonb_build_object('B_STAMP_PATH',''),u.id) returning id into c;
   insert into public.portal_company_members(user_id,company_id) values(u.id,c);
  end if;
  update public.portal_quote_requests set recipient=u.id,company_id=c where id=q.id;
 end loop;
end;$$;
revoke all on function public.claim_my_quotes() from public,anon;
grant execute on function public.claim_my_quotes() to authenticated;
create function public.update_quote_status(p_id uuid,p_revision integer,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare q public.portal_quote_requests;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 if p_status not in ('received','in_review','information_required','quoted','closed') then raise exception 'Invalid status';end if;
 select * into q from public.portal_quote_requests where id=p_id and revision=p_revision for update;
 if not found then raise exception 'Request changed; refresh first';end if;
 if q.status=p_status then return;end if;
 update public.portal_quote_requests set status=p_status,revision=revision+1,updated_at=now() where id=p_id;
 insert into public.portal_quote_emails(quote_id,revision,kind) values(p_id,p_revision+1,'status');
end;$$;
revoke all on function public.update_quote_status(uuid,integer,text) from public,anon;
grant execute on function public.update_quote_status(uuid,integer,text) to authenticated;
create function public.claim_quote_email(p_id uuid,p_hash text) returns setof public.portal_quote_emails language plpgsql security definer set search_path='' as $$
begin return query update public.portal_quote_emails set token_hash=null,lease=gen_random_uuid(),leased_at=now(),attempts=attempts+1 where id=p_id and token_hash=p_hash and sent_at is null and attempts<5 and (leased_at is null or leased_at<now()-interval '5 minutes') returning *;end;$$;
revoke all on function public.claim_quote_email(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_quote_email(uuid,text) to service_role;
create function portal_private.dispatch_quote_emails() returns void language plpgsql security definer set search_path='' as $$
declare r record;t text;
begin
 for r in select id from public.portal_quote_emails where sent_at is null and attempts<5 and next_at<=now() and (leased_at is null or leased_at<now()-interval '5 minutes') order by next_at limit 10 for update skip locked loop
  t:=encode(extensions.gen_random_bytes(32),'hex');
  update public.portal_quote_emails set token_hash=encode(extensions.digest(t,'sha256'),'hex'),next_at=now()+interval '5 minutes' where id=r.id;
  perform net.http_post(url:='https://inndqvdryjiupfzkzsdl.supabase.co/functions/v1/quote-requests',headers:=jsonb_build_object('Content-Type','application/json'),body:=jsonb_build_object('action','notify','id',r.id,'token',t),timeout_milliseconds:=45000);
 end loop;
end;$$;
revoke all on function portal_private.dispatch_quote_emails() from public,anon,authenticated;
select cron.schedule('nexora-quote-email-retry','* * * * *',$$select portal_private.dispatch_quote_emails();$$);
commit;
