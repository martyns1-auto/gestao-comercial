-- Controle de gastos pessoais; dados separados do financeiro empresarial.
create table if not exists public.personal_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  transaction_type text not null check (transaction_type in ('income','expense')),
  description text not null,
  category text not null default 'Outros',
  amount numeric(12,2) not null check (amount > 0),
  transaction_date date not null default current_date,
  status text not null default 'completed' check (status in ('pending','completed')),
  payment_method text not null default 'cash',
  created_at timestamptz not null default now()
);
alter table public.personal_transactions add column if not exists payment_method text not null default 'cash';
alter table public.personal_transactions drop constraint if exists personal_transactions_payment_method_check;
alter table public.personal_transactions add constraint personal_transactions_payment_method_check check (payment_method in ('cash','pix','debit','credit_card','other'));
create table if not exists public.personal_category_budgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  month_start date not null check (extract(day from month_start) = 1),
  category text not null check (length(btrim(category)) between 1 and 80),
  limit_amount numeric(12,2) not null check (limit_amount > 0),
  created_at timestamptz not null default now(),
  unique (user_id, month_start, category)
);
create table if not exists public.personal_installments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null,
  category text not null default 'Outros',
  total_amount numeric(12,2) not null check (total_amount > 0),
  installment_count integer not null check (installment_count > 0),
  paid_installments integer not null default 0 check (paid_installments >= 0 and paid_installments <= installment_count),
  first_due_date date not null default current_date,
  status text not null default 'active' check (status in ('active','paid','cancelled')),
  created_at timestamptz not null default now()
);
alter table public.personal_transactions enable row level security;
alter table public.personal_installments enable row level security;
alter table public.personal_category_budgets enable row level security;
drop policy if exists personal_category_budgets_own on public.personal_category_budgets;
create policy personal_category_budgets_own on public.personal_category_budgets
  for all to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
revoke all on public.personal_category_budgets from anon, authenticated;
grant select, insert, update, delete on public.personal_category_budgets to authenticated;
drop policy if exists personal_transactions_own on public.personal_transactions;
create policy personal_transactions_own on public.personal_transactions for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists personal_installments_own on public.personal_installments;
create policy personal_installments_own on public.personal_installments for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
revoke all on public.personal_transactions, public.personal_installments from anon, authenticated;
grant select, insert, update, delete on public.personal_transactions, public.personal_installments to authenticated;

-- Relatórios semanais de preços de mercado, escritos somente pela Edge Function.
create table if not exists public.market_price_reviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  week_start date not null,
  products_checked integer not null default 0 check (products_checked >= 0),
  items jsonb not null default '[]'::jsonb,
  insights text not null default '',
  errors jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  unique (user_id, week_start)
);
alter table public.market_price_reviews enable row level security;
drop policy if exists market_price_reviews_select_own on public.market_price_reviews;
create policy market_price_reviews_select_own on public.market_price_reviews
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.market_price_reviews from anon, authenticated;
grant select on public.market_price_reviews to authenticated;

-- Gestão de acesso por perfil.
-- O e-mail do administrador é usado somente nesta migração para resolver o UID correto.
-- Usuários comuns acessam exclusivamente seus próprios dados pessoais.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create table if not exists public.app_user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'personal_only' check (role in ('admin','personal_only')),
  created_at timestamptz not null default now()
);
alter table public.app_user_roles enable row level security;
revoke all on public.app_user_roles from anon, authenticated;
grant select on public.app_user_roles to authenticated;
drop policy if exists app_user_roles_select_self on public.app_user_roles;
create policy app_user_roles_select_self on public.app_user_roles
  for select to authenticated using ((select auth.uid()) = user_id);

create or replace function private.is_app_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.app_user_roles r
    where r.user_id = (select auth.uid()) and r.role = 'admin'
  );
$$;
revoke all on function private.is_app_admin() from public, anon;
grant execute on function private.is_app_admin() to authenticated;

create or replace function private.assign_personal_only_role()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.app_user_roles(user_id, role)
  values (new.id, 'personal_only')
  on conflict (user_id) do nothing;
  return new;
end;
$$;
revoke all on function private.assign_personal_only_role() from public, anon, authenticated;
drop trigger if exists assign_app_role_after_signup on auth.users;
create trigger assign_app_role_after_signup
after insert on auth.users
for each row execute function private.assign_personal_only_role();

-- Existing accounts start restricted. The named administrator is promoted below.
insert into public.app_user_roles(user_id, role)
select id, 'personal_only' from auth.users
on conflict (user_id) do nothing;
do $$
declare
  admin_email text := 'ADMIN_EMAIL_HERE';
  admin_id uuid;
begin
  select id into admin_id from auth.users where lower(email) = lower(admin_email);
  if admin_id is null then
    raise exception 'A conta definida em admin_email não existe no Supabase Auth. Substitua ADMIN_EMAIL_HERE pelo e-mail correto e execute novamente.';
  end if;
  update public.app_user_roles set role = 'admin' where user_id = admin_id;
end;
$$;

-- Replace table policies to enforce the two access profiles at the database layer.
do $$
declare
  table_name text;
  policy_row record;
  table_names text[] := array[
    'business_profiles','marketplace_fees','marketing_campaigns','products','suppliers',
    'purchases','purchase_items','sales','sale_items','stock_movements','expenses',
    'financial_transactions','personal_transactions','personal_installments','personal_category_budgets','market_price_reviews'
  ];
begin
  foreach table_name in array table_names loop
    if to_regclass(format('public.%I', table_name)) is null then
      raise exception 'Tabela public.% não existe. Execute primeiro o setup.sql do aplicativo.', table_name;
    end if;
    execute format('alter table public.%I enable row level security', table_name);
    for policy_row in select policyname from pg_policies where schemaname='public' and tablename=table_name loop
      execute format('drop policy %I on public.%I', policy_row.policyname, table_name);
    end loop;
    if table_name = 'market_price_reviews' then
      execute format('create policy %I on public.%I for select to authenticated using ((select private.is_app_admin()))', table_name || '_admin_read_all', table_name);
    elsif table_name in ('personal_transactions','personal_installments','personal_category_budgets') then
      execute format('create policy %I on public.%I for select to authenticated using ((select private.is_app_admin()))', table_name || '_admin_read_all', table_name);
      execute format('create policy %I on public.%I for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', table_name || '_owner_manage', table_name);
    else
      execute format('create policy %I on public.%I for select to authenticated using ((select private.is_app_admin()))', table_name || '_admin_read_all', table_name);
      execute format('create policy %I on public.%I for all to authenticated using ((select private.is_app_admin()) and (select auth.uid()) = user_id) with check ((select private.is_app_admin()) and (select auth.uid()) = user_id)', table_name || '_admin_manage_own', table_name);
    end if;
    execute format('revoke all on public.%I from anon', table_name);
    execute format('grant select, insert, update, delete on public.%I to authenticated', table_name);
  end loop;
end;
$$;
alter view public.inventory_summary set (security_invoker = true);
revoke all on public.inventory_summary from anon;
grant select on public.inventory_summary to authenticated;
