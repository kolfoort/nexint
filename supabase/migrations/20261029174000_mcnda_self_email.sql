begin;
create or replace function public.multi_mcnda_delivery_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.portal_document_notifications;v public.portal_mcnda_versions;m public.portal_members;ok boolean:=false;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select * into n from public.portal_document_notifications where id=p_id and lease=p_lease and kind='mcnda_multi' and sent_at is null and skipped_at is null;if not found then return jsonb_build_object('allowed',false);end if;
 select * into m from public.portal_members where user_id=n.recipient and active;if not found then return jsonb_build_object('allowed',false);end if;
 select * into v from public.portal_mcnda_versions where id=n.entity_id;
 if not found or not (exists(select 1 from public.portal_mcnda_parties where version_id=v.id and user_id=m.user_id) or (m.is_admin and n.version_key like 'self-copy:%')) then return jsonb_build_object('allowed',false);end if;
 if n.version_key like 'self-copy:%' then
 ok:=v.status='completed' and v.final_pdf is not null and exists(select 1 from auth.users u where u.id=m.user_id and u.email_confirmed_at is not null and lower(u.email)=lower(m.email));
 elsif n.event='draft_review' then ok:=v.status='draft_review';
 elsif n.event='released' then ok:=v.status='released' and not exists(select 1 from public.portal_mcnda_signatures where version_id=v.id and user_id=m.user_id);
 elsif n.event='client_signed' then ok:=m.is_admin and v.status in('released','awaiting_bundle');
 elsif n.event='completed' then ok:=v.status='completed' and v.final_pdf is not null;
 elsif n.event in('withdrawn','cancelled') then ok:=v.status in('superseded','cancelled');end if;
 return jsonb_build_object('allowed',ok,'email',m.email,'language',coalesce(n.language,public.mail_language_for_email(m.email)),'event',n.event,'url','https://nexint.eu/mcnda-agreements.html?id='||v.id,'needs_signature',n.event='released','self_copy',n.version_key like 'self-copy:%','attachment_pdf',case when ok and n.version_key like 'self-copy:%' then v.final_pdf end,'attachment_hash',case when ok and n.version_key like 'self-copy:%' then v.final_hash end,'attachment_filename','Nexora-MCNDA-'||v.id||'-revision-'||v.revision||'-signed.pdf');
end;$$;
revoke all on function public.multi_mcnda_delivery_context(uuid,uuid) from public,anon,authenticated;grant execute on function public.multi_mcnda_delivery_context(uuid,uuid) to service_role;
create function public.request_my_mcnda_copy(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.portal_mcnda_versions;n uuid;pending uuid;title text;
begin
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() or not portal_private.multi_mcnda_visible(p_id) then raise exception 'Access denied';end if;
 select * into v from public.portal_mcnda_versions where id=p_id;
 if v.status<>'completed' or v.final_pdf is null then raise exception 'The signed PDF is not yet available';end if;
 perform 1 from public.portal_mcnda_threads where id=v.thread_id for update;
 if not exists(select 1 from public.portal_members m join auth.users u on u.id=m.user_id where m.user_id=auth.uid() and m.active and u.email_confirmed_at is not null and lower(m.email)=lower(u.email)) then raise exception 'Verified registered email required';end if;
 select id into pending from public.portal_document_notifications where entity_id=v.id and recipient=auth.uid() and kind='mcnda_multi' and version_key like 'self-copy:%' and sent_at is null and skipped_at is null and attempts<5 order by created_at desc limit 1;
 if pending is not null then perform portal_private.dispatch_document_notifications();return jsonb_build_object('queued',true,'notification_id',pending);end if;
 if (select count(*) from public.portal_mcnda_events where version_id=v.id and actor=auth.uid() and event='signed_pdf_email_requested' and at>now()-interval '1 hour')>=5 or exists(select 1 from public.portal_mcnda_events where version_id=v.id and actor=auth.uid() and event='signed_pdf_email_requested' and at>now()-interval '60 seconds') then raise exception 'Please wait before requesting another copy';end if;
 select t.title into title from public.portal_mcnda_threads t where t.id=v.thread_id;
 insert into public.portal_document_notifications(recipient,kind,entity_id,version_key,document_version,event,title) values(auth.uid(),'mcnda_multi',v.id,'self-copy:'||gen_random_uuid(),v.revision::text,'completed',title) returning id into n;
 perform portal_private.multi_mcnda_log(v.id,'signed_pdf_email_requested',jsonb_build_object('notification_id',n,'recipient_account',auth.uid(),'final_pdf_sha256',v.final_hash,'delivery','PDF attachment to verified registered email only'));
 perform portal_private.dispatch_document_notifications();
 return jsonb_build_object('queued',true,'notification_id',n);
end;$$;
revoke all on function public.request_my_mcnda_copy(uuid) from public,anon;grant execute on function public.request_my_mcnda_copy(uuid) to authenticated;
notify pgrst,'reload schema';commit;
