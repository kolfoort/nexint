begin;
create table public.portal_document_notifications(
 id uuid primary key default gen_random_uuid(),recipient uuid not null references public.portal_members(user_id) on delete cascade,kind text not null check(kind in('document','mcnda','commission','spa','fco')),entity_id uuid not null,version_key text not null,title text not null,created_at timestamptz not null default now(),sent_at timestamptz,skipped_at timestamptz,attempts integer not null default 0,token_hash text,lease uuid,leased_at timestamptz,next_attempt_at timestamptz not null default now(),last_error text,unique(recipient,kind,entity_id,version_key));
alter table public.portal_document_notifications enable row level security;
revoke all on public.portal_document_notifications from public,anon,authenticated;
grant all on public.portal_document_notifications to service_role;
grant select on public.portal_document_notifications to authenticated;
create policy notification_admin_read on public.portal_document_notifications for select to authenticated using((select portal_private.is_admin()));
create function public.claim_document_notification(p_id uuid,p_token_hash text) returns setof public.portal_document_notifications language plpgsql security definer set search_path='' as $$
begin
 return query update public.portal_document_notifications set token_hash=null,lease=gen_random_uuid(),leased_at=now(),attempts=attempts+1,next_attempt_at=now()+interval '5 minutes' where id=p_id and token_hash=p_token_hash and sent_at is null and skipped_at is null and attempts<5 and (leased_at is null or leased_at<now()-interval '5 minutes') returning *;
end;$$;
revoke all on function public.claim_document_notification(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_document_notification(uuid,text) to service_role;
create function portal_private.dispatch_document_notifications() returns void language plpgsql security definer set search_path='' as $$
declare item record;token text;
begin
 for item in select id from public.portal_document_notifications where sent_at is null and skipped_at is null and attempts<5 and next_attempt_at<=now() and (leased_at is null or leased_at<now()-interval '5 minutes') order by created_at limit 10 for update skip locked loop
 token:=encode(extensions.gen_random_bytes(32),'hex');
 update public.portal_document_notifications set token_hash=encode(extensions.digest(token,'sha256'),'hex'),next_attempt_at=now()+interval '5 minutes' where id=item.id;
 perform net.http_post(url:='https://inndqvdryjiupfzkzsdl.supabase.co/functions/v1/document-notifications',headers:=jsonb_build_object('Content-Type','application/json'),body:=jsonb_build_object('id',item.id,'token',token),timeout_milliseconds:=45000);
 end loop;
end;$$;
revoke all on function portal_private.dispatch_document_notifications() from public,anon,authenticated;
create function portal_private.queue_document_notification(p_recipient uuid,p_kind text,p_entity uuid,p_version text,p_title text) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.portal_members where user_id=p_recipient and active and not is_admin) then return;end if;
 insert into public.portal_document_notifications(recipient,kind,entity_id,version_key,title) values(p_recipient,p_kind,p_entity,p_version,left(coalesce(p_title,'New document'),200)) on conflict do nothing;
 begin perform portal_private.dispatch_document_notifications();exception when others then null;end;
end;$$;
revoke all on function portal_private.queue_document_notification(uuid,text,uuid,text,text) from public,anon,authenticated;
create function portal_private.notify_shared_document() returns trigger language plpgsql security definer set search_path='' as $$
declare d public.portal_documents;r record;
begin
 if tg_table_name='portal_document_access' then
 select * into d from public.portal_documents where id=new.document_id;
 if d.published then perform portal_private.queue_document_notification(new.user_id,'document',d.id,coalesce(d.storage_path,'')||':'||coalesce(d.version_date::text,''),d.title);end if;
 else
 if not new.published then return new;end if;
 if tg_op='UPDATE' and old.published and new.storage_path is not distinct from old.storage_path and new.version_date is not distinct from old.version_date then return new;end if;
 for r in select user_id from public.portal_document_access where document_id=new.id loop
 perform portal_private.queue_document_notification(r.user_id,'document',new.id,coalesce(new.storage_path,'')||':'||coalesce(new.version_date::text,''),new.title);
 end loop;
 end if;
 return new;
end;$$;
revoke all on function portal_private.notify_shared_document() from public,anon,authenticated;
create trigger notify_document_grant after insert on public.portal_document_access for each row execute function portal_private.notify_shared_document();
create trigger notify_document_publish after insert or update of published,storage_path,version_date on public.portal_documents for each row execute function portal_private.notify_shared_document();
create function portal_private.notify_assigned_agreement() returns trigger language plpgsql security definer set search_path='' as $$
declare kind text;recipient uuid;version text;title text;
begin
 if tg_table_name='portal_mcnda_assignments' then
 if new.status<>'assigned' then return new;end if;
 if tg_op='UPDATE' and old.status='assigned' then return new;end if;
 kind:='mcnda';recipient:=new.user_id;version:=new.template_version;title:='MCNDA';
 else
 if new.status<>'awaiting_client' then return new;end if;
 if tg_op='UPDATE' and old.status='awaiting_client' then return new;end if;
 kind:=case tg_table_name when 'commission_agreements' then 'commission' when 'spa_agreements' then 'spa' else 'fco' end;
 recipient:=new.recipient;version:=new.version::text;title:=coalesce(new.data->>'title',case kind when 'commission' then 'Commission agreement' when 'spa' then 'SPA' else 'FCO Petroleum' end)||' | '||new.transaction_code;
 end if;
 perform portal_private.queue_document_notification(recipient,kind,new.id,version,title);return new;
end;$$;
revoke all on function portal_private.notify_assigned_agreement() from public,anon,authenticated;
create trigger notify_mcnda_assignment after insert or update of status on public.portal_mcnda_assignments for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_commission_assignment after insert or update of status on public.commission_agreements for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_spa_assignment after insert or update of status on public.spa_agreements for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_fco_assignment after insert or update of status on public.fco_agreements for each row execute function portal_private.notify_assigned_agreement();
select cron.schedule('nexora-document-email-retry','*/5 * * * *',$$select portal_private.dispatch_document_notifications();$$);
commit;
