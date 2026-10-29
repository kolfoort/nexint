begin;
alter table public.commission_events add column if not exists details jsonb not null default '{}';
create function public.agreement_copy_action(p_kind text,p_id uuid,p_delivery text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb; f jsonb; m public.portal_members; n uuid; pending uuid; h text; filename text; email text;
begin
 if p_kind not in ('commission','spa','fco','jv') or p_delivery not in ('download','email') or p_kind is null or p_delivery is null then raise exception 'Invalid request';end if;
 if not portal_private.is_active() or not portal_private.session_mfa_allowed() then raise exception 'MFA_REQUIRED';end if;
 select * into m from public.portal_members where user_id=auth.uid() and active;
 execute format('select to_jsonb(a) from public.%I a where id=$1 for update',p_kind||'_agreements') into a using p_id;
 if a is null or (not m.is_admin and a->>'recipient' is distinct from auth.uid()::text) then raise exception 'Access denied';end if;
 if a->>'status'<>'completed' then raise exception 'Final signed PDF unavailable';end if;
 execute format('select to_jsonb(f) from public.%I f where agreement_id=$1',p_kind||'_final_pdfs') into f using p_id;
 h:=coalesce(f->>'pdf_sha256',f->>'sha256');
 if f->>'pdf_base64' is null or h is null then raise exception 'Final signed PDF unavailable';end if;
 filename:='Nexora-'||upper(p_kind)||'-'||p_id||'-signed.pdf';
 if p_delivery='download' then
 execute format('insert into public.%I(agreement_id,actor,actor_email,event,details) values($1,$2,$3,$4,$5)',p_kind||'_events') using p_id,auth.uid(),m.email,'signed_pdf_download_requested',jsonb_build_object('pdf_sha256',h,'browser_save_not_confirmed',true);
 return jsonb_build_object('pdf',f->>'pdf_base64','hash',h,'filename',filename);
 end if;
 select u.email into email from auth.users u where u.id=auth.uid() and u.email_confirmed_at is not null and lower(u.email)=lower(m.email);
 if email is null then raise exception 'Verified registered email required';end if;
 select id into pending from public.portal_document_notifications where recipient=auth.uid() and kind=p_kind and entity_id=p_id and version_key like 'self-copy:%' and sent_at is null and skipped_at is null and attempts<5 order by created_at desc limit 1;
 if pending is not null then perform portal_private.dispatch_document_notifications();return jsonb_build_object('queued',true,'email',email);end if;
 if (select count(*) from public.portal_document_notifications where recipient=auth.uid() and kind=p_kind and entity_id=p_id and version_key like 'self-copy:%' and created_at>now()-interval '1 hour')>=5 or exists(select 1 from public.portal_document_notifications where recipient=auth.uid() and kind=p_kind and entity_id=p_id and version_key like 'self-copy:%' and created_at>now()-interval '60 seconds') then raise exception 'Please wait before requesting another copy';end if;
 insert into public.portal_document_notifications(recipient,kind,entity_id,version_key,document_version,event,title) values(auth.uid(),p_kind,p_id,'self-copy:'||gen_random_uuid(),coalesce(a->>'revision',a->>'version','1'),'completed','Nexora '||upper(p_kind)||' · '||coalesce(a->>'transaction_code',p_id::text)) returning id into n;
 execute format('insert into public.%I(agreement_id,actor,actor_email,event,details) values($1,$2,$3,$4,$5)',p_kind||'_events') using p_id,auth.uid(),m.email,'signed_pdf_email_requested',jsonb_build_object('notification_id',n,'pdf_sha256',h,'recipient_account',auth.uid(),'delivery','Verified own mailbox only');
 perform portal_private.dispatch_document_notifications();
 return jsonb_build_object('queued',true,'email',email);
end;$$;
revoke all on function public.agreement_copy_action(text,uuid,text) from public,anon;grant execute on function public.agreement_copy_action(text,uuid,text) to authenticated;
create function public.agreement_copy_delivery_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.portal_document_notifications;m public.portal_members;a jsonb;f jsonb; email text;page text;name text;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 select * into n from public.portal_document_notifications where id=p_id and lease=p_lease and leased_at>now()-interval '5 minutes' and sent_at is null and skipped_at is null and version_key like 'self-copy:%' and kind in('commission','spa','fco','jv');
 if not found then return jsonb_build_object('allowed',false);end if;
 select * into m from public.portal_members where user_id=n.recipient and active;
 if not found then return jsonb_build_object('allowed',false);end if;
 select u.email into email from auth.users u where u.id=m.user_id and u.email_confirmed_at is not null and lower(u.email)=lower(m.email);
 if email is null then return jsonb_build_object('allowed',false);end if;
 execute format('select to_jsonb(a) from public.%I a where id=$1',n.kind||'_agreements') into a using n.entity_id;
 if a is null or a->>'status'<>'completed' or (not m.is_admin and a->>'recipient' is distinct from m.user_id::text) then return jsonb_build_object('allowed',false);end if;
 execute format('select to_jsonb(f) from public.%I f where agreement_id=$1',n.kind||'_final_pdfs') into f using n.entity_id;
 if f->>'pdf_base64' is null then return jsonb_build_object('allowed',false);end if;
 page:=n.kind||'-agreements.html';name:=case n.kind when 'commission' then 'Commission Agreement' when 'jv' then 'Joint Venture Agreement' else upper(n.kind) end;
 return jsonb_build_object('allowed',true,'email',email,'language',public.mail_language_for_email(email),'event','completed','needs_signature',false,'url','https://nexint.eu/'||page||'?id='||n.entity_id,'self_copy',true,'document_name',name,'attachment_pdf',f->>'pdf_base64','attachment_hash',coalesce(f->>'pdf_sha256',f->>'sha256'),'attachment_filename','Nexora-'||upper(n.kind)||'-'||n.entity_id||'-signed.pdf');
end;$$;
revoke all on function public.agreement_copy_delivery_context(uuid,uuid) from public,anon,authenticated;grant execute on function public.agreement_copy_delivery_context(uuid,uuid) to service_role;
create function portal_private.agreement_copy_mail_audit() returns trigger language plpgsql security definer set search_path='' as $$
declare email text;event text;
begin
 if new.kind not in('commission','spa','fco','jv') or new.version_key not like 'self-copy:%' then return new;end if;
 if new.sent_at is not null and old.sent_at is null then event:='signed_pdf_email_smtp_submitted';
 elsif new.last_error is distinct from old.last_error and new.last_error is not null then event:='signed_pdf_email_delivery_error';else return new;end if;
 select m.email into email from public.portal_members m where m.user_id=new.recipient;
 execute format('insert into public.%I(agreement_id,actor,actor_email,event,details) values($1,$2,$3,$4,$5)',new.kind||'_events') using new.entity_id,new.recipient,coalesce(email,''),event,jsonb_build_object('notification_id',new.id,'smtp_submission_not_proof_of_receipt',true);
 return new;
end;$$;
revoke all on function portal_private.agreement_copy_mail_audit() from public,anon,authenticated,service_role;
create trigger agreement_copy_mail_audit after update on public.portal_document_notifications for each row execute function portal_private.agreement_copy_mail_audit();
notify pgrst,'reload schema';commit;
