begin;
-- Narrow dependency between the already-approved immutable Victory versions.
create table if not exists portal_private.contract_prerequisites (
 version_id uuid primary key references public.portal_mcnda_versions(id),
 prerequisite_id uuid not null references public.portal_mcnda_versions(id),
 check(version_id<>prerequisite_id)
);
alter table portal_private.contract_prerequisites enable row level security;
revoke all on portal_private.contract_prerequisites from public,anon,authenticated;
do $$begin
 if not exists(select 1 from public.portal_mcnda_versions where id='18c69eda-091d-4093-9615-f9f578f306ca' and content_hash='9c6a33dca95d7bcb930c4d6a091db8f647662afde112c6fb82dc81871673e183') or
 not exists(select 1 from public.portal_mcnda_versions where id='34e218d8-ec15-49ae-8066-7816a08ff4ee' and content_hash='8ff783f475006dec4f62398569154ef13af22b6e10bb427aebefadfc23107705') then raise exception 'Approved Victory PDFs do not match';end if;
 if exists(select 1 from public.portal_mcnda_signatures where version_id='34e218d8-ec15-49ae-8066-7816a08ff4ee') then raise exception 'JVA already signed; do not withdraw';end if;
end $$;
insert into portal_private.contract_prerequisites values('34e218d8-ec15-49ae-8066-7816a08ff4ee','18c69eda-091d-4093-9615-f9f578f306ca') on conflict(version_id) do nothing;
create or replace function portal_private.contract_prerequisite_complete(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from portal_private.contract_prerequisites d join public.portal_mcnda_versions m on m.id=d.prerequisite_id where d.version_id=p_id and (m.status<>'completed' or m.final_hash is null or m.final_pdf is null or exists(select 1 from public.portal_mcnda_parties p where p.version_id=m.id and not exists(select 1 from public.portal_mcnda_signatures s where s.version_id=m.id and s.user_id=p.user_id))));
$$;
revoke all on function portal_private.contract_prerequisite_complete(uuid) from public,anon;
grant execute on function portal_private.contract_prerequisite_complete(uuid) to authenticated;
create or replace function portal_private.enforce_contract_prerequisite() returns trigger language plpgsql security definer set search_path='' as $$begin
 if (new.shared_at is not null or new.status in('released','awaiting_bundle','completed')) and not portal_private.contract_prerequisite_complete(new.id) then raise exception 'Complete the linked MCNDA with all counterparty signatures and Nexora countersignature before sharing or releasing the JVA';end if;
 return new;
end $$;
revoke all on function portal_private.enforce_contract_prerequisite() from public,anon,authenticated;
create trigger contract_prerequisite_guard before insert or update of status,shared_at,released_at on public.portal_mcnda_versions for each row execute function portal_private.enforce_contract_prerequisite();
-- Withdraw the unsigned JVA review; retain the exact PDF, identities and history.
update public.portal_mcnda_versions set status='draft',shared_at=null,released_at=null where id='34e218d8-ec15-49ae-8066-7816a08ff4ee' and status='draft_review';
select portal_private.multi_mcnda_log('34e218d8-ec15-49ae-8066-7816a08ff4ee','draft_review_withdrawn',jsonb_build_object('reason','MCNDA must be fully signed and countersigned before JVA becomes visible','prerequisite','18c69eda-091d-4093-9615-f9f578f306ca','content_unchanged',true));
-- Retain the original active-account, party membership and active-company checks.
create or replace function portal_private.multi_mcnda_visible(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select portal_private.is_active() and (portal_private.is_admin() or exists(
 select 1 from public.portal_mcnda_parties p join public.portal_mcnda_versions v on v.id=p.version_id join public.portal_companies c on c.id=p.company_id
 where p.version_id=p_id and p.user_id=auth.uid() and v.shared_at is not null and c.access_state='active'
 and v.status not in('cancelled','superseded') and portal_private.contract_prerequisite_complete(v.id)
 and not exists(select 1 from public.portal_mcnda_versions newer where newer.thread_id=v.thread_id and newer.revision>v.revision and newer.shared_at is not null and newer.status not in('cancelled','superseded'))));
$$;
notify pgrst,'reload schema';
commit;
select id,status,shared_at,portal_private.contract_prerequisite_complete(id) as prerequisite_complete,content_hash from public.portal_mcnda_versions where id in('18c69eda-091d-4093-9615-f9f578f306ca','34e218d8-ec15-49ae-8066-7816a08ff4ee');
