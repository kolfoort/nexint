begin;
do $patch$ declare f text;old text;new text;begin
 f:=pg_get_functiondef('public.multi_mcnda_action(text,uuid,integer,jsonb)'::regprocedure);
 old:=$old$ if p_action='pdf' then$old$;
 new:=$new$ if p_action='pdf' then
 if p_payload->>'delivery'='download' then
  if p_payload->>'artifact'='final' and (v.status<>'completed' or v.final_pdf is null) then raise exception 'Final bundle unavailable';end if;
  perform portal_private.multi_mcnda_log(v.id,'document_download_requested',jsonb_build_object('artifact',case when p_payload->>'artifact'='final' then 'final' else 'content' end,'pdf_sha256',case when p_payload->>'artifact'='final' then v.final_hash else v.content_hash end,'meaning','Authorised download requested; browser save completion is not independently confirmed'));
 end if;$new$;
 if position(old in f)=0 then raise exception 'Unexpected MCNDA function';end if;
 execute replace(f,old,new);
end;$patch$;
notify pgrst,'reload schema';commit;
