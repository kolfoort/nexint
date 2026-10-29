begin;
create function portal_private.multi_mcnda_final_guard() returns trigger language plpgsql set search_path='' as $$begin
 if old.final_pdf is not null and (new.final_pdf is distinct from old.final_pdf or new.final_hash is distinct from old.final_hash or new.completed_at is distinct from old.completed_at or new.status is distinct from old.status) then raise exception 'A completed agreement cannot be overwritten; create a new version';end if;return new;
end;$$;
revoke all on function portal_private.multi_mcnda_final_guard() from public,anon,authenticated,service_role;
create trigger multi_mcnda_completed_immutable before update of status,final_pdf,final_hash,completed_at on public.portal_mcnda_versions for each row execute function portal_private.multi_mcnda_final_guard();
notify pgrst,'reload schema';commit;
