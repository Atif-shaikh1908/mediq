begin;

create extension if not exists pgcrypto with schema extensions;

create table public.departments (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  code text not null unique check (code ~ '^[A-Z]{2,4}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.departments (name, code) values
  ('General Medicine', 'GM'),
  ('Emergency', 'ER'),
  ('Cardiology', 'CD');

create table public.staff_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text not null check (length(trim(full_name)) between 1 and 120),
  role text not null check (role in ('Admin', 'Receptionist', 'Doctor', 'Nurse')),
  department_id uuid references public.departments(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.hospital_settings (
  id boolean primary key default true check (id),
  hospital_name text not null check (length(trim(hospital_name)) between 1 and 120),
  updated_at timestamptz not null default now()
);

insert into public.hospital_settings (id, hospital_name) values (true, 'MediQ City Hospital');

create table public.patients (
  id uuid primary key default gen_random_uuid(),
  patient_number bigint generated always as identity unique,
  patient_code text generated always as (
    'MQ-' || lpad(patient_number::text, greatest(6, length(patient_number::text)), '0')
  ) stored unique,
  full_name text not null check (length(trim(full_name)) between 1 and 120),
  age smallint not null check (age between 0 and 120),
  gender text not null check (gender in ('Female', 'Male', 'Non-binary', 'Prefer not to say')),
  mobile text not null check (
    length(trim(mobile)) between 7 and 30 and mobile ~ '^[0-9+(). -]{7,30}$'
  ),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.visits (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id),
  department_id uuid not null references public.departments(id),
  status text not null default 'Waiting' check (status in ('Waiting', 'Serving', 'Completed')),
  arrived_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status in ('Serving', 'Completed')) = (started_at is not null)),
  check ((status = 'Completed') = (completed_at is not null))
);

create index visits_patient_arrival_idx on public.visits (patient_id, arrived_at desc);
create index visits_department_status_idx on public.visits (department_id, status, arrived_at);

create table public.queue_records (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null unique references public.visits(id),
  department_id uuid not null references public.departments(id),
  queue_date date not null default (now() at time zone 'UTC')::date,
  token_number integer not null check (token_number > 0),
  token text not null,
  priority text check (priority in ('red', 'yellow', 'green')),
  status text not null default 'Waiting' check (status in ('Waiting', 'Serving', 'Completed')),
  called_at timestamptz,
  completed_at timestamptz,
  created_by uuid not null references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (department_id, queue_date, token_number),
  unique (department_id, queue_date, token),
  check ((status in ('Serving', 'Completed')) = (called_at is not null)),
  check ((status = 'Completed') = (completed_at is not null))
);

create index queue_waiting_order_idx on public.queue_records
  (department_id, queue_date, status, priority, created_at);

create unique index one_serving_record_per_department_idx
  on public.queue_records (department_id, queue_date)
  where status = 'Serving';

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  table_name text not null,
  record_id text,
  changed_fields text[] not null default '{}',
  created_at timestamptz not null default now()
);

create index audit_logs_created_at_idx on public.audit_logs (created_at desc);

-- This deliberately contains only non-identifying display data, never patient IDs or names.
create table public.public_queue_display (
  department_id uuid primary key references public.departments(id) on delete cascade,
  hospital_name text not null,
  department_name text not null,
  department_code text not null,
  now_serving_token text,
  next_token text,
  updated_at timestamptz not null default now()
);

insert into public.public_queue_display (department_id, hospital_name, department_name, department_code)
select d.id, s.hospital_name, d.name, d.code
from public.departments d cross join public.hospital_settings s;

create or replace function public.current_staff_role()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select role
  from public.staff_profiles
  where user_id = (select auth.uid())
    and active = true
  limit 1
$$;

revoke all on function public.current_staff_role() from public, anon;
grant execute on function public.current_staff_role() to authenticated;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

create or replace function public.write_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  old_data jsonb;
  new_data jsonb;
  row_data jsonb;
  fields text[];
begin
  if tg_op = 'INSERT' then
    new_data := to_jsonb(new);
    row_data := new_data;
    select coalesce(array_agg(key order by key), '{}')
      into fields
      from jsonb_object_keys(new_data) as keys(key)
      where key not in ('created_at', 'updated_at');
  elsif tg_op = 'UPDATE' then
    old_data := to_jsonb(old);
    new_data := to_jsonb(new);
    row_data := new_data;
    select coalesce(array_agg(key order by key), '{}')
      into fields
      from jsonb_object_keys(new_data) as keys(key)
      where key not in ('created_at', 'updated_at')
        and old_data -> key is distinct from new_data -> key;
  else
    old_data := to_jsonb(old);
    row_data := old_data;
    select coalesce(array_agg(key order by key), '{}')
      into fields
      from jsonb_object_keys(old_data) as keys(key)
      where key not in ('created_at', 'updated_at');
  end if;

  insert into public.audit_logs (actor_user_id, action, table_name, record_id, changed_fields)
  values (
    auth.uid(),
    tg_op,
    tg_table_name,
    coalesce(row_data ->> 'id', row_data ->> 'user_id'),
    fields
  );
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

create trigger staff_profiles_updated_at before update on public.staff_profiles
  for each row execute function public.set_updated_at();
create trigger hospital_settings_updated_at before update on public.hospital_settings
  for each row execute function public.set_updated_at();
create trigger patients_updated_at before update on public.patients
  for each row execute function public.set_updated_at();
create trigger visits_updated_at before update on public.visits
  for each row execute function public.set_updated_at();
create trigger queue_records_updated_at before update on public.queue_records
  for each row execute function public.set_updated_at();

create trigger audit_staff_profiles after insert or update or delete on public.staff_profiles
  for each row execute function public.write_audit_log();
create trigger audit_hospital_settings after insert or update or delete on public.hospital_settings
  for each row execute function public.write_audit_log();
create trigger audit_patients after insert or update or delete on public.patients
  for each row execute function public.write_audit_log();
create trigger audit_visits after insert or update or delete on public.visits
  for each row execute function public.write_audit_log();
create trigger audit_queue_records after insert or update or delete on public.queue_records
  for each row execute function public.write_audit_log();

create or replace function public.sync_visit_from_queue()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.visits
  set status = new.status,
      started_at = new.called_at,
      completed_at = new.completed_at
  where id = new.visit_id;
  return new;
end
$$;

create trigger sync_queue_visit after insert or update of status, called_at, completed_at
  on public.queue_records
  for each row execute function public.sync_visit_from_queue();

create or replace function public.sync_public_queue_display()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
aS $$
declare
  department_row public.departments%rowtype;
  configured_hospital_name text;
  active_date date;
  serving_token text;
  waiting_token text;
begin
  select * into department_row from public.departments where id = new.department_id;
  select hospital_name into configured_hospital_name from public.hospital_settings where id = true;
  active_date := (now() at time zone 'UTC')::date;

  select token into serving_token
  from public.queue_records
  where department_id = new.department_id and queue_date = active_date and status = 'Serving'
  limit 1;

  select token into waiting_token
  from public.queue_records
  where department_id = new.department_id and queue_date = active_date and status = 'Waiting'
  order by case priority when 'red' then 1 when 'yellow' then 2 when 'green' then 3 else 4 end,
           created_at, id
  limit 1;

  insert into public.public_queue_display (
    department_id, hospital_name, department_name, department_code, now_serving_token, next_token, updated_at
  ) values (
    department_row.id, configured_hospital_name, department_row.name, department_row.code,
    serving_token, waiting_token, now()
  )
  on conflict (department_id) do update
  set hospital_name = excluded.hospital_name,
      department_name = excluded.department_name,
      department_code = excluded.department_code,
      now_serving_token = excluded.now_serving_token,
      next_token = excluded.next_token,
      updated_at = excluded.updated_at;
  return new;
end
$$;

create trigger update_public_queue_display after insert or update of status, priority, called_at, completed_at
  on public.queue_records
  for each row execute function public.sync_public_queue_display();

create or replace function public.sync_public_queue_hospital_name()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.public_queue_display
  set hospital_name = new.hospital_name, updated_at = now();
  return new;
end
$$;

create trigger update_public_queue_hospital_name after update of hospital_name on public.hospital_settings
  for each row execute function public.sync_public_queue_hospital_name();

create or replace function public.register_patient(
  p_full_name text,
  p_age integer,
  p_gender text,
  p_mobile text,
  p_department_id uuid
)
returns table (patient_id uuid, patient_code text, visit_id uuid, queue_record_id uuid, token text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  role_name text;
  department_row public.departments%rowtype;
  new_patient_id uuid;
  new_patient_code text;
  new_visit_id uuid;
  next_number integer;
  today_utc date := (now() at time zone 'UTC')::date;
  new_token text;
  new_queue_id uuid;
begin
  role_name := public.current_staff_role();
  if actor_id is null or role_name is null or role_name not in ('Admin', 'Receptionist') then
    raise exception 'Staff role is not permitted to register patients' using errcode = '42501';
  end if;
  if p_full_name is null or length(trim(p_full_name)) not between 1 and 120
     or p_age is null or p_age not between 0 and 120
     or p_gender not in ('Female', 'Male', 'Non-binary', 'Prefer not to say')
     or p_mobile is null or length(trim(p_mobile)) not between 7 and 30 then
    raise exception 'Patient details are invalid' using errcode = '22023';
  end if;

  select * into department_row from public.departments
    where id = p_department_id and active = true;
  if not found then
    raise exception 'Department is unavailable' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(department_row.id::text || ':' || today_utc::text, 0));
  select coalesce(max(q.token_number), 0) + 1 into next_number
    from public.queue_records q
    where q.department_id = department_row.id and q.queue_date = today_utc;
  new_token := department_row.code || '-' ||
    lpad(next_number::text, greatest(3, length(next_number::text)), '0');

  insert into public.patients (full_name, age, gender, mobile, created_by)
    values (trim(p_full_name), p_age, p_gender, trim(p_mobile), actor_id)
    returning id, patients.patient_code into new_patient_id, new_patient_code;
  insert into public.visits (patient_id, department_id, created_by)
    values (new_patient_id, department_row.id, actor_id)
    returning id into new_visit_id;
  insert into public.queue_records (
    visit_id, department_id, queue_date, token_number, token, created_by
  ) values (
    new_visit_id, department_row.id, today_utc, next_number, new_token, actor_id
  ) returning id into new_queue_id;

  return query select new_patient_id, new_patient_code, new_visit_id, new_queue_id, new_token;
end
$$;

create or replace function public.call_next_patient(p_department_id uuid)
returns table (queue_record_id uuid, visit_id uuid, token text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  role_name text;
  today_utc date := (now() at time zone 'UTC')::date;
  next_record public.queue_records%rowtype;
begin
  role_name := public.current_staff_role();
  if actor_id is null or role_name is null or role_name not in ('Admin', 'Receptionist', 'Doctor', 'Nurse') then
    raise exception 'Staff role is not permitted to call queue patients' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_department_id::text || ':' || today_utc::text, 0));
  if exists (
    select 1 from public.queue_records
    where department_id = p_department_id and queue_date = today_utc and status = 'Serving'
  ) then
    raise exception 'Complete the current visit before calling another patient' using errcode = '55000';
  end if;

  select * into next_record
  from public.queue_records
  where department_id = p_department_id and queue_date = today_utc and status = 'Waiting'
  order by case priority when 'red' then 1 when 'yellow' then 2 when 'green' then 3 else 4 end,
           created_at, id
  for update skip locked
  limit 1;
  if not found then
    raise exception 'No patients are waiting in this department' using errcode = 'P0002';
  end if;

  update public.queue_records
  set status = 'Serving', called_at = now(), updated_by = actor_id
  where id = next_record.id;
  return query select next_record.id, next_record.visit_id, next_record.token, 'Serving'::text;
end
$$;

create or replace function public.set_queue_priority(p_queue_record_id uuid, p_priority text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  role_name text := public.current_staff_role();
begin
  if auth.uid() is null or role_name is null or role_name not in ('Admin', 'Doctor', 'Nurse') then
    raise exception 'Only authorized clinical staff may update priority' using errcode = '42501';
  end if;
  if p_priority is not null and p_priority not in ('red', 'yellow', 'green') then
    raise exception 'Priority is invalid' using errcode = '22023';
  end if;
  update public.queue_records
  set priority = p_priority, updated_by = auth.uid()
  where id = p_queue_record_id and status = 'Waiting';
  if not found then
    raise exception 'Waiting queue record was not found' using errcode = 'P0002';
  end if;
end
$$;

create or replace function public.complete_queue_record(p_queue_record_id uuid)
returns table (queue_record_id uuid, token text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  role_name text := public.current_staff_role();
  completed_record public.queue_records%rowtype;
begin
  if auth.uid() is null or role_name is null or role_name not in ('Admin', 'Doctor', 'Nurse') then
    raise exception 'Staff role is not permitted to complete visits' using errcode = '42501';
  end if;
  update public.queue_records
  set status = 'Completed', completed_at = now(), updated_by = auth.uid()
  where id = p_queue_record_id and status = 'Serving'
  returning * into completed_record;
  if not found then
    raise exception 'Serving queue record was not found' using errcode = 'P0002';
  end if;
  return query select completed_record.id, completed_record.token, 'Completed'::text;
end
$$;

revoke all on function public.register_patient(text, integer, text, text, uuid) from public, anon;
revoke all on function public.call_next_patient(uuid) from public, anon;
revoke all on function public.set_queue_priority(uuid, text) from public, anon;
revoke all on function public.complete_queue_record(uuid) from public, anon;
grant execute on function public.register_patient(text, integer, text, text, uuid) to authenticated;
grant execute on function public.call_next_patient(uuid) to authenticated;
grant execute on function public.set_queue_priority(uuid, text) to authenticated;
grant execute on function public.complete_queue_record(uuid) to authenticated;

alter table public.departments enable row level security;
alter table public.staff_profiles enable row level security;
alter table public.hospital_settings enable row level security;
alter table public.patients enable row level security;
alter table public.visits enable row level security;
alter table public.queue_records enable row level security;
alter table public.audit_logs enable row level security;
alter table public.public_queue_display enable row level security;

create policy "Active staff read departments" on public.departments
  for select to authenticated using (public.current_staff_role() is not null);
create policy "Staff read permitted profiles" on public.staff_profiles
  for select to authenticated
  using (user_id = (select auth.uid()) or public.current_staff_role() = 'Admin');
create policy "Admins create staff profiles" on public.staff_profiles
  for insert to authenticated with check (public.current_staff_role() = 'Admin');
create policy "Admins update staff profiles" on public.staff_profiles
  for update to authenticated
  using (public.current_staff_role() = 'Admin')
  with check (public.current_staff_role() = 'Admin');
create policy "Staff read hospital settings" on public.hospital_settings
  for select to authenticated using (public.current_staff_role() is not null);
create policy "Admins update hospital settings" on public.hospital_settings
  for update to authenticated
  using (public.current_staff_role() = 'Admin')
  with check (public.current_staff_role() = 'Admin');
create policy "Staff read patients" on public.patients
  for select to authenticated using (public.current_staff_role() is not null);
create policy "Admins and reception update patients" on public.patients
  for update to authenticated
  using (public.current_staff_role() in ('Admin', 'Receptionist'))
  with check (public.current_staff_role() in ('Admin', 'Receptionist'));
create policy "Staff read visits" on public.visits
  for select to authenticated using (public.current_staff_role() is not null);
create policy "Staff read queue" on public.queue_records
  for select to authenticated using (public.current_staff_role() is not null);
create policy "Admins read audit log" on public.audit_logs
  for select to authenticated using (public.current_staff_role() = 'Admin');
create policy "Public read token display" on public.public_queue_display
  for select to anon, authenticated using (true);

revoke all on public.departments, public.staff_profiles, public.hospital_settings, public.patients, public.visits,
  public.queue_records, public.audit_logs, public.public_queue_display from public, anon, authenticated;
grant select on public.departments, public.staff_profiles, public.hospital_settings, public.patients, public.visits,
  public.queue_records, public.audit_logs to authenticated;
grant update (full_name, role, department_id) on public.staff_profiles to authenticated;
grant update (hospital_name) on public.hospital_settings to authenticated;
grant update (full_name, age, gender, mobile) on public.patients to authenticated;
grant select on public.public_queue_display to anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise exception 'Supabase Realtime publication is missing; enable it before applying this migration';
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'queue_records'
  ) then
    alter publication supabase_realtime add table public.queue_records;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'public_queue_display'
  ) then
    alter publication supabase_realtime add table public.public_queue_display;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'patients'
  ) then
    alter publication supabase_realtime add table public.patients;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'staff_profiles'
  ) then
    alter publication supabase_realtime add table public.staff_profiles;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'hospital_settings'
  ) then
    alter publication supabase_realtime add table public.hospital_settings;
  end if;
end
$$;

commit;;
