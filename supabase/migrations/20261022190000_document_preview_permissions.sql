begin;
alter table public.portal_document_access add column if not exists can_download boolean not null default true;
alter table public.portal_documents add column if not exists default_can_download boolean not null default true;
create table if not exists public.portal_document_previews (
 document_id uuid primary key references public.portal_documents(id) on delete cascade,
 storage_prefix text not null check(storage_prefix ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}$'),
 page_count integer not null check(page_count between 1 and 200),
 source_sha256 text not null check(source_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz not null default now()
);
alter table public.portal_document_previews enable row level security;
revoke all on public.portal_document_previews from anon,authenticated;
grant select,insert,update,delete on public.portal_document_previews to authenticated;
create policy document_preview_read on public.portal_document_previews for select to authenticated using (
 (select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(
 select 1 from public.portal_document_access a join public.portal_documents d on d.id=a.document_id
 where a.document_id=portal_document_previews.document_id and a.user_id=(select auth.uid()) and d.published))
);
create policy document_preview_manage on public.portal_document_previews for all to authenticated using((select portal_private.is_admin())) with check((select portal_private.is_admin()));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('nexora-document-previews','nexora-document-previews',false,5242880,array['image/webp']) on conflict(id) do nothing;
create policy document_preview_page_read on storage.objects for select to authenticated using(
 bucket_id='nexora-document-previews' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(
 select 1 from public.portal_document_previews p join public.portal_document_access a on a.document_id=p.document_id join public.portal_documents d on d.id=p.document_id
 where a.user_id=(select auth.uid()) and d.published and name like p.storage_prefix||'/%')))
);
create policy document_preview_page_write on storage.objects for insert to authenticated with check(bucket_id='nexora-document-previews' and (select portal_private.is_admin()));
create policy document_preview_page_delete on storage.objects for delete to authenticated using(bucket_id='nexora-document-previews' and (select portal_private.is_admin()));
-- Retain private metadata access for preview-only recipients, but deny original PDF bytes.
drop policy if exists nexora_file_read on storage.objects;
create policy nexora_file_read on storage.objects for select to authenticated using(
 bucket_id='nexora-documents' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(
 select 1 from public.portal_documents d join public.portal_document_access a on a.document_id=d.id
 where d.storage_path=storage.objects.name and d.published and a.user_id=(select auth.uid()) and a.can_download)))
);
-- A preview-only grant cannot be enabled before private page previews are ready.
create or replace function portal_private.require_document_preview() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not new.can_download and not exists(select 1 from public.portal_document_previews where document_id=new.document_id) then raise exception 'Prepare the private document preview before enabling preview-only access';end if;
 return new;
end;$$;
create trigger require_document_preview before insert or update of can_download,document_id on public.portal_document_access for each row execute function portal_private.require_document_preview();
commit;
select 'Per-recipient preview and download permissions installed' as result;
