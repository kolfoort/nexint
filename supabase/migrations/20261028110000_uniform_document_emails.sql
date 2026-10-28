begin;
alter table public.portal_document_notifications drop constraint if exists portal_document_notifications_kind_check;
alter table public.portal_document_notifications add constraint portal_document_notifications_kind_check check(kind in('document','mcnda','commission','spa','fco','jv'));
alter table public.portal_document_notifications add column if not exists event text not null default 'released';
alter table public.portal_document_notifications add column if not exists document_version text;
alter table public.portal_document_notifications drop constraint if exists portal_document_notifications_event_check;
alter table public.portal_document_notifications add constraint portal_document_notifications_event_check check(event in('available','draft_review','released','client_signed','completed','withdrawn','cancelled'));

create or replace function portal_private.queue_document_event(p_client uuid,p_kind text,p_entity uuid,p_version text,p_revision text,p_event text,p_title text) returns void language plpgsql security definer set search_path='' as $$
declare r record;
begin
 for r in select user_id from public.portal_members where active and ((p_event='client_signed' and is_admin) or (p_event<>'client_signed' and not is_admin and user_id=p_client)) loop
 insert into public.portal_document_notifications(recipient,kind,entity_id,version_key,document_version,event,title)
 values(r.user_id,p_kind,p_entity,p_version||':'||p_event||':'||p_revision,p_version,p_event,left(p_title,200)) on conflict do nothing;
 end loop;
 begin perform portal_private.dispatch_document_notifications();exception when others then null;end;
end;$$;
revoke all on function portal_private.queue_document_event(uuid,text,uuid,text,text,text,text) from public,anon,authenticated;

create or replace function portal_private.notify_assigned_agreement() returns trigger language plpgsql security definer set search_path='' as $$
declare k text;v text;rev text;client uuid;ev text;t text;o jsonb:='{}';d jsonb:=to_jsonb(new);
begin
 if tg_op='UPDATE' then o:=to_jsonb(old);end if;
 if tg_table_name='portal_mcnda_assignments' then
 k:='mcnda';client:=new.user_id;v:=new.template_version;rev:=coalesce(d->>'assigned_at','');t:='MCNDA';
 if new.status='draft_review' and o->>'status' is distinct from 'draft_review' then ev:='draft_review';
 elsif new.status='assigned' and o->>'status' is distinct from 'assigned' then ev:='released';
 elsif new.status='cancelled' and o->>'status'='draft_review' then ev:='withdrawn';
 elsif new.status='cancelled' and o->>'status'='assigned' then ev:='cancelled';
 end if;
 else
 k:=case tg_table_name when 'commission_agreements' then 'commission' when 'spa_agreements' then 'spa' when 'fco_agreements' then 'fco' when 'jv_agreements' then 'jv' end;
 if k is null then return new;end if;
 client:=new.recipient;v:=new.version::text;rev:=coalesce(d->>'revision','1');t:=case k when 'commission' then 'Commission Agreement' when 'spa' then 'SPA' when 'fco' then 'FCO' when 'jv' then 'JVA' end||' | '||new.transaction_code;
 if new.status='awaiting_client' and o->>'status' is distinct from 'awaiting_client' then ev:='released';
 elsif new.status='awaiting_approval' and o->>'status' is distinct from 'awaiting_approval' then ev:='client_signed';
 elsif new.status='completed' and o->>'status' is distinct from 'completed' then ev:='completed';
 elsif new.status='cancelled' and (coalesce(o->>'status','draft')<>'draft' or o->'data'->>'draft_shared'='true') then ev:='cancelled';
 elsif new.status='draft' and d->'data'->>'draft_shared'='true' and (o->>'status' is distinct from 'draft' or o->'data'->>'draft_shared' is distinct from 'true') then ev:='draft_review';
 elsif new.status='draft' and coalesce(d->'data'->>'draft_shared','false')<>'true' and o->'data'->>'draft_shared'='true' then ev:='withdrawn';
 end if;
 end if;
 if ev is not null then perform portal_private.queue_document_event(client,k,new.id,v,rev,ev,t);end if;
 return new;
end;$$;
revoke all on function portal_private.notify_assigned_agreement() from public,anon,authenticated;
drop trigger if exists notify_mcnda_assignment on public.portal_mcnda_assignments;
drop trigger if exists notify_commission_assignment on public.commission_agreements;
drop trigger if exists notify_spa_assignment on public.spa_agreements;
drop trigger if exists notify_fco_assignment on public.fco_agreements;
drop trigger if exists notify_jv_assignment on public.jv_agreements;
create trigger notify_mcnda_assignment after insert or update of status on public.portal_mcnda_assignments for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_commission_assignment after insert or update of status,data on public.commission_agreements for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_spa_assignment after insert or update of status,data on public.spa_agreements for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_fco_assignment after insert or update of status,data on public.fco_agreements for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_jv_assignment after insert or update of status,data on public.jv_agreements for each row execute function portal_private.notify_assigned_agreement();

create or replace function portal_private.notify_mcnda_approval_event() returns trigger language plpgsql security definer set search_path='' as $$
declare a public.portal_mcnda_assignments;ev text;
begin
 select * into a from public.portal_mcnda_assignments where id=new.id;
 if tg_op='INSERT' and new.status='awaiting_approval' then ev:='client_signed';
 elsif tg_op='UPDATE' and new.status='completed' and old.status is distinct from 'completed' then ev:='completed';end if;
 if ev is not null then perform portal_private.queue_document_event(new.recipient,'mcnda',new.id,a.template_version,new.revision::text,ev,'MCNDA');end if;
 return new;
end;$$;
revoke all on function portal_private.notify_mcnda_approval_event() from public,anon,authenticated;
drop trigger if exists notify_mcnda_approval_event on public.portal_mcnda_approvals;
create trigger notify_mcnda_approval_event after insert or update of status on public.portal_mcnda_approvals for each row execute function portal_private.notify_mcnda_approval_event();

create or replace function public.document_notification_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.portal_document_notifications;m public.portal_members;a jsonb;ap jsonb;allowed boolean;owner_id uuid;table_name text;url text:='https://nexint.eu/documents.html';v text;st text;test_to text;
begin
 select * into n from public.portal_document_notifications where id=p_id and lease=p_lease and leased_at>now()-interval '5 minutes' and sent_at is null and skipped_at is null;
 if not found then raise exception 'No active delivery lease';end if;
 select * into m from public.portal_members where user_id=n.recipient;
 allowed:=coalesce(m.active,false);v:=coalesce(n.document_version,n.version_key);
 if n.kind='document' then
 allowed:=allowed and not m.is_admin and exists(select 1 from public.portal_document_access g join public.portal_documents d on d.id=g.document_id where g.user_id=n.recipient and d.id=n.entity_id and d.published and coalesce(d.storage_path,'')||':'||coalesce(d.version_date::text,'')=v);
 owner_id:=n.recipient;
 else
 if n.kind='mcnda' then
 select to_jsonb(x) into a from public.portal_mcnda_assignments x where id=n.entity_id;
 select to_jsonb(x) into ap from public.portal_mcnda_approvals x where id=n.entity_id;
 owner_id:=(a->>'user_id')::uuid;st:=case when n.event in('client_signed','completed') then ap->>'status' else a->>'status' end;
 allowed:=allowed and a->>'template_version'=v;
 else
 table_name:=case n.kind when 'commission' then 'commission_agreements' when 'spa' then 'spa_agreements' when 'fco' then 'fco_agreements' when 'jv' then 'jv_agreements' end;
 if table_name is null then raise exception 'Unsupported document type';end if;
 execute format('select to_jsonb(a) from public.%I a where id=$1',table_name) into a using n.entity_id;
 owner_id:=(a->>'recipient')::uuid;st:=a->>'status';allowed:=allowed and a->>'version'=v;
 end if;
 allowed:=allowed and case n.event
 when 'draft_review' then (st='draft_review' or (st='draft' and a->'data'->>'draft_shared'='true'))
 when 'released' then st in('assigned','awaiting_client')
 when 'client_signed' then st='awaiting_approval'
 when 'completed' then st='completed'
 when 'withdrawn' then (n.kind='mcnda' and st='cancelled') or (st='draft' and coalesce(a->'data'->>'draft_shared','false')<>'true')
 when 'cancelled' then st='cancelled'
 else false end;
 if n.event='client_signed' then
 allowed:=allowed and m.is_admin;
 url:='https://nexint.eu/client-files.html?client='||coalesce(a->>'client_user_id',owner_id::text);
 else allowed:=allowed and not m.is_admin and owner_id=n.recipient;
 end if;
 end if;
 if not m.is_admin and exists(select 1 from public.portal_company_members cm join public.portal_companies c on c.id=cm.company_id where cm.user_id=n.recipient and c.access_state is distinct from 'active') then allowed:=false;end if;
 -- Test overrides exist only for database-created test entities and expire automatically.
 select public.mail_route_test_recipient('agreement',n.entity_id) into test_to;
 return jsonb_build_object('allowed',coalesce(allowed,false),'email',case when allowed then coalesce(test_to,m.email) else null end,'url',url,'event',case when n.kind='document' then 'available' else n.event end,'needs_signature',n.event='released' and n.kind<>'document','test',test_to is not null);
end;$$;
revoke all on function public.document_notification_context(uuid,uuid) from public,anon,authenticated;
grant execute on function public.document_notification_context(uuid,uuid) to service_role;
create or replace function portal_private.queue_upload_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.title ~* '^MCNDA[[:space:]]*-' and new.note like 'Completed and electronically signed via the Nexora portal. Awaiting explicit Nexora countersignature.%' then return new;end if;
 insert into public.portal_upload_notifications(submission_id) values(new.id) on conflict do nothing;
 begin perform portal_private.dispatch_upload_notifications();exception when others then update public.portal_upload_notifications set last_error='Dispatch unavailable; queued for retry' where submission_id=new.id;end;
 return new;
end;$$;
notify pgrst,'reload schema';
commit;
