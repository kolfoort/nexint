begin;
create table if not exists public.portal_mail_route_tests(route text not null,entity_id uuid not null,expires_at timestamptz not null default now()+interval '2 hours',primary key(route,entity_id));
alter table public.portal_mail_route_tests enable row level security;
revoke all on public.portal_mail_route_tests from public,anon,authenticated,service_role;
create or replace function public.mail_route_test_recipient(p_route text,p_id uuid) returns text language sql security definer set search_path='' as $$ select 'jp@vipcapital.eu'::text from public.portal_mail_route_tests where route=p_route and entity_id=p_id and expires_at>now(); $$;
revoke all on function public.mail_route_test_recipient(text,uuid) from public,anon,authenticated;
grant execute on function public.mail_route_test_recipient(text,uuid) to service_role;
notify pgrst,'reload schema';
commit;
