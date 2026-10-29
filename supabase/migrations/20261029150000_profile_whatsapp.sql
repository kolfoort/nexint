begin;
create or replace function portal_private.personal_profile_extra(p_details jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb:='{}';k text;
begin
 if p_details ? 'B_WHATSAPP' then
  if jsonb_typeof(p_details->'B_WHATSAPP') <> 'string' or (trim(p_details->>'B_WHATSAPP')<>'' and trim(p_details->>'B_WHATSAPP') !~ '^\+[0-9 ()-]{5,31}$') then raise exception 'Use an international WhatsApp number with country code';end if;
  result:=jsonb_build_object('B_WHATSAPP',trim(p_details->>'B_WHATSAPP'));
 end if;
 if p_details->>'ACCOUNT_TYPE'='individual' then
 foreach k in array array['P_FIRST_NAME','P_LAST_NAME','P_ADDRESS','P_POSTCODE','P_CITY','P_COUNTRY'] loop
 if length(trim(coalesce(p_details->>k,'')))=0 or length(p_details->>k)>100 then raise exception 'Invalid personal profile';end if;result:=result||jsonb_build_object(k,trim(p_details->>k));end loop;
 result:=result||jsonb_build_object('ACCOUNT_TYPE','individual');end if;return result;
end;$$;
revoke all on function portal_private.personal_profile_extra(jsonb) from public,anon,authenticated;

do $migration$
declare f text;old text;new text;
begin
 f:=pg_get_functiondef('portal_private.multi_mcnda_snapshot(jsonb,uuid,text)'::regprocedure);
 old:=$old$else d->>'B_REGISTRATION' end,'whatsapp',''))$old$;
 new:=$new$else d->>'B_REGISTRATION' end,'whatsapp',coalesce(d->>'B_WHATSAPP','')))$new$;
 if position(old in f)=0 then raise exception 'Unexpected snapshot function; migration stopped';end if;
 execute replace(f,old,new);
 select pg_get_functiondef(p.oid) into strict f from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='multi_mcnda_action';
 old:=$old$coalesce(p_payload->'notice_numbers'->>(value->>'user_id'),'')$old$;
 new:=$new$coalesce(p_payload->'notice_numbers'->>(value->>'user_id'),value->>'whatsapp','')$new$;
 if position(old in f)=0 then raise exception 'Unexpected MCNDA function; migration stopped';end if;
 execute replace(f,old,new);
end;$migration$;
notify pgrst,'reload schema';
commit;
