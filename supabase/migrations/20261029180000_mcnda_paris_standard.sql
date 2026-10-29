begin;
do $patch$
declare definition text; old_template constant text := 'NEX-MCNDA-ICC-MULTI-20261029-R2'; new_template constant text := 'NEX-MCNDA-ICC-PARIS-20261029-R3'; anchor constant text := 'if p_action=''prepare'' then return snap;end if;';
begin
 select pg_get_functiondef('portal_private.multi_mcnda_snapshot(jsonb,uuid,text)'::regprocedure) into definition;
 if position(old_template in definition)=0 then raise exception 'Unexpected snapshot template'; end if;
 execute replace(definition,old_template,new_template);
 select pg_get_functiondef('public.multi_mcnda_action(text,uuid,integer,jsonb)'::regprocedure) into definition;
 if position(anchor in definition)=0 then raise exception 'Unexpected create action';end if;
 execute replace(definition,anchor,anchor||E'\n if p_payload->>''template_version'' is distinct from snap->>''template'' then raise exception ''MCNDA standard changed. Reload this page before preparing a new agreement.'';end if;');
end $patch$;
commit;
