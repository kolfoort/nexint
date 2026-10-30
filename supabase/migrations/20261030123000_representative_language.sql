begin;
-- Reuse the account-wide portal/email preference; do not duplicate it per company.
-- Language-only saves leave company and signing-authority versions unchanged.
create function public.admin_save_representative_language(p_company uuid,p_user_id uuid,p_language text,p_expected_language text) returns text language plpgsql security definer set search_path='' as $$
declare previous text;saved text;
begin
 if not portal_private.is_active() or not portal_private.is_admin() or not portal_private.session_mfa_allowed() then raise exception 'Administrator MFA required';end if;
 perform 1 from public.portal_company_representatives where company_id=p_company and user_id=p_user_id for share;
 if not found then raise exception 'Save the linked representative first';end if;
 previous:=public.admin_client_language(p_user_id);
 saved:=public.admin_save_client_language(p_user_id,p_language,p_expected_language);
 if previous is distinct from saved then
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(p_company,auth.uid(),'representative_language_changed',jsonb_build_object('user_id',p_user_id,'before',previous,'after',saved,'scope','account-wide portal and future notifications'));
 end if;
 return saved;
end;$$;
revoke all on function public.admin_save_representative_language(uuid,uuid,text,text) from public,anon;
grant execute on function public.admin_save_representative_language(uuid,uuid,text,text) to authenticated;
notify pgrst,'reload schema';

commit;
