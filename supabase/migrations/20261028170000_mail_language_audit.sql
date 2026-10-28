begin;
alter table public.portal_mail_delivery_checks add column if not exists language text not null default 'en' check(language in('en','nl','de','es','ar'));
alter table public.portal_mail_delivery_checks add column if not exists event text not null default 'released' check(event in('access_receipt','invitation','recovery','document_available','draft_review','released','client_signed','completed','withdrawn','cancelled','upload','quote_receipt','quote_status','access_admin','quote_admin'));
alter table public.portal_mail_delivery_checks add column if not exists document_title text not null default 'MCNDA';
alter table public.portal_mail_delivery_checks add column if not exists batch text;
-- Return the snapshotted language with the already authenticated upload lease.
drop function public.claim_upload_notification(uuid,text);
create function public.claim_upload_notification(p_submission_id uuid,p_token_hash text) returns table(lease_id uuid,client_email text,document_title text,uploaded_at timestamptz,language text) language plpgsql security definer set search_path='' as $$
declare claimed_lease uuid;
begin
 update public.portal_upload_notifications n set status='sending',token_hash=null,attempts=n.attempts+1,lease_id=gen_random_uuid(),leased_at=now(),next_attempt_at=now()+interval '5 minutes' where n.submission_id=p_submission_id and n.token_hash=p_token_hash and n.attempts<5 and (n.status='pending' or (n.status='sending' and n.leased_at<now()-interval '5 minutes')) returning n.lease_id into claimed_lease;
 if claimed_lease is null then return;end if;
 return query select claimed_lease,m.email,s.title,s.created_at,n.language from public.portal_submissions s join public.portal_members m on m.user_id=s.user_id join public.portal_upload_notifications n on n.submission_id=s.id where s.id=p_submission_id;
end;$$;
revoke all on function public.claim_upload_notification(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_upload_notification(uuid,text) to service_role;
notify pgrst,'reload schema';commit;
