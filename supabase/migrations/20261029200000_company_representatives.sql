begin;
-- Additive relationships: personal profiles, broker links and previous agreements stay intact.
create table public.portal_company_representatives(
 company_id uuid not null references public.portal_companies(id),user_id uuid not null references public.portal_members(user_id),
 name text not null check(length(name) between 2 and 120),title text not null check(length(title) between 1 and 80),
 active boolean not null default true,can_edit boolean not null default false,authority_verified boolean not null default false,
 verification_note text not null default '' check(length(verification_note)<=2000),verified_by uuid references public.portal_members(user_id),verified_at timestamptz,
 version integer not null default 1,updated_at timestamptz not null default now(),primary key(company_id,user_id),
 check(not authority_verified or (verified_by is not null and verified_at is not null and length(trim(verification_note))>=8))
);
create table public.portal_company_signing_rules(
 company_id uuid primary key references public.portal_companies(id),version integer not null default 1,
 mode text not null default 'pending' check(mode in('pending','any','joint')),
 signers uuid[] not null default '{}',approved_by uuid references public.portal_members(user_id),approved_at timestamptz,
 proposed jsonb,updated_at timestamptz not null default now(),
 check(mode='pending' or (cardinality(signers)>0 and approved_by is not null and approved_at is not null))
);
alter table public.portal_company_representatives enable row level security;
alter table public.portal_company_signing_rules enable row level security;
revoke all on public.portal_company_representatives,public.portal_company_signing_rules from public,anon,authenticated;
-- No direct grants: scoped, MFA-checked RPCs provide the UI and every mutation is audited.
create function portal_private.company_rep_access(p_company uuid,p_edit boolean default false) returns boolean language sql stable security definer set search_path='' as $$
 select portal_private.is_active() and portal_private.session_mfa_allowed() and (portal_private.is_admin() or exists(select 1 from public.portal_company_representatives r join public.portal_companies c on c.id=r.company_id where r.company_id=p_company and r.user_id=auth.uid() and r.active and c.access_state='active' and (not p_edit or r.can_edit)) or (not p_edit and exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.company_id=p_company and m.user_id=auth.uid() and c.access_state='active')));
$$;
revoke all on function portal_private.company_rep_access(uuid,boolean) from public,anon,authenticated,service_role;
create function public.company_representation_context(p_company uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;admin boolean;
begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() then raise exception 'MFA_REQUIRED';end if;admin:=portal_private.is_admin();
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'details',c.details,'version',c.version,'status',c.status,'access_state',c.access_state,'can_edit',portal_private.company_rep_access(c.id,true),'rule',to_jsonb(s)-'proposed'||jsonb_build_object('proposed',s.proposed),'representatives',coalesce((select jsonb_agg((to_jsonb(r)-'verification_note')||jsonb_build_object('email',case when admin or r.user_id=auth.uid() then m.email else null end,'account_active',m.active) order by r.name) from public.portal_company_representatives r join public.portal_members m on m.user_id=r.user_id where r.company_id=c.id),'[]'::jsonb)) order by c.details->>'B_COMPANY'),'[]'::jsonb) into result
 from public.portal_companies c left join public.portal_company_signing_rules s on s.company_id=c.id where c.details->>'ACCOUNT_TYPE' is distinct from 'individual' and (p_company is null or c.id=p_company) and portal_private.company_rep_access(c.id,false);
 return jsonb_build_object('admin',admin,'companies',result,'accounts',case when admin then (select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',m.email,'active',m.active) order by m.email),'[]'::jsonb) from public.portal_members m where not m.is_admin) else '[]'::jsonb end);
end;$$;
revoke all on function public.company_representation_context(uuid) from public,anon;grant execute on function public.company_representation_context(uuid) to authenticated;
create function public.manage_company_representatives(p_action text,p_company uuid,p_expected_version integer,p_payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.portal_companies;s public.portal_company_signing_rules;r public.portal_company_representatives;uid uuid;ids uuid[];name text;title text;note text;verified boolean;v_active boolean;v_can_edit boolean;metadata jsonb;mode text;new_details jsonb;k text;v text;old jsonb;
begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() or not portal_private.company_rep_access(p_company,false) then raise exception 'Access denied';end if;
 if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>20000 then raise exception 'Invalid request';end if;
 select * into c from public.portal_companies where id=p_company for update;
 if c.id is null or c.details->>'ACCOUNT_TYPE'='individual' or c.access_state='archived' then raise exception 'Active company record required';end if;
 select * into s from public.portal_company_signing_rules where company_id=p_company for update;
 if coalesce(s.version,0) is distinct from p_expected_version then raise exception 'Representatives changed. Refresh and try again';end if;
 if p_action='propose' then
  if not portal_private.company_rep_access(p_company,true) then raise exception 'Profile editing permission required';end if;
  mode:=p_payload->>'mode';if mode not in('any','joint') or mode is null then raise exception 'Invalid signing rule';end if;
  select array_agg(distinct value::uuid) into ids from jsonb_array_elements_text(p_payload->'signers');
  if coalesce(cardinality(ids),0) not between 1 and 20 or exists(select 1 from unnest(ids) u where not exists(select 1 from public.portal_company_representatives x where x.company_id=p_company and x.user_id=u and x.active)) then raise exception 'Select linked active representatives';end if;
  metadata:=jsonb_build_object('mode',mode,'signers',ids,'proposed_by',auth.uid(),'proposed_at',now());
  insert into public.portal_company_signing_rules(company_id,proposed) values(p_company,metadata) on conflict(company_id) do update set proposed=excluded.proposed,version=public.portal_company_signing_rules.version+1,updated_at=now();
 elsif p_action='save_profile' then
  if not portal_private.company_rep_access(p_company,true) or c.access_state<>'active' then raise exception 'Profile editing permission required';end if;
  if (p_payload->>'company_version')::integer is distinct from c.version then raise exception 'Company profile changed. Refresh first';end if;
  new_details:=c.details;
  foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_PHONE','B_WHATSAPP','B_EMAIL','B_WEBSITE'] loop
   if jsonb_typeof(p_payload->'details'->k) is distinct from 'string' then raise exception 'Missing company detail';end if;v:=trim(p_payload->'details'->>k);
   if length(v)>(case k when 'B_ADDRESS' then 150 when 'B_COUNTRY' then 60 when 'B_REGISTRATION' then 60 when 'B_PHONE' then 50 when 'B_WHATSAPP' then 32 else 100 end) or (k not in('B_WHATSAPP','B_WEBSITE') and v='') then raise exception 'Complete required company fields';end if;
   if k='B_EMAIL' and v !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid company email';end if;
   if k='B_WHATSAPP' and v<>'' and v !~ '^\+[0-9 ()-]{5,31}$' then raise exception 'International WhatsApp number required';end if;
   new_details:=jsonb_set(new_details,array[k],to_jsonb(v));
  end loop;
  update public.portal_companies set details=new_details,version=version+1,status='pending',approved_by=null,approved_at=null,updated_at=now() where id=p_company;
  metadata:=jsonb_build_object('company_version',c.version+1,'personal_signing_identity_unchanged',true);
 else
  if not portal_private.is_admin() then raise exception 'Administrator required';end if;
  if p_action='representative' then
   uid:=(p_payload->>'user_id')::uuid;name:=trim(p_payload->>'name');title:=trim(p_payload->>'title');note:=trim(coalesce(p_payload->>'verification_note',''));verified:=coalesce((p_payload->>'authority_verified')::boolean,false);v_active:=coalesce((p_payload->>'active')::boolean,true);v_can_edit:=coalesce((p_payload->>'can_edit')::boolean,false);
   if coalesce(length(name),0) not between 2 and 120 or coalesce(length(title),0) not between 1 and 80 or length(note)>2000 or (verified and length(note)<8) then raise exception 'Enter name, title and the verification basis';end if;
   if not exists(select 1 from public.portal_members m join auth.users u on u.id=m.user_id where m.user_id=uid and not m.is_admin and (not v_active or (m.active and u.email_confirmed_at is not null and lower(u.email)=lower(m.email)))) then raise exception 'Select an active verified existing account';end if;
   select to_jsonb(x) into old from public.portal_company_representatives x where company_id=p_company and user_id=uid;
   insert into public.portal_company_representatives(company_id,user_id,name,title,active,can_edit,authority_verified,verification_note,verified_by,verified_at) values(p_company,uid,name,title,v_active,v_can_edit,verified,note,case when verified then auth.uid() end,case when verified then now() end)
   on conflict(company_id,user_id) do update set name=excluded.name,title=excluded.title,active=excluded.active,can_edit=excluded.can_edit,authority_verified=excluded.authority_verified,verification_note=excluded.verification_note,verified_by=excluded.verified_by,verified_at=excluded.verified_at,version=public.portal_company_representatives.version+1,updated_at=now();
   -- Invalidate authority on every role edit; explicit confirmation is required again.
   insert into public.portal_company_signing_rules(company_id) values(p_company) on conflict(company_id) do update set mode='pending',signers='{}',approved_by=null,approved_at=null,version=public.portal_company_signing_rules.version+1,updated_at=now();
   metadata:=jsonb_build_object('user_id',uid,'before',old-'verification_note','after',jsonb_build_object('name',name,'title',title,'active',v_active,'can_edit',v_can_edit,'authority_verified',verified),'verification_basis_recorded',verified);
  elsif p_action='approve_rule' then
   mode:=p_payload->>'mode';note:=trim(p_payload->>'verification_note');if mode not in('any','joint') or mode is null or coalesce(length(note),0) not between 8 and 2000 then raise exception 'Select signing authority and record verification basis';end if;
   select array_agg(distinct value::uuid) into ids from jsonb_array_elements_text(p_payload->'signers');
   if coalesce(cardinality(ids),0) not between 1 and 20 or exists(select 1 from unnest(ids) u where not exists(select 1 from public.portal_company_representatives x join public.portal_members m on m.user_id=x.user_id where x.company_id=p_company and x.user_id=u and x.active and x.authority_verified and m.active)) then raise exception 'Select verified active representatives';end if;
   insert into public.portal_company_signing_rules(company_id,mode,signers,approved_by,approved_at) values(p_company,mode,ids,auth.uid(),now()) on conflict(company_id) do update set mode=excluded.mode,signers=excluded.signers,approved_by=auth.uid(),approved_at=now(),proposed=null,version=public.portal_company_signing_rules.version+1,updated_at=now();
   metadata:=jsonb_build_object('before',to_jsonb(s)-'proposed','mode',mode,'signers',ids,'verification_note',note);
  else raise exception 'Unknown action';end if;
 end if;
 insert into public.portal_company_events(company_id,actor_id,event,metadata) values(p_company,auth.uid(),'representatives_'||p_action,metadata);
 return jsonb_build_object('saved',true);
end;$$;
revoke all on function public.manage_company_representatives(text,uuid,integer,jsonb) from public,anon;grant execute on function public.manage_company_representatives(text,uuid,integer,jsonb) to authenticated;
create function portal_private.mcnda_snapshot_representatives(p_users jsonb,p_owner uuid,p_owner_name text,p_representations jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;u uuid;cid uuid;c public.portal_companies;r public.portal_company_representatives;s public.portal_company_signing_rules;part jsonb;legacy jsonb;i integer:=1;seen uuid[]:='{}';email text;owner_email text;
begin
 if jsonb_typeof(p_users) is distinct from 'array' or jsonb_array_length(p_users) not between 1 and 20 or coalesce(length(trim(p_owner_name)),0) not between 2 and 120 or jsonb_typeof(coalesce(p_representations,'{}')) is distinct from 'object' then raise exception 'Select 1–20 signatories';end if;
 select m.email into owner_email from public.portal_members m where m.user_id=p_owner and m.active and m.is_admin;if owner_email is null then raise exception 'Administrator required';end if;
 result:=jsonb_build_array(jsonb_build_object('user_id',p_owner,'is_nexora',true,'position',0,'account_email',owner_email,'kind','company','legal_name','La Clava Elit BV, trading as Nexora International','name',trim(p_owner_name),'capacity','Authorised Nexora representative','address','Herengracht 208, 1016 BS Amsterdam','country','The Netherlands','registration','La Clava Elit BV','whatsapp',''));
 for u in select value::uuid from jsonb_array_elements_text(p_users) loop
  if u=p_owner or u=any(seen) then raise exception 'Each account may sign only once per agreement';end if;seen:=array_append(seen,u);
  cid:=nullif(p_representations->>u::text,'')::uuid;
  if cid is null then
   if exists(select 1 from public.portal_company_members m join public.portal_company_signing_rules q on q.company_id=m.company_id where m.user_id=u) then raise exception 'Choose the verified company-representative role for this account';end if;
   legacy:=portal_private.multi_mcnda_snapshot(jsonb_build_array(u),p_owner,p_owner_name);part:=legacy->'parties'->1;
  else
   select * into c from public.portal_companies where id=cid for share;
   select * into s from public.portal_company_signing_rules where company_id=cid for share;
   select * into r from public.portal_company_representatives where company_id=cid and user_id=u for share;
   select m.email into email from public.portal_members m join auth.users a on a.id=m.user_id where m.user_id=u and m.active and not m.is_admin and a.email_confirmed_at is not null and lower(a.email)=lower(m.email);
   if c.id is null or c.details->>'ACCOUNT_TYPE'='individual' or c.access_state<>'active' or c.status<>'approved' or r.user_id is null or not r.active or not r.authority_verified or s.mode is null or s.mode='pending' or not u=any(s.signers) or email is null then raise exception 'Approved company profile and verified signing authority required';end if;
   if s.mode='joint' and exists(select 1 from unnest(s.signers) x where not (p_users @> jsonb_build_array(x)) or p_representations->>x::text is distinct from cid::text) then raise exception 'Joint authority requires every designated representative of the company';end if;
   if exists(select 1 from unnest(s.signers) x where not exists(select 1 from public.portal_company_representatives a join public.portal_members m on m.user_id=a.user_id where a.company_id=cid and a.user_id=x and a.active and a.authority_verified and m.active)) then raise exception 'Signing authority must be reviewed';end if;
   part:=jsonb_build_object('user_id',u,'is_nexora',false,'company_id',cid,'company_version',c.version,'account_email',email,'kind','company','legal_party_id',cid,'legal_name',c.details->>'B_COMPANY','name',r.name,'capacity',r.title,'address',c.details->>'B_ADDRESS','country',c.details->>'B_COUNTRY','registration',c.details->>'B_REGISTRATION','whatsapp',coalesce(c.details->>'B_WHATSAPP',''),'representative_version',r.version,'authority_version',s.version,'authority_mode',s.mode,'required_signers',s.signers);
  end if;
  result:=result||jsonb_build_array(part||jsonb_build_object('position',i));i:=i+1;
 end loop;
 if exists(select 1 from jsonb_array_elements(result) p where p->>'kind'='company' and p->>'company_id' is not null group by p->>'company_id' having count(*)>1 and bool_or(not (p ? 'representative_version'))) then raise exception 'Configure company representatives and signing authority before selecting multiple accounts for one company';end if;
 return jsonb_build_object('template','NEX-MCNDA-ICC-PARIS-REPS-20261029-R4','parties',result);
end;$$;
revoke all on function portal_private.mcnda_snapshot_representatives(jsonb,uuid,text,jsonb) from public,anon,authenticated,service_role;
create function portal_private.mcnda_representatives_current(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.portal_mcnda_parties p where p.version_id=p_id and p.snapshot ? 'representative_version' and not exists(select 1 from public.portal_company_representatives r join public.portal_company_signing_rules s on s.company_id=r.company_id join public.portal_companies c on c.id=r.company_id join public.portal_members m on m.user_id=r.user_id where r.company_id=p.company_id and r.user_id=p.user_id and r.active and r.authority_verified and r.version=(p.snapshot->>'representative_version')::integer and s.version=(p.snapshot->>'authority_version')::integer and s.mode in('any','joint') and r.user_id=any(s.signers) and c.access_state='active' and c.version=p.company_version and m.active));
$$;
revoke all on function portal_private.mcnda_representatives_current(uuid) from public,anon,authenticated,service_role;
-- Guard in the single existing action, preserving saved-image, network, OTP and audit logic.
do $patch$
declare f text;anchor text;
begin
 f:=pg_get_functiondef('public.multi_mcnda_action(text,uuid,integer,jsonb)'::regprocedure);
 anchor:=$a$portal_private.multi_mcnda_snapshot(p_payload->'users',auth.uid(),p_payload->>'owner_name')$a$;
 if position(anchor in f)=0 then raise exception 'Snapshot action changed';end if;
 f:=replace(f,anchor,$a$portal_private.mcnda_snapshot_representatives(p_payload->'users',auth.uid(),p_payload->>'owner_name',coalesce(p_payload->'representations','{}'::jsonb))$a$);
 anchor:=$a$if p_action='pdf' then$a$;
 if position(anchor in f)=0 then raise exception 'Action guard changed';end if;
 f:=replace(f,anchor,$a$if p_action in('release','share_draft','review','sign') then
 perform 1 from public.portal_companies c join public.portal_mcnda_parties p on p.company_id=c.id where p.version_id=v.id order by c.id for share of c;
 perform 1 from public.portal_company_representatives r join public.portal_mcnda_parties p on p.company_id=r.company_id and p.user_id=r.user_id where p.version_id=v.id order by r.company_id,r.user_id for share of r;
 perform 1 from public.portal_company_signing_rules s where s.company_id in(select p.company_id from public.portal_mcnda_parties p where p.version_id=v.id) order by s.company_id for share;
 end if;
 if p_action in('release','share_draft','review','sign') and not portal_private.mcnda_representatives_current(v.id) then raise exception 'Company representation or signing authority changed; create a new revision';end if;
 if p_action='pdf' then$a$);
 execute f;
end $patch$;
-- Preserve the existing implementation and function identity, adding a scoped edit guard.
do $guard$
declare f text;anchor text:=E'\nbegin\n';
begin
 f:=pg_get_functiondef('portal_private.save_company_details(jsonb,integer)'::regprocedure);
 if position(anchor in f)=0 then raise exception 'Profile save definition changed';end if;
 f:=replace(f,anchor,anchor||$injected$
 perform 1 from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() for update of c;
 if exists(select 1 from public.portal_company_members m join public.portal_company_signing_rules s on s.company_id=m.company_id where m.user_id=auth.uid() and not portal_private.company_rep_access(m.company_id,true)) then raise exception 'Company profile editing permission required';end if;
 $injected$);
 execute f;
end $guard$;
notify pgrst,'reload schema';
commit;
