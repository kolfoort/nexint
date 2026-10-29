begin;
do $patch$ declare f text;begin
 f:=pg_get_functiondef('public.multi_mcnda_action(text,uuid,integer,jsonb)'::regprocedure);
 if position('organisation_asset_version text' in f)=0 then raise exception 'Organisation asset support required';end if;
 f:=replace(f,'not between 1 and 2000','not between 1 and (case when organisation_asset_version is not null then 4000 else 2000 end)');
 f:=replace(f,'not between 1 and 1000','not between 1 and (case when organisation_asset_version is not null then 4000 else 1000 end)');
 f:=replace(f,'length(stamp_png) not between 50 and 900000','length(stamp_png) not between 50 and (case when organisation_asset_version is not null then 1500000 else 900000 end)');
 execute f;
end;$patch$;
notify pgrst,'reload schema';commit;
