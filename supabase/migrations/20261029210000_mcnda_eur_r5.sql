-- Change only the default template identifier for newly prepared MCNDAs.
-- Existing snapshots, PDFs, signatures and access rules are unchanged.
do $migration$
declare definition text;
begin
 select pg_get_functiondef('portal_private.mcnda_snapshot_representatives(jsonb,uuid,text,jsonb)'::regprocedure) into definition;
 if position('NEX-MCNDA-ICC-PARIS-EUR-20261029-R5' in definition)>0 then return;end if;
 if position('NEX-MCNDA-ICC-PARIS-REPS-20261029-R4' in definition)=0 then raise exception 'Unexpected MCNDA default version';end if;
 execute replace(definition,'NEX-MCNDA-ICC-PARIS-REPS-20261029-R4','NEX-MCNDA-ICC-PARIS-EUR-20261029-R5');
end;$migration$;
select position('NEX-MCNDA-ICC-PARIS-EUR-20261029-R5' in pg_get_functiondef('portal_private.mcnda_snapshot_representatives(jsonb,uuid,text,jsonb)'::regprocedure))>0 as r5_default_active;
