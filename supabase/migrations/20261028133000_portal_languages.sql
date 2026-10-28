begin;
create table public.portal_language_preferences(user_id uuid primary key references public.portal_members(user_id),language text not null check(language in('en','nl','de','es','ar')),updated_at timestamptz not null default now());
alter table public.portal_language_preferences enable row level security;
revoke all on public.portal_language_preferences from public,anon,authenticated;
grant select on public.portal_language_preferences to authenticated;
create policy language_own_read on public.portal_language_preferences for select to authenticated using(user_id=(select auth.uid()) and (select portal_private.is_active()));
create function public.my_portal_language() returns text language sql security definer set search_path='' as $$ select coalesce((select language from public.portal_language_preferences where user_id=auth.uid()),(select case when raw_user_meta_data->>'language' in('en','nl','de','es','ar') then raw_user_meta_data->>'language' end from auth.users where id=auth.uid())) where (select portal_private.is_active()); $$;
revoke all on function public.my_portal_language() from public,anon;
grant execute on function public.my_portal_language() to authenticated;
create function public.save_my_portal_language(p_language text) returns text language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 if p_language is null or p_language not in('en','nl','de','es','ar') then raise exception 'Select a supported language';end if;
 insert into public.portal_language_preferences(user_id,language) values(auth.uid(),p_language) on conflict(user_id) do update set language=excluded.language,updated_at=now();
 update auth.users set raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||jsonb_build_object('language',p_language) where id=auth.uid();
 return p_language;
end;$$;
revoke all on function public.save_my_portal_language(text) from public,anon;
grant execute on function public.save_my_portal_language(text) to authenticated;
create function public.mail_language_for_email(p_email text) returns text language sql security definer set search_path='' as $$
 select coalesce((select p.language from public.portal_language_preferences p join public.portal_members m on m.user_id=p.user_id where lower(m.email)=lower(p_email)),(select u.raw_user_meta_data->>'language' from auth.users u where lower(u.email)=lower(p_email) and u.raw_user_meta_data->>'language' in('en','nl','de','es','ar')),'en');
$$;
revoke all on function public.mail_language_for_email(text) from public,anon,authenticated;
grant execute on function public.mail_language_for_email(text) to service_role;
-- Authentication metadata is only a presentation preference, never an access claim.
create function portal_private.capture_invited_language() returns trigger language plpgsql security definer set search_path='' as $$
declare pref text;
begin
 select raw_user_meta_data->>'language' into pref from auth.users where id=new.user_id;
 if pref in('en','nl','de','es','ar') then insert into public.portal_language_preferences(user_id,language) values(new.user_id,pref) on conflict do nothing;end if;
 return new;
end;$$;
revoke all on function portal_private.capture_invited_language() from public,anon,authenticated;
create trigger capture_invited_language after insert on public.portal_members for each row execute function portal_private.capture_invited_language();
-- Preserve all existing registration validation and throttling.
alter function public.register_access_request(jsonb,text,text) rename to register_access_request_before_languages;
revoke all on function public.register_access_request_before_languages(jsonb,text,text) from public,anon,authenticated,service_role;
create function public.register_access_request(p_details jsonb,p_message text,p_source_key text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;pref text:=p_details->>'B_LANGUAGE';
begin
 if pref is not null and pref not in('en','nl','de','es','ar') then raise exception 'Select a supported language';end if;
 result:=public.register_access_request_before_languages(p_details,p_message,p_source_key);
 if result is not null and pref is not null then update public.portal_access_requests set details=details||jsonb_build_object('B_LANGUAGE',pref) where id=result;end if;
 return result;
end;$$;
revoke all on function public.register_access_request(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.register_access_request(jsonb,text,text) to service_role;
-- Store the language on queued mail; retries retain the original language.
alter table public.portal_document_notifications add column language text check(language in('en','nl','de','es','ar'));
alter table public.portal_quote_emails add column language text check(language in('en','nl','de','es','ar'));
alter table public.portal_upload_notifications add column language text check(language in('en','nl','de','es','ar'));
create function portal_private.snapshot_mail_language() returns trigger language plpgsql security definer set search_path='' as $$
declare email text;q public.portal_quote_requests;
begin
 if tg_table_name='portal_document_notifications' then select m.email into email from public.portal_members m where m.user_id=new.recipient;
 elsif tg_table_name='portal_quote_emails' then
  select * into q from public.portal_quote_requests where id=new.quote_id;
  if new.kind='admin' then email:='info@nexint.eu';else email:=q.email;end if;
  if new.kind<>'admin' and q.recipient is null and q.details->>'B_LANGUAGE' in('en','nl','de','es','ar') then new.language:=q.details->>'B_LANGUAGE';end if;
 else email:='info@nexint.eu';end if;
 if new.language is null then new.language:=public.mail_language_for_email(email);end if;
 return new;
end;$$;
revoke all on function portal_private.snapshot_mail_language() from public,anon,authenticated;
create trigger snapshot_document_language before insert on public.portal_document_notifications for each row execute function portal_private.snapshot_mail_language();
create trigger snapshot_quote_language before insert on public.portal_quote_emails for each row execute function portal_private.snapshot_mail_language();
create trigger snapshot_upload_language before insert on public.portal_upload_notifications for each row execute function portal_private.snapshot_mail_language();
alter function public.document_notification_context(uuid,uuid) rename to document_notification_context_before_languages;
revoke all on function public.document_notification_context_before_languages(uuid,uuid) from public,anon,authenticated,service_role;
create function public.document_notification_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb;pref text;
begin
 ctx:=public.document_notification_context_before_languages(p_id,p_lease);
 select coalesce(n.language,public.mail_language_for_email(m.email)) into pref from public.portal_document_notifications n join public.portal_members m on m.user_id=n.recipient where n.id=p_id and n.lease=p_lease;
 return ctx||jsonb_build_object('language',pref);
end;$$;
revoke all on function public.document_notification_context(uuid,uuid) from public,anon,authenticated;
grant execute on function public.document_notification_context(uuid,uuid) to service_role;
notify pgrst,'reload schema';
commit;
