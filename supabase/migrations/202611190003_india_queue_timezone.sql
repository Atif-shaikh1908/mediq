begin;

alter table public.queue_records
  alter column queue_date set default (now() at time zone 'Asia/Kolkata')::date;

create or replace function public.sync_public_queue_display()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  department_row public.departments%rowtype;
  configured_hospital_name text;
  active_date date;
  serving_token text;
  waiting_token text;
begin
  select * into department_row from public.departments where id = new.department_id;
  select hospital_name into configured_hospital_name from public.hospital_settings where id = true;
  active_date := (now() at time zone 'Asia/Kolkata')::date;

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
  today_kolkata date := (now() at time zone 'Asia/Kolkata')::date;
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

  perform pg_advisory_xact_lock(hashtextextended(department_row.id::text || ':' || today_kolkata::text, 0));
  select coalesce(max(q.token_number), 0) + 1 into next_number
    from public.queue_records q
    where q.department_id = department_row.id and q.queue_date = today_kolkata;
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
    new_visit_id, department_row.id, today_kolkata, next_number, new_token, actor_id
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
  today_kolkata date := (now() at time zone 'Asia/Kolkata')::date;
  next_record public.queue_records%rowtype;
begin
  role_name := public.current_staff_role();
  if actor_id is null or role_name is null or role_name not in ('Admin', 'Receptionist', 'Doctor', 'Nurse') then
    raise exception 'Staff role is not permitted to call queue patients' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_department_id::text || ':' || today_kolkata::text, 0));
  if exists (
    select 1 from public.queue_records
    where department_id = p_department_id and queue_date = today_kolkata and status = 'Serving'
  ) then
    raise exception 'Complete the current visit before calling another patient' using errcode = '55000';
  end if;

  select * into next_record
  from public.queue_records
  where department_id = p_department_id and queue_date = today_kolkata and status = 'Waiting'
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

commit;
