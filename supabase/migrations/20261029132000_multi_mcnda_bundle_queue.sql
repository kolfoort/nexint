begin;
create table portal_private.multi_mcnda_bundle_jobs(version_id uuid primary key references public.portal_mcnda_versions(id),signer uuid not null references public.portal_members(user_id),created_at timestamptz not null default now(),next_attempt_at timestamptz not null default now(),attempts integer not null default 0,token_hash text,lease uuid,leased_at timestamptz,completed_at timestamptz,last_error text);
alter table portal_private.multi_mcnda_bundle_jobs enable row level security;revoke all on portal_private.multi_mcnda_bundle_jobs from public,anon,authenticated,service_role;
create function portal_private.dispatch_multi_mcnda_bundles() returns void language plpgsql security definer set search_path='' as $$
declare job record;tok text;gateway text:='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlubmRxdmRyeWppdXBmemt6c2RsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIzOTM1NDQsImV4cCI6MjEwNzk2OTU0NH0.ZTAlu7y0Pi8JC0B3PZjUZ_J4eMMrbEy_XbpxH5onFos';
begin
 for job in select version_id from portal_private.multi_mcnda_bundle_jobs where completed_at is null and attempts<5 and next_attempt_at<=now() and (leased_at is null or leased_at<now()-interval '5 minutes') order by created_at limit 5 for update skip locked loop
 tok:=encode(extensions.gen_random_bytes(32),'hex');update portal_private.multi_mcnda_bundle_jobs set token_hash=encode(sha256(convert_to(tok,'UTF8')),'hex'),next_attempt_at=now()+interval '5 minutes' where version_id=job.version_id;
 perform net.http_post(url:='https://inndqvdryjiupfzkzsdl.supabase.co/functions/v1/mcnda-bundle',headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||gateway),body:=jsonb_build_object('id',job.version_id,'job_token',tok),timeout_milliseconds:=45000);
 end loop;
end;$$;
revoke all on function portal_private.dispatch_multi_mcnda_bundles() from public,anon,authenticated,service_role;
create function portal_private.queue_multi_mcnda_bundle() returns trigger language plpgsql security definer set search_path='' as $$declare signer uuid;begin
 if new.status='awaiting_bundle' and old.status is distinct from 'awaiting_bundle' then
 select p.user_id into signer from public.portal_mcnda_parties p join public.portal_mcnda_signatures s on s.version_id=p.version_id and s.user_id=p.user_id where p.version_id=new.id and p.is_nexora;
 if signer is null then raise exception 'Confirmed Nexora signature required';end if;
 insert into portal_private.multi_mcnda_bundle_jobs(version_id,signer) values(new.id,signer) on conflict do nothing;
 perform portal_private.multi_mcnda_log(new.id,'final_pdf_queued',jsonb_build_object('content_hash',new.content_hash));
 begin perform portal_private.dispatch_multi_mcnda_bundles();exception when others then null;end;
 elsif new.status='completed' then update portal_private.multi_mcnda_bundle_jobs set completed_at=now(),token_hash=null,last_error=null where version_id=new.id;end if;return new;
end;$$;
revoke all on function portal_private.queue_multi_mcnda_bundle() from public,anon,authenticated,service_role;
create trigger multi_mcnda_bundle_queue after update of status on public.portal_mcnda_versions for each row execute function portal_private.queue_multi_mcnda_bundle();
create function public.claim_multi_mcnda_bundle(p_id uuid,p_token_hash text) returns jsonb language plpgsql security definer set search_path='' as $$declare j portal_private.multi_mcnda_bundle_jobs;th uuid;begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select thread_id into th from public.portal_mcnda_versions where id=p_id;perform 1 from public.portal_mcnda_threads where id=th for update;
 update portal_private.multi_mcnda_bundle_jobs set token_hash=null,lease=gen_random_uuid(),leased_at=now(),attempts=attempts+1,next_attempt_at=now()+interval '5 minutes' where version_id=p_id and token_hash=p_token_hash and completed_at is null and attempts<5 and (leased_at is null or leased_at<now()-interval '5 minutes') returning * into j;
 if not found then return null;end if;perform portal_private.multi_mcnda_log(p_id,'final_pdf_packaging_started',jsonb_build_object('attempt',j.attempts),null);return jsonb_build_object('signer',j.signer,'lease',j.lease);
end;$$;
revoke all on function public.claim_multi_mcnda_bundle(uuid,text) from public,anon,authenticated;grant execute on function public.claim_multi_mcnda_bundle(uuid,text) to service_role;
create function public.fail_multi_mcnda_bundle(p_id uuid,p_lease uuid) returns void language plpgsql security definer set search_path='' as $$declare th uuid;begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select thread_id into th from public.portal_mcnda_versions where id=p_id;perform 1 from public.portal_mcnda_threads where id=th for update;
 update portal_private.multi_mcnda_bundle_jobs set leased_at=null,last_error='PDF packaging pending',next_attempt_at=now()+interval '5 minutes' where version_id=p_id and lease=p_lease and completed_at is null;
 if found then perform portal_private.multi_mcnda_log(p_id,'final_pdf_packaging_pending',jsonb_build_object('retry_scheduled',true),null);end if;
end;$$;
revoke all on function public.fail_multi_mcnda_bundle(uuid,uuid) from public,anon,authenticated;grant execute on function public.fail_multi_mcnda_bundle(uuid,uuid) to service_role;
select cron.schedule('nexora-multi-mcnda-pdf-retry','* * * * *',$$select portal_private.dispatch_multi_mcnda_bundles();$$);
notify pgrst,'reload schema';commit;
