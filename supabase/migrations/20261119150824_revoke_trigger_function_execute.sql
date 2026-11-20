begin;

revoke all on function public.sync_visit_from_queue() from public, anon, authenticated;
revoke all on function public.sync_public_queue_display() from public, anon, authenticated;
revoke all on function public.sync_public_queue_hospital_name() from public, anon, authenticated;
revoke all on function public.write_audit_log() from public, anon, authenticated;

create index if not exists audit_logs_actor_user_id_idx on public.audit_logs (actor_user_id);
create index if not exists patients_created_by_idx on public.patients (created_by);
create index if not exists queue_records_created_by_idx on public.queue_records (created_by);
create index if not exists queue_records_updated_by_idx on public.queue_records (updated_by);
create index if not exists staff_profiles_department_id_idx on public.staff_profiles (department_id);
create index if not exists visits_created_by_idx on public.visits (created_by);

commit;;
