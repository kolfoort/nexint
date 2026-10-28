begin;
create table if not exists public.portal_mail_delivery_checks(id uuid primary key default gen_random_uuid(),recipient text not null check(recipient='jp@vipcapital.eu'),token_hash text,created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '10 minutes',claimed_at timestamptz,sent_at timestamptz,last_error text);
alter table public.portal_mail_delivery_checks enable row level security;
revoke all on public.portal_mail_delivery_checks from public,anon,authenticated;
grant select,update on public.portal_mail_delivery_checks to service_role;
create or replace function public.claim_mail_delivery_check(p_id uuid,p_token_hash text) returns setof public.portal_mail_delivery_checks language sql security definer set search_path='' as $$
 update public.portal_mail_delivery_checks set token_hash=null,claimed_at=now() where id=p_id and token_hash=p_token_hash and expires_at>now() and claimed_at is null returning *;
$$;
revoke all on function public.claim_mail_delivery_check(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_mail_delivery_check(uuid,text) to service_role;
notify pgrst,'reload schema';
commit;
