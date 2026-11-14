-- Execute depois de enable-personal-access.sql no SQL Editor do projeto Supabase.
-- Recursos da aba pessoal: contas recorrentes, metas e vencimento de fatura.
-- Garante que o painel de limites continue disponível mesmo se a migração base tiver sido aplicada parcialmente.
create table if not exists public.personal_category_budgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  month_start date not null check (extract(day from month_start) = 1),
  category text not null check (length(btrim(category)) between 1 and 80),
  limit_amount numeric(12,2) not null check (limit_amount > 0),
  created_at timestamptz not null default now(),
  unique (user_id, month_start, category)
);
alter table public.personal_category_budgets enable row level security;
drop policy if exists personal_category_budgets_admin_read_all on public.personal_category_budgets;
create policy personal_category_budgets_admin_read_all on public.personal_category_budgets
  for select to authenticated using ((select private.is_app_admin()));
drop policy if exists personal_category_budgets_owner_manage on public.personal_category_budgets;
create policy personal_category_budgets_owner_manage on public.personal_category_budgets
  for all to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
revoke all on public.personal_category_budgets from anon, authenticated;
grant select, insert, update, delete on public.personal_category_budgets to authenticated;


create table if not exists public.personal_recurring_bills (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null check (length(btrim(title)) between 1 and 160),
  category text not null default 'Outros' check (length(btrim(category)) between 1 and 80),
  amount numeric(12,2) not null check (amount > 0),
  frequency text not null default 'monthly' check (frequency in ('weekly','monthly','yearly')),
  next_due_date date not null,
  payment_method text not null default 'cash' check (payment_method in ('cash','pix','debit','credit_card','other')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.personal_savings_goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null check (length(btrim(title)) between 1 and 160),
  target_amount numeric(12,2) not null check (target_amount > 0),
  saved_amount numeric(12,2) not null default 0 check (saved_amount >= 0),
  target_date date,
  status text not null default 'active' check (status in ('active','paused','completed')),
  created_at timestamptz not null default now()
);

alter table public.personal_transactions
  add column if not exists card_due_date date,
  add column if not exists recurring_bill_id uuid references public.personal_recurring_bills(id) on delete set null,
  add column if not exists recurring_due_date date;

create unique index if not exists personal_transactions_recurring_occurrence_unique
  on public.personal_transactions(recurring_bill_id, recurring_due_date);

alter table public.personal_recurring_bills enable row level security;
alter table public.personal_savings_goals enable row level security;

drop policy if exists personal_recurring_bills_admin_read_all on public.personal_recurring_bills;
create policy personal_recurring_bills_admin_read_all on public.personal_recurring_bills
  for select to authenticated using ((select private.is_app_admin()));
drop policy if exists personal_recurring_bills_owner_manage on public.personal_recurring_bills;
create policy personal_recurring_bills_owner_manage on public.personal_recurring_bills
  for all to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists personal_savings_goals_admin_read_all on public.personal_savings_goals;
create policy personal_savings_goals_admin_read_all on public.personal_savings_goals
  for select to authenticated using ((select private.is_app_admin()));
drop policy if exists personal_savings_goals_owner_manage on public.personal_savings_goals;
create policy personal_savings_goals_owner_manage on public.personal_savings_goals
  for all to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke all on public.personal_recurring_bills, public.personal_savings_goals from anon, authenticated;
grant select, insert, update, delete on public.personal_recurring_bills, public.personal_savings_goals to authenticated;
revoke all on public.personal_transactions from anon;
grant select, insert, update, delete on public.personal_transactions to authenticated;

-- Atualiza o cache do Data API para reconhecer as colunas adicionadas acima.
notify pgrst, 'reload schema';
