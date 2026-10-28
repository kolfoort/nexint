begin;
create function public.admin_client_language(p_user_id uuid) returns text language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator access required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and not is_admin) then raise exception 'Client account not found';end if;
 return coalesce((select language from public.portal_language_preferences where user_id=p_user_id),(select case when raw_user_meta_data->>'language' in('en','nl','de','es','ar') then raw_user_meta_data->>'language' end from auth.users where id=p_user_id));
end;$$;
create function public.admin_save_client_language(p_user_id uuid,p_language text,p_expected_language text) returns text language plpgsql security definer set search_path='' as $$
declare previous text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator access required';end if;
 perform 1 from public.portal_members where user_id=p_user_id and not is_admin for update;
 if not found then raise exception 'Client account not found';end if;
 if p_language is null or p_language not in('en','nl','de','es','ar') then raise exception 'Select a supported language';end if;
 previous:=public.admin_client_language(p_user_id);
 if previous is distinct from p_expected_language then raise exception 'Language was changed. Refresh the client file and try again.';end if;
 insert into public.portal_language_preferences(user_id,language) values(p_user_id,p_language) on conflict(user_id) do update set language=excluded.language,updated_at=now();
 update auth.users set raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||jsonb_build_object('language',p_language) where id=p_user_id;
 return p_language;
end;$$;
revoke all on function public.admin_client_language(uuid) from public,anon;
revoke all on function public.admin_save_client_language(uuid,text,text) from public,anon;
grant execute on function public.admin_client_language(uuid) to authenticated;
grant execute on function public.admin_save_client_language(uuid,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
