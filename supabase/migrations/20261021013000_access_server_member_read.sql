-- Server-only access required by the authenticated access-request handler.
-- No changes to client roles, membership, document access, or RLS policies.
grant select (user_id,email,active,is_admin) on public.portal_members to service_role;
