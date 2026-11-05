-- Uploaded execution copies use Nexora's user-confirmed legal identity.
-- Legacy standard MCNDAs and every existing immutable snapshot remain untouched.
begin;
do $patch$
declare f text;anchor text;
begin
 f:=pg_get_functiondef('portal_private.uploaded_contract_snapshot(jsonb,uuid)'::regprocedure);
 anchor:=$a$return snap||jsonb_build_object('template','NEX-UPLOADED-CONTRACT-20261105-R1','document',doc);$a$;
 if position(anchor in f)=0 then raise exception 'Unexpected uploaded contract snapshot';end if;
 f:=replace(f,anchor,$a$
 snap:=jsonb_set(snap,'{parties}',(
  select jsonb_agg(case when (party->>'is_nexora')::boolean then party||jsonb_build_object(
   'legal_name','Nexora International B.V.',
   'registration','KvK 84285699',
   'address','Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands',
   'business_address','Herengracht 208, 1016 BS Amsterdam, The Netherlands'
  ) else party end order by ordinal)
  from jsonb_array_elements(snap->'parties') with ordinality as parties(party,ordinal)
 ));
 return snap||jsonb_build_object('template','NEX-UPLOADED-CONTRACT-20261105-R1','document',doc);$a$);
 execute f;
end;$patch$;
notify pgrst,'reload schema';
commit;
