begin;

create extension if not exists pg_cron with schema pg_catalog;

grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

create function private.cleanup_public_registration_requests()
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  deleted_count bigint;
begin
  delete from private.public_registration_requests
  where created_at < pg_catalog.now() - interval '30 days';

  get diagnostics deleted_count = row_count;
  return deleted_count;
end
$$;

alter function private.cleanup_public_registration_requests() owner to postgres;
revoke all on function private.cleanup_public_registration_requests()
  from public, anon, authenticated, service_role;

create function public.get_public_registration_retention_status()
returns table (approaching_expiry_count bigint, expired_count bigint)
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null or not exists (
    select 1
    from public.staff_profiles
    where user_id = caller_id
      and role = 'Admin'
      and active = true
  ) then
    raise exception 'Active Admin access is required' using errcode = '42501';
  end if;

  return query
  select
    count(*) filter (
      where created_at >= pg_catalog.now() - interval '30 days'
        and created_at <= pg_catalog.now() - interval '25 days'
    ),
    count(*) filter (
      where created_at < pg_catalog.now() - interval '30 days'
    )
  from private.public_registration_requests;
end
$$;

alter function public.get_public_registration_retention_status() owner to postgres;
revoke all on function public.get_public_registration_retention_status()
  from public, anon, authenticated, service_role;
grant execute on function public.get_public_registration_retention_status()
  to authenticated;

do $$
declare
  existing_job record;
begin
  for existing_job in
    select jobid
    from cron.job
    where jobname = 'mediq-clean-public-registration-requests'
  loop
    perform cron.unschedule(existing_job.jobid);
  end loop;

  perform cron.schedule(
    'mediq-clean-public-registration-requests',
    '17 3 * * *',
    'select private.cleanup_public_registration_requests();'
  );
end
$$;

commit;