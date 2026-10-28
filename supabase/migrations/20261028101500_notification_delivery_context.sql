begin;
-- Return only the delivery context for an already claimed, short-lived queue lease.
create or replace function public.document_notification_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.portal_document_notifications;m public.portal_members;allowed boolean;url text:='https://nexint.eu/documents.html';
begin
 select * into n from public.portal_document_notifications where id=p_id and lease=p_lease and leased_at>now()-interval '5 minutes' and sent_at is null and skipped_at is null;
 if not found then raise exception 'No active delivery lease';end if;
 select * into m from public.portal_members where user_id=n.recipient;
 allowed:=coalesce(m.active and not m.is_admin,false);
 if exists(select 1 from public.portal_company_members cm join public.portal_companies c on c.id=cm.company_id where cm.user_id=n.recipient and c.access_state is distinct from 'active') then allowed:=false;end if;
 if n.kind='mcnda' then
 allowed:=allowed and exists(select 1 from public.portal_mcnda_assignments a where a.id=n.entity_id and a.user_id=n.recipient and a.status='assigned' and a.template_version=n.version_key);
 elsif n.kind='document' then
 allowed:=allowed and exists(select 1 from public.portal_document_access g join public.portal_documents d on d.id=g.document_id where g.user_id=n.recipient and d.id=n.entity_id and d.published and coalesce(d.storage_path,'')||':'||coalesce(d.version_date::text,'')=n.version_key);
 elsif n.kind='commission' then
 allowed:=allowed and exists(select 1 from public.commission_agreements a where a.id=n.entity_id and a.recipient=n.recipient and a.status='awaiting_client' and a.version::text=n.version_key);url:='https://nexint.eu/commission-agreements.html?agreement='||n.entity_id;
 elsif n.kind='spa' then
 allowed:=allowed and exists(select 1 from public.spa_agreements a where a.id=n.entity_id and a.recipient=n.recipient and a.status='awaiting_client' and a.version::text=n.version_key);url:='https://nexint.eu/spa-agreements.html?agreement='||n.entity_id;
 elsif n.kind='fco' then
 allowed:=allowed and exists(select 1 from public.fco_agreements a where a.id=n.entity_id and a.recipient=n.recipient and a.status='awaiting_client' and a.version::text=n.version_key);url:='https://nexint.eu/fco-agreements.html?agreement='||n.entity_id;
 else allowed:=false;
 end if;
 return jsonb_build_object('allowed',coalesce(allowed,false),'email',case when allowed then m.email else null end,'url',url,'needs_signature',n.kind<>'document');
end;$$;
revoke all on function public.document_notification_context(uuid,uuid) from public,anon,authenticated;
grant execute on function public.document_notification_context(uuid,uuid) to service_role;
notify pgrst,'reload schema';
commit;
