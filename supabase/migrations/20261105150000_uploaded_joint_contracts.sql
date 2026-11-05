-- Private uploaded MCNDA/JVA content uses the existing shared, immutable signing
-- pipeline. No existing version, signature, recipient or standard term is changed.
begin;
create table portal_private.uploaded_contract_migration_backup(
 function_name text primary key, definition text not null, saved_at timestamptz not null default now()
);
alter table portal_private.uploaded_contract_migration_backup enable row level security;
revoke all on portal_private.uploaded_contract_migration_backup from public,anon,authenticated,service_role;
insert into portal_private.uploaded_contract_migration_backup(function_name,definition)
select signature,pg_get_functiondef(signature::regprocedure) from (values
 ('public.multi_mcnda_action(text,uuid,integer,jsonb)'),
 ('public.multi_mcnda_delivery_context(uuid,uuid)'),
 ('public.issue_multi_mcnda_confirmation(uuid,uuid,uuid,text,text,integer,uuid)')
) as functions(signature);
create function portal_private.uploaded_contract_snapshot(p_payload jsonb,p_owner uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare snap jsonb;doc jsonb;
begin
 snap:=portal_private.mcnda_snapshot_representatives(p_payload->'users',p_owner,p_payload->>'owner_name',coalesce(p_payload->'representations','{}'::jsonb));
 doc:=p_payload->'document';
 if doc is null or doc='null'::jsonb then return snap;end if;
 if jsonb_typeof(doc)<>'object' or coalesce(doc->>'kind','') not in('MCNDA','JVA')
 or coalesce(doc->>'reference','') !~ '^[A-Z0-9][A-Z0-9._/-]{2,119}$'
 or coalesce(doc->>'sha256','') !~ '^[0-9a-f]{64}$'
 or length(coalesce(doc->>'filename','')) not between 5 and 180
 or doc->>'filename' ~ E'[\r\n/\\\\]' or lower(doc->>'filename') not like '%.pdf'
 or coalesce(doc->>'pages','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid uploaded agreement metadata';end if;
 if (doc->>'pages')::integer not between 1 and 250 then raise exception 'Invalid PDF page count';end if;
 -- Only explicit metadata is accepted, never a client-supplied party snapshot.
 doc:=jsonb_build_object('kind',doc->>'kind','reference',doc->>'reference','filename',doc->>'filename','sha256',doc->>'sha256','pages',(doc->>'pages')::integer);
 return snap||jsonb_build_object('template','NEX-UPLOADED-CONTRACT-20261105-R1','document',doc);
end;$$;
revoke all on function portal_private.uploaded_contract_snapshot(jsonb,uuid) from public,anon,authenticated,service_role;

do $patch$
declare f text;anchor text;
begin
 f:=pg_get_functiondef('public.multi_mcnda_action(text,uuid,integer,jsonb)'::regprocedure);
 anchor:=$a$portal_private.mcnda_snapshot_representatives(p_payload->'users',auth.uid(),p_payload->>'owner_name',coalesce(p_payload->'representations','{}'::jsonb))$a$;
 if position(anchor in f)=0 then raise exception 'Unexpected shared signing snapshot implementation';end if;
 f:=replace(f,anchor,'portal_private.uploaded_contract_snapshot(p_payload,auth.uid())');
 anchor:=$a$if p_id is null then insert into public.portal_mcnda_threads$a$;
 if position(anchor in f)=0 then raise exception 'Unexpected shared signing creation implementation';end if;
 f:=replace(f,anchor,$a$
 if snap ? 'document' then
  if octet_length(content)>14000000 or snap->'document'->>'sha256' is distinct from encode(sha256(content),'hex') then raise exception 'Uploaded PDF fingerprint mismatch';end if;
  if p_payload->>'uploaded_content_confirmed' is distinct from 'true' then raise exception 'Confirm the exact uploaded PDF and all party details';end if;
 end if;
 if p_id is not null then
  select * into oldv from public.portal_mcnda_versions where thread_id=p_id order by revision desc limit 1;
  if found and ((oldv.snapshot ? 'document') or (snap ? 'document')) then
   if (oldv.snapshot ? 'document') is distinct from (snap ? 'document')
    or oldv.snapshot->'document'->>'kind' is distinct from snap->'document'->>'kind'
    or oldv.snapshot->'document'->>'reference' is distinct from snap->'document'->>'reference'
    then raise exception 'Start a separate agreement for a different contract type or reference';end if;
  end if;
 end if;
 if p_id is null then insert into public.portal_mcnda_threads$a$);
 execute f;
end;$patch$;

-- Notifications and self-requested copies identify the actual contract kind.
do $patch$
declare f text;anchor text;
begin
 f:=pg_get_functiondef('public.multi_mcnda_delivery_context(uuid,uuid)'::regprocedure);
 anchor:=$a$'attachment_filename','Nexora-MCNDA-'||v.id||'-revision-'||v.revision||'-signed.pdf'$a$;
 if position(anchor in f)=0 then raise exception 'Unexpected shared signing mail context';end if;
 f:=replace(f,anchor,$a$'document_name',coalesce(v.snapshot->'document'->>'kind','MCNDA'),'attachment_filename','Nexora-'||coalesce(v.snapshot->'document'->>'kind','MCNDA')||'-'||v.id||'-revision-'||v.revision||'-signed.pdf'$a$);
 execute f;
end;$patch$;

-- Derive the OTP email's contract name from the frozen server snapshot.
do $patch$
declare f text;anchor text;
begin
 f:=pg_get_functiondef('public.issue_multi_mcnda_confirmation(uuid,uuid,uuid,text,text,integer,uuid)'::regprocedure);
 anchor:=$a$return jsonb_build_object('email',m.email,'language',$a$;
 if position(anchor in f)=0 then raise exception 'Unexpected signing confirmation context';end if;
 f:=replace(f,anchor,$a$return jsonb_build_object('document_name',coalesce(v.snapshot->'document'->>'kind','MCNDA'),'email',m.email,'language',$a$);
 execute f;
end;$patch$;
notify pgrst,'reload schema';
commit;
