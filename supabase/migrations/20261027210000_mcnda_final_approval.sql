begin;
create table public.portal_mcnda_approvals(id uuid primary key references public.portal_mcnda_assignments(id),recipient uuid not null references public.portal_members(user_id),submission_id uuid not null references public.portal_submissions(id),status text not null default 'awaiting_approval' check(status in('awaiting_approval','completed')),revision integer not null default 1,client_pdf text not null,client_hash text not null,final_pdf text,final_hash text,approval_token uuid,approval_by uuid,approval_at timestamptz,created_at timestamptz not null default now());
alter table public.portal_mcnda_approvals enable row level security;
revoke all on public.portal_mcnda_approvals from public,anon,authenticated;
grant select on public.portal_mcnda_approvals to authenticated;
create policy mcnda_approval_read on public.portal_mcnda_approvals for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or recipient=(select auth.uid())));
alter table public.portal_mcnda_approvals add column client_attestation jsonb not null default '{}'::jsonb, add column company_snapshot jsonb not null default '{}'::jsonb;
create function public.submit_mcnda_for_approval(p_id uuid,p_details jsonb,p_expected_version integer,p_note text,p_pdf text,p_attestation jsonb) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare company public.portal_companies;request public.portal_mcnda_assignments;bytes bytea;hash text;sv uuid;
begin
 if not portal_private.is_active() or portal_private.is_admin() then raise exception 'Active client account required';end if;
 select * into request from public.portal_mcnda_assignments where user_id=auth.uid() and status='assigned' for update;
 if not found then raise exception 'MCNDA assignment required';end if;
 if length(coalesce(p_pdf,'')) not between 100 and 20000000 then raise exception 'Client-signed PDF required';end if;
 bytes:=decode(p_pdf,'base64');if substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;hash:=encode(sha256(bytes),'hex');
 if p_attestation->>'authority' is distinct from 'true' or p_attestation->>'acceptance' is distinct from 'true' or p_attestation->>'reviewed_hash' is distinct from hash or p_attestation->>'name' is distinct from p_details->>'B_REPRESENTATIVE' then raise exception 'Review and acceptance required for this exact PDF';end if;
 if p_attestation->>'signing_version' is not null then
 select version into sv from public.portal_signing_profiles where user_id=auth.uid() for share;
 if sv is distinct from (p_attestation->>'signing_version')::uuid or p_attestation->>'assets_authorized' is distinct from 'true' then raise exception 'Signing images changed or not authorized';end if;
 end if;
 company:=public.submit_company_mcnda(p_id,p_details,p_expected_version,p_note);
 insert into public.portal_mcnda_approvals(id,recipient,submission_id,client_pdf,client_hash,client_attestation,company_snapshot) values(request.id,auth.uid(),p_id,p_pdf,hash,p_attestation||jsonb_build_object('signed_at',now(),'account_id',auth.uid(),'template','NEX-2026-10-27'),jsonb_build_object('details',company.details,'version',company.version,'status',company.status));
 return company;
end;$$;
revoke all on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) from public,anon;
grant execute on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) to authenticated;
create function public.approve_mcnda(p_id uuid,p_revision integer,p_action text,p_reviewed_hash text,p_pdf text default null,p_token uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.portal_mcnda_approvals;bytes bytea;email text;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 select * into a from public.portal_mcnda_approvals where id=p_id for update;
 if not found or a.status<>'awaiting_approval' or a.revision<>p_revision or a.client_hash is distinct from p_reviewed_hash then raise exception 'MCNDA changed; preview again';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active) then raise exception 'Client disabled';end if;
 if p_action='prepare' then
 if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Nexora signing assets unavailable';end if;
 update public.portal_mcnda_approvals set approval_token=gen_random_uuid(),approval_by=auth.uid(),approval_at=now(),revision=revision+1 where id=a.id returning * into a;
 return jsonb_build_object('token',a.approval_token,'at',a.approval_at,'revision',a.revision);
 elsif p_action='finalize' then
 if a.approval_token is distinct from p_token or a.approval_by is distinct from auth.uid() or a.approval_at<now()-interval '15 minutes' then raise exception 'Approval expired';end if;
 if length(coalesce(p_pdf,'')) not between 100 and 20000000 then raise exception 'Final PDF required';end if;
 bytes:=decode(p_pdf,'base64');if substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid final PDF';end if;
 update public.portal_mcnda_approvals set status='completed',final_pdf=p_pdf,final_hash=encode(sha256(bytes),'hex'),approval_token=null,revision=revision+1 where id=a.id;
 return jsonb_build_object('status','completed');
 else raise exception 'Invalid action';end if;
end;$$;
revoke all on function public.approve_mcnda(uuid,integer,text,text,text,uuid) from public,anon;
grant execute on function public.approve_mcnda(uuid,integer,text,text,text,uuid) to authenticated;

revoke execute on function public.submit_company_mcnda(uuid,jsonb,integer,text) from public,anon,authenticated;
alter table public.portal_mcnda_assignments alter column template_version set default 'NEX-2026-10-27';
drop policy nda_template_member_read on storage.objects;
create policy nda_template_member_read on storage.objects for select to authenticated using(bucket_id='nexora-documents' and name='nda-template-unsigned-v20261027.pdf' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_mcnda_assignments where user_id=(select auth.uid()) and status in ('draft_review','assigned')))));
notify pgrst, 'reload schema';
commit;
