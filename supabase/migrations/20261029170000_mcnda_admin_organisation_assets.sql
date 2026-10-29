begin;
do $patch$ declare f text;old text;new text;begin
 f:=pg_get_functiondef('public.multi_mcnda_action(text,uuid,integer,jsonb)'::regprocedure);
 f:=replace(f,'network_id uuid;','network_id uuid;organisation_asset_version text;');
 old:=$old$  select * into assets from public.portal_signing_profiles where user_id=auth.uid() for share;
  if not found or p_payload->>'asset_version' is distinct from assets.version::text then raise exception 'Saved signing images changed; refresh and review again';end if;$old$;
 new:=$new$  if me.is_nexora and is_admin then
   if regexp_replace(lower(me.snapshot->>'name'),'[^a-z]','','g') not in('jpkolfoort','janpeterkolfoort') then raise exception 'The configured Nexora signature belongs to J.P. Kolfoort; a different signatory requires their own signing assets';end if;
   select png_base64 into assets.signature from public.commission_assets where name='signature' for share;
   select png_base64 into assets.stamp from public.commission_assets where name='stamp' for share;
   if assets.signature is null or assets.stamp is null then raise exception 'Nexora signing assets unavailable';end if;
   if assets.signature not like 'data:image/png;base64,%' then assets.signature:='data:image/png;base64,'||assets.signature;end if;
   if assets.stamp not like 'data:image/png;base64,%' then assets.stamp:='data:image/png;base64,'||assets.stamp;end if;
   organisation_asset_version:='nexora:'||encode(sha256(convert_to(assets.signature||':'||assets.stamp,'UTF8')),'hex');
   if p_payload->>'asset_version' is distinct from organisation_asset_version then raise exception 'Nexora signing images changed; refresh and review again';end if;
  else
   select * into assets from public.portal_signing_profiles where user_id=auth.uid() for share;
   if not found or p_payload->>'asset_version' is distinct from assets.version::text then raise exception 'Saved signing images changed; refresh and review again';end if;
  end if;$new$;
 if position(old in f)=0 then raise exception 'Unexpected signing function; migration stopped';end if;
 f:=replace(f,old,new);
 f:=replace(f,$old$'saved_asset_version',assets.version$old$,$new$'saved_asset_version',coalesce(organisation_asset_version,assets.version::text),'asset_origin',case when organisation_asset_version is not null then 'Nexora organisation signing assets' else 'account signing profile' end$new$);
 execute f;
end;$patch$;
notify pgrst,'reload schema';commit;
