begin;
alter table public.portal_signing_profiles alter column stamp drop not null;
create or replace function public.save_my_signing_profile(p_signature text,p_stamp text,p_expected_version uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare previous uuid;fresh uuid:=gen_random_uuid();img text;raw bytea;individual boolean;
begin
 if auth.uid() is null or not portal_private.is_active() or portal_private.is_admin() then raise exception 'Active client account required';end if;
 select coalesce(c.details->>'ACCOUNT_TYPE'='individual',false) into individual from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=auth.uid();
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));select version into previous from public.portal_signing_profiles where user_id=auth.uid() for update;
 if previous is distinct from p_expected_version then raise exception 'Signing images changed; refresh and try again';end if;
 foreach img in array (case when individual then array[p_signature] else array[p_signature,p_stamp] end) loop
 if img is null or length(img) not between 50 and 900000 or img not like 'data:image/png;base64,%' then raise exception 'Upload valid PNG signing images';end if;
 raw:=decode(substring(img from 23),'base64');if substring(raw from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'Invalid PNG image';end if;end loop;
 insert into public.portal_signing_profiles(user_id,signature,stamp,version) values(auth.uid(),p_signature,case when individual then null else p_stamp end,fresh) on conflict(user_id) do update set signature=excluded.signature,stamp=excluded.stamp,version=excluded.version,updated_at=now();return fresh;
end;$$;
commit;
