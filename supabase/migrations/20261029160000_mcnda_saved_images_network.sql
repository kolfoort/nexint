begin;
alter table public.portal_mcnda_signatures add column stamp_png text;
revoke select(stamp_png) on public.portal_mcnda_signatures from public,anon,authenticated;
create table portal_private.mcnda_network_evidence(id uuid primary key default gen_random_uuid(),version_id uuid not null references public.portal_mcnda_versions(id),user_id uuid not null,confirmation_id uuid not null,at timestamptz not null default clock_timestamp(),reported_ip inet,user_agent text,source text not null,assurance text not null);
alter table portal_private.mcnda_network_evidence enable row level security;
revoke all on portal_private.mcnda_network_evidence from public,anon,authenticated,service_role;
create trigger mcnda_network_immutable before update or delete on portal_private.mcnda_network_evidence for each row execute function portal_private.multi_mcnda_unchangeable();
create function portal_private.capture_mcnda_network(p_version uuid,p_confirmation uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare headers jsonb;ip inet;raw text;result uuid;
begin
 headers:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
 raw:=headers->>'cf-connecting-ip';
 begin if length(raw)<=45 then ip:=raw::inet;end if;exception when invalid_text_representation then ip:=null;end;
 insert into portal_private.mcnda_network_evidence(version_id,user_id,confirmation_id,reported_ip,user_agent,source,assurance) values(p_version,auth.uid(),p_confirmation,ip,left(headers->>'user-agent',500),case when ip is null then 'unavailable' else 'request gateway cf-connecting-ip header' end,'Supporting proxy-reported network context; not independent proof of identity or location; VPN/proxy use possible') returning id into result;
 return result;
end;$$;
revoke all on function portal_private.capture_mcnda_network(uuid,uuid) from public,anon,authenticated,service_role;
create function public.multi_mcnda_network_evidence(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() or not portal_private.multi_mcnda_visible(p_id) then raise exception 'Access denied';end if;
 select coalesce(jsonb_agg(to_jsonb(e) order by at),'[]') into result from portal_private.mcnda_network_evidence e where e.version_id=p_id and (portal_private.is_admin() or e.user_id=auth.uid());
 perform portal_private.multi_mcnda_log(p_id,'protected_network_evidence_accessed',jsonb_build_object('scope',case when portal_private.is_admin() then 'administrator' else 'own account only' end));
 return result;
end;$$;
revoke all on function public.multi_mcnda_network_evidence(uuid) from public,anon;grant execute on function public.multi_mcnda_network_evidence(uuid) to authenticated;
create or replace function public.multi_mcnda_action(p_action text,p_id uuid default null,p_expected_revision integer default null,p_payload jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.portal_mcnda_versions;oldv public.portal_mcnda_versions;thread uuid;num integer;content bytea;snap jsonb;part jsonb;me public.portal_mcnda_parties;proof jsonb;c portal_private.signing_confirmations;sig bytea;rec jsonb;h text;tok uuid;title text;is_admin boolean;assets public.portal_signing_profiles;stamp_png text;asset_source text;network_id uuid;
begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() then raise exception 'MFA_REQUIRED';end if;if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>23000000 then raise exception 'Invalid request';end if;is_admin:=portal_private.is_admin();
 if p_action in ('prepare','create') then
 if not is_admin then raise exception 'Administrator required';end if;
 snap:=portal_private.multi_mcnda_snapshot(p_payload->'users',auth.uid(),p_payload->>'owner_name')||jsonb_build_object('scope',left(coalesce(p_payload->>'scope',''),1200));
 for part in select value from jsonb_array_elements(snap->'parties') loop
 if coalesce(p_payload->'notice_numbers'->>(part->>'user_id'),'')<>'' and p_payload->'notice_numbers'->>(part->>'user_id') !~ '^[+0-9 ()-]{6,32}$' then raise exception 'Invalid designated WhatsApp number';end if;end loop;
 snap:=jsonb_set(snap,'{parties}',(select jsonb_agg(value||jsonb_build_object('whatsapp',coalesce(p_payload->'notice_numbers'->>(value->>'user_id'),value->>'whatsapp','')) order by ord) from jsonb_array_elements(snap->'parties') with ordinality as a(value,ord)));
 if p_action='prepare' then return snap;end if;
 if p_payload->'snapshot' is distinct from snap then raise exception 'Profile changed; prepare and review a new PDF';end if;
 title:=trim(p_payload->>'title');if length(coalesce(title,'')) not between 1 and 180 then raise exception 'Document title required';end if;
 if length(coalesce(p_payload->>'pdf','')) not between 500 and 20000000 then raise exception 'Complete PDF required';end if;
 content:=decode(p_payload->>'pdf','base64');if substring(content from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;
 if p_id is null then insert into public.portal_mcnda_threads(title,owner_id) values(title,auth.uid()) returning id into thread;num:=1;
 else
 select id into thread from public.portal_mcnda_threads where id=p_id for update;if not found then raise exception 'Agreement unavailable';end if;
 select * into oldv from public.portal_mcnda_versions where thread_id=thread order by revision desc limit 1 for update;
 if oldv.revision is distinct from p_expected_revision then raise exception 'Version changed';end if;num:=oldv.revision+1;
 if oldv.status not in ('completed','cancelled','superseded') then
 update public.portal_mcnda_versions set status='superseded' where id=oldv.id;
 update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null where purpose='mcnda_multi' and document_id=oldv.id and consumed_at is null;
 perform portal_private.multi_mcnda_log(oldv.id,'revision_superseded',jsonb_build_object('replacement_revision',num,'prior_signatures_preserved',true));
 if oldv.shared_at is not null then perform portal_private.multi_mcnda_queue(oldv.id,'withdrawn');end if;
 end if;
 end if;
 insert into public.portal_mcnda_versions(thread_id,revision,template_version,content_pdf,content_hash,snapshot,created_by) values(thread,num,snap->>'template',p_payload->>'pdf',encode(sha256(content),'hex'),snap,auth.uid()) returning * into v;
 for part in select value from jsonb_array_elements(snap->'parties') loop
 insert into public.portal_mcnda_parties(version_id,user_id,position,company_id,company_version,snapshot,is_nexora) values(v.id,(part->>'user_id')::uuid,(part->>'position')::integer,(part->>'company_id')::uuid,(part->>'company_version')::integer,part,(part->>'is_nexora')::boolean);
 end loop;
 perform portal_private.multi_mcnda_log(v.id,'revision_created',jsonb_build_object('content_hash',v.content_hash,'template',v.template_version,'snapshot_hash',encode(sha256(convert_to(snap::text,'UTF8')),'hex'),'prior_completed_agreements_unaffected',true));return jsonb_build_object('id',v.id,'thread_id',thread,'revision',num);
 end if;
 select thread_id into thread from public.portal_mcnda_versions where id=p_id;perform 1 from public.portal_mcnda_threads where id=thread for update;
 select * into v from public.portal_mcnda_versions where id=p_id for update;if not found or v.revision is distinct from p_expected_revision or not portal_private.multi_mcnda_visible(v.id) then raise exception 'Current accessible agreement required';end if;
 if p_action='pdf' then
 perform portal_private.multi_mcnda_log(v.id,'document_accessed',jsonb_build_object('content_hash',v.content_hash,'artifact',case when p_payload->>'artifact'='final' then 'final' else 'content' end));
 if p_payload->>'artifact'='final' then if v.final_pdf is null then raise exception 'Final bundle unavailable';end if;return jsonb_build_object('pdf',v.final_pdf,'hash',v.final_hash);end if;
 return jsonb_build_object('pdf',v.content_pdf,'hash',v.content_hash);
 elsif p_action in ('release','share_draft') then
 if not is_admin or v.status not in('draft','draft_review') or p_payload->>'reviewed_hash' is distinct from v.content_hash or p_payload->>'authority_reviewed' is distinct from 'true' then raise exception 'Review the exact PDF, all party identities and authority first';end if;
 for me in select * from public.portal_mcnda_parties where version_id=v.id and not is_nexora loop
 if not exists(select 1 from public.portal_companies where id=me.company_id and version=me.company_version and access_state='active') or not exists(select 1 from public.portal_members where user_id=me.user_id and active) then raise exception 'Counterparty profile changed or access unavailable; create a new revision';end if;
 end loop;
 if p_action='share_draft' then
 update public.portal_mcnda_versions set status='draft_review',shared_at=coalesce(shared_at,now()) where id=v.id;perform portal_private.multi_mcnda_log(v.id,'draft_shared',jsonb_build_object('content_hash',v.content_hash,'authority_reviewed',true));perform portal_private.multi_mcnda_queue(v.id,'draft_review');return jsonb_build_object('shared',true);end if;
 update public.portal_mcnda_versions set status='released',released_at=now(),shared_at=coalesce(shared_at,now()) where id=v.id;
 perform portal_private.multi_mcnda_log(v.id,'released_for_signature',jsonb_build_object('content_hash',v.content_hash,'authority_reviewed',true,'reviewer',auth.uid()));perform portal_private.multi_mcnda_queue(v.id,'released');return jsonb_build_object('released',true);
 elsif p_action='review' then
 if v.status<>'released' or p_payload->>'reviewed_hash' is distinct from v.content_hash or p_payload->>'accept_review' is distinct from 'true' then raise exception 'Review the complete current PDF first';end if;
 if not exists(select 1 from public.portal_mcnda_events where version_id=v.id and actor=auth.uid() and event='document_accessed' and payload->>'content_hash'=v.content_hash and at>now()-interval '24 hours') then raise exception 'Open the complete PDF first';end if;
 select * into me from public.portal_mcnda_parties where version_id=v.id and user_id=auth.uid();if not found then raise exception 'Assigned signatory required';end if;
 insert into portal_private.multi_mcnda_reviews(version_id,user_id,content_hash) values(v.id,auth.uid(),v.content_hash) returning token into tok;
 perform portal_private.multi_mcnda_log(v.id,'review_attested',jsonb_build_object('content_hash',v.content_hash,'attestation','Full English PDF and party schedule reviewed; this records an assertion, not proof of actual reading'));return jsonb_build_object('review_token',tok);
 elsif p_action='sign' then
 if v.status<>'released' or p_payload->>'accept' is distinct from 'true' then raise exception 'Explicit current agreement acceptance required';end if;
 select * into me from public.portal_mcnda_parties where version_id=v.id and user_id=auth.uid();if not found or exists(select 1 from public.portal_mcnda_signatures where version_id=v.id and user_id=auth.uid()) then raise exception 'Unsigned assigned party required';end if;
 if me.is_nexora then
 if not portal_private.multi_mcnda_parties_current(v.id) then raise exception 'A counterparty profile changed or access was paused; review and revise before final approval';end if;
 if not is_admin or exists(select 1 from public.portal_mcnda_parties p where p.version_id=v.id and not p.is_nexora and not exists(select 1 from public.portal_mcnda_signatures s where s.version_id=p.version_id and s.user_id=p.user_id)) then raise exception 'All counterparties must sign before Nexora';end if;
 else
 if not exists(select 1 from public.portal_companies where id=me.company_id and version=me.company_version and access_state='active') then raise exception 'Profile changed; request a revised agreement';end if;
 if me.snapshot->>'kind'='individual' and not exists(select 1 from portal_private.individual_identity i join public.portal_access_requests r on r.id=i.request_id join storage.objects o on o.bucket_id='nexora-private-identity' and o.name=i.copy_path where r.invited_user_id=auth.uid() and length(i.passport_number)>0) then raise exception 'Complete your protected identity record and upload the signed passport copy before signing';end if;
 end if;
 if p_payload->>'name' is distinct from me.snapshot->>'name' or p_payload->>'capacity_confirmed' is distinct from 'true' then raise exception 'Confirm the exact signatory name and capacity';end if;
 asset_source:=coalesce(p_payload->>'signature_source','drawn');
 if asset_source not in('drawn','saved') then raise exception 'Invalid signature source';end if;
 if asset_source='saved' or p_payload->>'use_saved_stamp'='true' then
  if p_payload->>'authorise_saved_images' is distinct from 'true' then raise exception 'Explicit image authorisation required';end if;
  select * into assets from public.portal_signing_profiles where user_id=auth.uid() for share;
  if not found or p_payload->>'asset_version' is distinct from assets.version::text then raise exception 'Saved signing images changed; refresh and review again';end if;
  if asset_source='saved' then
   if assets.signature not like 'data:image/png;base64,%' then raise exception 'Saved signature unavailable';end if;
   p_payload:=jsonb_set(p_payload,'{signature_png}',to_jsonb(substring(assets.signature from 23)));
  end if;
  if p_payload->>'use_saved_stamp'='true' then
   if me.snapshot->>'kind'='individual' or assets.stamp is null or assets.stamp not like 'data:image/png;base64,%' then raise exception 'Company stamp unavailable for this signatory';end if;
   stamp_png:=substring(assets.stamp from 23);
   if length(stamp_png) not between 50 and 900000 or substring(decode(stamp_png,'base64') from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'Invalid stored stamp';end if;
   sig:=decode(stamp_png,'base64');
   if octet_length(sig)<24 or (get_byte(sig,16)::bigint*16777216+get_byte(sig,17)*65536+get_byte(sig,18)*256+get_byte(sig,19)) not between 1 and 2000 or (get_byte(sig,20)::bigint*16777216+get_byte(sig,21)*65536+get_byte(sig,22)*256+get_byte(sig,23)) not between 1 and 1000 then raise exception 'Invalid stamp image dimensions';end if;
  end if;
 end if;
 if length(coalesce(p_payload->>'signature_png','')) not between 100 and 900000 then raise exception 'Signature image required';end if;sig:=decode(p_payload->>'signature_png','base64');if substring(sig from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'PNG signature required';end if;
 if octet_length(sig)<24 or (get_byte(sig,16)::bigint*16777216+get_byte(sig,17)*65536+get_byte(sig,18)*256+get_byte(sig,19)) not between 1 and 2000 or (get_byte(sig,20)::bigint*16777216+get_byte(sig,21)*65536+get_byte(sig,22)*256+get_byte(sig,23)) not between 1 and 1000 then raise exception 'Invalid signature image dimensions';end if;
 select * into c from portal_private.signing_confirmations where id=(p_payload->>'confirmation_id')::uuid and user_id=auth.uid() for update;
 if not found or c.document_revision is distinct from v.revision or c.review_token is distinct from (p_payload->>'review_token')::uuid then raise exception 'Confirm this reviewed version again';end if;
 proof:=portal_private.consume_signing_confirmation(c.id,(p_payload->>'confirmation_token')::uuid,'mcnda_multi',v.id,v.content_hash,v.revision);
 rec:=jsonb_build_object('account_id',auth.uid(),'account_email',proof->>'account_email','signer_name',me.snapshot->>'name','legal_party',me.snapshot->>'legal_name','capacity',me.snapshot->>'capacity','content_hash',v.content_hash,'signature_image_hash',encode(sha256(sig),'hex'),'accepted_at',now(),'acceptance','Explicit acceptance of the full English agreement and schedule in the recorded capacity','email_confirmation',proof,'method',asset_source||' signature and explicit acceptance with document-bound registered-email code','qualified_signature',false);
 network_id:=portal_private.capture_mcnda_network(v.id,c.id);
 rec:=rec||jsonb_build_object('signature_source',asset_source,'saved_asset_version',assets.version,'saved_images_authorised',asset_source='saved' or stamp_png is not null,'stamp_included',stamp_png is not null,'stamp_image_hash',case when stamp_png is not null then encode(sha256(decode(stamp_png,'base64')),'hex') end,'network_evidence_id',network_id);
 h:=encode(sha256(convert_to(rec::text,'UTF8')),'hex');
 insert into public.portal_mcnda_signatures(version_id,user_id,signer_name,capacity,signature_png,stamp_png,content_hash,email_confirmation,attestation,record_hash) values(v.id,auth.uid(),me.snapshot->>'name',me.snapshot->>'capacity',p_payload->>'signature_png',stamp_png,v.content_hash,proof,rec,h);
 perform portal_private.multi_mcnda_log(v.id,'signature_recorded',rec||jsonb_build_object('record_hash',h));
 if me.is_nexora then update public.portal_mcnda_versions set status='awaiting_bundle' where id=v.id;perform portal_private.multi_mcnda_log(v.id,'all_signatures_recorded',jsonb_build_object('content_hash',v.content_hash));
 else perform portal_private.multi_mcnda_queue(v.id,'client_signed');end if;
 return jsonb_build_object('signed',true,'needs_bundle',me.is_nexora);
 elsif p_action='cancel' then
 if not is_admin or v.status not in ('draft','draft_review','released') then raise exception 'Only an unsigned/in-progress revision can be cancelled';end if;
 update public.portal_mcnda_versions set status='cancelled' where id=v.id;update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null where purpose='mcnda_multi' and document_id=v.id and consumed_at is null;
 perform portal_private.multi_mcnda_log(v.id,'revision_cancelled',jsonb_build_object('reason',left(coalesce(p_payload->>'reason',''),500),'evidence_preserved',true));if v.shared_at is not null then perform portal_private.multi_mcnda_queue(v.id,'cancelled');end if;return jsonb_build_object('cancelled',true);
 end if;raise exception 'Unsupported MCNDA action';
end;$$;


do $patch$ declare f text;begin
 f:=pg_get_functiondef('public.multi_mcnda_export(uuid)'::regprocedure);
 if position($old$to_jsonb(s)-'signature_png'$old$ in f)=0 then raise exception 'Unexpected export function';end if;
 execute replace(f,$old$to_jsonb(s)-'signature_png'$old$,$new$to_jsonb(s)-'signature_png'-'stamp_png'$new$);
end;$patch$;
notify pgrst,'reload schema';commit;
