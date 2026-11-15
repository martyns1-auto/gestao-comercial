-- Compartilhamento privado da aba pessoal entre o administrador e Laiana.
-- Execute depois de enable-personal-access.sql e personal-finance-enhancements.sql.

create table if not exists public.personal_finance_shares (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  invited_user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','active','declined')),
  created_at timestamptz not null default now(),
  constraint personal_finance_shares_distinct_users check (owner_user_id <> invited_user_id),
  constraint personal_finance_shares_pair_unique unique (owner_user_id, invited_user_id)
);

alter table public.personal_finance_shares enable row level security;
revoke all on public.personal_finance_shares from anon, authenticated;
grant select on public.personal_finance_shares to authenticated;
drop policy if exists personal_finance_shares_read_participants on public.personal_finance_shares;
create policy personal_finance_shares_read_participants
  on public.personal_finance_shares for select to authenticated
  using ((select auth.uid()) in (owner_user_id, invited_user_id));

create or replace function private.can_access_personal_finance_user(target_user_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select target_user_id = (select auth.uid())
    or exists (
      select 1
      from public.personal_finance_shares s
      where s.status = 'active'
        and (
          (s.owner_user_id = target_user_id and s.invited_user_id = (select auth.uid()))
          or (s.invited_user_id = target_user_id and s.owner_user_id = (select auth.uid()))
        )
    );
$$;
revoke all on function private.can_access_personal_finance_user(uuid) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.can_access_personal_finance_user(uuid) to authenticated;

drop policy if exists personal_transactions_shared_access on public.personal_transactions;
create policy personal_transactions_shared_access on public.personal_transactions
  for all to authenticated
  using ((select private.can_access_personal_finance_user(user_id)))
  with check ((select private.can_access_personal_finance_user(user_id)));

drop policy if exists personal_installments_shared_access on public.personal_installments;
create policy personal_installments_shared_access on public.personal_installments
  for all to authenticated
  using ((select private.can_access_personal_finance_user(user_id)))
  with check ((select private.can_access_personal_finance_user(user_id)));

drop policy if exists personal_category_budgets_shared_access on public.personal_category_budgets;
create policy personal_category_budgets_shared_access on public.personal_category_budgets
  for all to authenticated
  using ((select private.can_access_personal_finance_user(user_id)))
  with check ((select private.can_access_personal_finance_user(user_id)));

drop policy if exists personal_recurring_bills_shared_access on public.personal_recurring_bills;
create policy personal_recurring_bills_shared_access on public.personal_recurring_bills
  for all to authenticated
  using ((select private.can_access_personal_finance_user(user_id)))
  with check ((select private.can_access_personal_finance_user(user_id)));

drop policy if exists personal_savings_goals_shared_access on public.personal_savings_goals;
create policy personal_savings_goals_shared_access on public.personal_savings_goals
  for all to authenticated
  using ((select private.can_access_personal_finance_user(user_id)))
  with check ((select private.can_access_personal_finance_user(user_id)));

-- The invited user can accept or decline only their own pending invitation.
create or replace function public.respond_personal_finance_share(p_share_id uuid, p_accept boolean)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.personal_finance_shares
     set status = case when p_accept then 'active' else 'declined' end
   where id = p_share_id
     and invited_user_id = (select auth.uid())
     and status = 'pending';
  return found;
end;
$$;
revoke all on function public.respond_personal_finance_share(uuid, boolean) from public, anon;
grant execute on function public.respond_personal_finance_share(uuid, boolean) to authenticated;

-- Invite Laiana. The current app admin is selected as the data owner.
do $$
declare
  owner_id uuid;
  laiana_id uuid;
  admin_count integer;
begin
  select count(*)
    into admin_count
    from public.app_user_roles
   where role = 'admin';
  if admin_count <> 1 then
    raise exception 'Esperava exatamente um administrador para ser dono dos dados compartilhados; encontrei %.', admin_count;
  end if;
  select user_id into owner_id from public.app_user_roles where role = 'admin';

  select id into laiana_id
    from auth.users
   where lower(email) = lower('laiana742@gmail.com');
  if laiana_id is null then
    raise exception 'A conta Laiana não foi encontrada no Supabase Auth. Confira se ela já criou a conta usando laiana742@gmail.com.';
  end if;
  if laiana_id = owner_id then
    raise exception 'O administrador e o convite não podem ser a mesma conta.';
  end if;

  insert into public.personal_finance_shares(owner_user_id, invited_user_id, status)
  values (owner_id, laiana_id, 'pending')
  on conflict (owner_user_id, invited_user_id)
  do update set status = 'pending', created_at = now()
  where public.personal_finance_shares.status = 'declined';
end;
$$;

notify pgrst, 'reload schema';
