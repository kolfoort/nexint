begin;
alter table portal_private.individual_identity alter column copy_path drop not null;
create or replace function public.register_individual_access(p_details jsonb,p_message text,p_source_key text,p_passport text,p_copy_path text) returns uuid language plpgsql security definer set search_path='' as $$
declare new_request_id uuid;k text;
begin
 if p_details->>'ACCOUNT_TYPE' is distinct from 'individual' or length(trim(p_passport)) not between 3 and 30 then raise exception 'Invalid personal application';end if;
 foreach k in array array['P_FIRST_NAME','P_LAST_NAME','P_ADDRESS','P_POSTCODE','P_CITY','P_COUNTRY'] loop
 if trim(coalesce(p_details->>k,''))='' then raise exception 'Required personal detail missing';end if;end loop;
 if p_copy_path is not null and (p_copy_path !~ '^[0-9a-f-]{36}\.(pdf|jpg|png)$' or not exists(select 1 from storage.objects where bucket_id='nexora-private-identity' and name=p_copy_path) ) then raise exception 'Signed passport copy required';end if;
 new_request_id:=public.register_access_request(p_details,p_message,p_source_key);
 if new_request_id is not null then
 update public.portal_access_requests set details=details||jsonb_build_object('ACCOUNT_TYPE','individual','P_FIRST_NAME',p_details->>'P_FIRST_NAME','P_LAST_NAME',p_details->>'P_LAST_NAME','P_ADDRESS',p_details->>'P_ADDRESS','P_POSTCODE',p_details->>'P_POSTCODE','P_CITY',p_details->>'P_CITY','P_COUNTRY',p_details->>'P_COUNTRY') where portal_access_requests.id=new_request_id;
 insert into portal_private.individual_identity values(new_request_id,trim(p_passport),p_copy_path,now());
 end if;return new_request_id;
end;$$;

create policy private_identity_upload on storage.objects for insert to authenticated with check(
 bucket_id='nexora-private-identity' and (select portal_private.is_active()) and name ~ ('^'||(select auth.uid())::text||'/[0-9a-f-]{36}\.(pdf|jpg|png)$') and exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=(select auth.uid()) and c.details->>'ACCOUNT_TYPE'='individual'));
create function public.save_my_passport_copy(p_path text,p_signed boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_active()) or not public.my_portal_access_allowed() then raise exception 'Active portal access required';end if;
 if p_signed is distinct from true or p_path !~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}\.(pdf|jpg|png)$') or p_path is null then raise exception 'Signed passport copy required';end if;
 if not exists(select 1 from storage.objects where bucket_id='nexora-private-identity' and name=p_path and (metadata->>'size')::bigint between 1 and 4194304 and metadata->>'mimetype' in('application/pdf','image/jpeg','image/png')) then raise exception 'Upload a valid passport copy first';end if;
 update portal_private.individual_identity i set copy_path=p_path from public.portal_access_requests r where r.id=i.request_id and r.invited_user_id=auth.uid() and r.status='invited' and r.details->>'ACCOUNT_TYPE'='individual';
 if not found then raise exception 'Individual invitation required';end if;
end;$$;
revoke all on function public.save_my_passport_copy(text,boolean) from public,anon;
grant execute on function public.save_my_passport_copy(text,boolean) to authenticated;
create or replace function public.submit_mcnda_for_approval(p_id uuid,p_details jsonb,p_expected_version integer,p_note text,p_pdf text,p_attestation jsonb) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare identity jsonb;
begin
 if exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=auth.uid() and c.details->>'ACCOUNT_TYPE'='individual') then
 identity:=public.individual_identity(auth.uid(),null);
 if identity->>'copy_path' is null or not exists(select 1 from storage.objects where bucket_id='nexora-private-identity' and name=identity->>'copy_path') then raise exception 'Upload your signed passport copy in your profile before signing the MCNDA';end if;
 if p_details->>'ACCOUNT_TYPE' is distinct from 'individual' or identity->>'passport_number' is null or p_details->>'PASSPORT_NUMBER' is distinct from identity->>'passport_number' then raise exception 'Personal passport details must match the registered application';end if;
 end if;
 return public.submit_mcnda_before_individuals(p_id,p_details,p_expected_version,p_note,p_pdf,p_attestation);
end;$$;
revoke all on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) from public,anon;
grant execute on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
