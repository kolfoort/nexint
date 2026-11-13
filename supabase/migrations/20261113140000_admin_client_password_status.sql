begin;

create or replace function public.admin_client_has_password(p_user_id uuid)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
begin
    if not coalesce((select portal_private.is_admin()), false) then
        raise exception 'Administrator access required' using errcode = '42501';
    end if;

    return (
        select nullif(account.encrypted_password, '') is not null
        from auth.users as account
        join public.portal_members as member on member.user_id = account.id
        where account.id = p_user_id
          and not member.is_admin
    );
end;
$$;

revoke all on function public.admin_client_has_password(uuid) from public, anon;
grant execute on function public.admin_client_has_password(uuid) to authenticated;
notify pgrst, 'reload schema';

commit;
