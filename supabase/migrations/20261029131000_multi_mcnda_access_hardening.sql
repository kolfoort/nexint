begin;
create or replace function portal_private.multi_mcnda_visible(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select portal_private.is_active() and (portal_private.is_admin() or exists(select 1 from public.portal_mcnda_parties p join public.portal_mcnda_versions v on v.id=p.version_id join public.portal_companies c on c.id=p.company_id where p.version_id=p_id and p.user_id=auth.uid() and v.shared_at is not null and c.access_state='active'));
$$;
revoke all on function portal_private.multi_mcnda_visible(uuid) from public,anon,service_role;grant execute on function portal_private.multi_mcnda_visible(uuid) to authenticated;
revoke select on public.portal_mcnda_versions from authenticated;
grant select(id,thread_id,revision,status,template_version,content_hash,snapshot,created_by,created_at,released_at,shared_at,final_hash,completed_at) on public.portal_mcnda_versions to authenticated;
revoke select on public.portal_mcnda_signatures from authenticated;
grant select(version_id,user_id,accepted_at,signer_name,capacity,content_hash,record_hash) on public.portal_mcnda_signatures to authenticated;
notify pgrst,'reload schema';commit;
