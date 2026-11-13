-- Gestão Comercial: complemento para o esquema já existente no projeto.
-- Preserva suppliers, products, purchases, purchase_items, sales, sale_items,
-- stock_movements, expenses e financial_transactions. Não remova tabelas existentes.

create table if not exists public.business_profiles (
  user_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  business_name text not null default 'Meu negócio',
  opening_cash numeric(12,2) not null default 0 check (opening_cash >= 0),
  investment_limit numeric(12,2) not null default 1000 check (investment_limit >= 0),
  currency text not null default 'BRL' check (currency = 'BRL'),
  updated_at timestamptz not null default now()
);

create table if not exists public.marketplace_fees (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  channel text not null check (channel in ('direct','shopee','mercado_livre','other')),
  commission_percent numeric(6,3) not null default 0 check (commission_percent between 0 and 100),
  fixed_fee numeric(12,2) not null default 0 check (fixed_fee >= 0),
  ads_percent numeric(6,3) not null default 0 check (ads_percent between 0 and 100),
  seller_shipping numeric(12,2) not null default 0 check (seller_shipping >= 0),
  updated_at timestamptz not null default now(),
  unique (user_id, channel)
);

create table if not exists public.marketing_campaigns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null,
  channel text not null default 'instagram',
  starts_at date not null default current_date,
  budget numeric(12,2) not null default 0 check (budget >= 0),
  status text not null default 'planned' check (status in ('planned','active','done','cancelled')),
  notes text,
  created_at timestamptz not null default now()
);

alter table public.business_profiles enable row level security;
alter table public.marketplace_fees enable row level security;
alter table public.marketing_campaigns enable row level security;

drop policy if exists business_profiles_select_own on public.business_profiles;
drop policy if exists business_profiles_insert_own on public.business_profiles;
drop policy if exists business_profiles_update_own on public.business_profiles;
create policy business_profiles_select_own on public.business_profiles for select to authenticated using ((select auth.uid()) = user_id);
create policy business_profiles_insert_own on public.business_profiles for insert to authenticated with check ((select auth.uid()) = user_id);
create policy business_profiles_update_own on public.business_profiles for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists marketplace_fees_select_own on public.marketplace_fees;
drop policy if exists marketplace_fees_insert_own on public.marketplace_fees;
drop policy if exists marketplace_fees_update_own on public.marketplace_fees;
drop policy if exists marketplace_fees_delete_own on public.marketplace_fees;
create policy marketplace_fees_select_own on public.marketplace_fees for select to authenticated using ((select auth.uid()) = user_id);
create policy marketplace_fees_insert_own on public.marketplace_fees for insert to authenticated with check ((select auth.uid()) = user_id);
create policy marketplace_fees_update_own on public.marketplace_fees for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy marketplace_fees_delete_own on public.marketplace_fees for delete to authenticated using ((select auth.uid()) = user_id);

drop policy if exists marketing_campaigns_select_own on public.marketing_campaigns;
drop policy if exists marketing_campaigns_insert_own on public.marketing_campaigns;
drop policy if exists marketing_campaigns_update_own on public.marketing_campaigns;
drop policy if exists marketing_campaigns_delete_own on public.marketing_campaigns;
create policy marketing_campaigns_select_own on public.marketing_campaigns for select to authenticated using ((select auth.uid()) = user_id);
create policy marketing_campaigns_insert_own on public.marketing_campaigns for insert to authenticated with check ((select auth.uid()) = user_id);
create policy marketing_campaigns_update_own on public.marketing_campaigns for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy marketing_campaigns_delete_own on public.marketing_campaigns for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on public.business_profiles, public.marketplace_fees, public.marketing_campaigns from anon, authenticated;
grant select, insert, update on public.business_profiles to authenticated;
grant select, insert, update, delete on public.marketplace_fees, public.marketing_campaigns to authenticated;
grant select, insert, update on public.products, public.suppliers, public.purchases, public.purchase_items,
  public.sales, public.sale_items, public.stock_movements, public.expenses, public.financial_transactions to authenticated;

create or replace view public.inventory_summary with (security_invoker = true) as
select user_id, product_id, sum(case
  when movement_type in ('purchase','in','return','opening') then abs(quantity)
  when movement_type in ('sale','out') then -abs(quantity)
  when movement_type = 'adjustment_in' then abs(quantity)
  when movement_type = 'adjustment_out' then -abs(quantity)
  when movement_type = 'adjustment' then quantity
  else quantity end)::numeric as stock
from public.stock_movements
group by user_id, product_id;
revoke all on public.inventory_summary from anon;
grant select on public.inventory_summary to authenticated;

create or replace function public.record_purchase(p_data jsonb, p_items jsonb)
returns uuid language plpgsql set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_purchase uuid;
  v_item jsonb;
  v_product uuid;
  v_quantity numeric;
  v_unit_cost numeric;
  v_old_cost numeric;
  v_stock numeric;
  v_subtotal numeric := 0;
  v_shipping numeric := coalesce(nullif(p_data->>'shipping_cost','')::numeric, 0);
  v_other numeric := coalesce(nullif(p_data->>'other_costs','')::numeric, 0);
  v_total numeric;
  v_payment text := coalesce(nullif(p_data->>'payment_status',''), 'pending');
begin
  if v_user is null then raise exception 'É necessário entrar na conta.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Inclua ao menos um produto.'; end if;
  if v_payment not in ('pending','paid') then raise exception 'Status de pagamento inválido.'; end if;
  if v_shipping < 0 or v_other < 0 then raise exception 'Frete e outros custos não podem ser negativos.'; end if;
  select coalesce(sum((x.item->>'quantity')::numeric * (x.item->>'unit_cost')::numeric), 0)
    into v_subtotal from jsonb_array_elements(p_items) as x(item);
  if v_subtotal <= 0 then raise exception 'O total dos itens deve ser maior que zero.'; end if;
  v_total := v_subtotal + v_shipping + v_other;

  insert into public.purchases(user_id, supplier_id, purchase_date, invoice_number, status, subtotal, shipping_cost, other_costs, total, notes)
  values (v_user, nullif(p_data->>'supplier_id','')::uuid, coalesce(nullif(p_data->>'purchase_date','')::date,current_date),
    nullif(p_data->>'invoice_number',''), 'received', v_subtotal, v_shipping, v_other, v_total, nullif(p_data->>'notes',''))
  returning id into v_purchase;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::numeric;
    v_unit_cost := (v_item->>'unit_cost')::numeric;
    if v_quantity <= 0 or v_unit_cost < 0 then raise exception 'Quantidade ou custo inválido.'; end if;
    select p.purchase_cost into v_old_cost from public.products as p
      where p.id = v_product and p.user_id = v_user for update;
    if not found then raise exception 'Produto não encontrado para esta conta.'; end if;
    select coalesce(sum(case
      when movement_type in ('purchase','in','return','opening') then abs(quantity)
      when movement_type in ('sale','out') then -abs(quantity)
      when movement_type in ('adjustment_in') then abs(quantity)
      when movement_type in ('adjustment_out') then -abs(quantity)
      when movement_type = 'adjustment' then quantity
      else quantity end),0)
      into v_stock from public.stock_movements
      where user_id = v_user and product_id = v_product;
    update public.products set purchase_cost = case when v_stock <= 0 then v_unit_cost
      else ((v_old_cost * v_stock) + (v_unit_cost * v_quantity)) / (v_stock + v_quantity) end
      where id = v_product and user_id = v_user;
    insert into public.purchase_items(user_id, purchase_id, product_id, quantity, unit_cost, total_cost)
      values (v_user, v_purchase, v_product, v_quantity, v_unit_cost, v_quantity * v_unit_cost);
    insert into public.stock_movements(user_id, product_id, movement_type, quantity, unit_cost, movement_date, source, reference_id, notes)
      values (v_user, v_product, 'purchase', v_quantity, v_unit_cost, coalesce(nullif(p_data->>'purchase_date','')::timestamptz, now()), 'purchase', v_purchase, 'Entrada de compra');
  end loop;

  insert into public.financial_transactions(user_id, type, description, category, amount, status, transaction_date, due_date, paid_at, payment_method, source, external_reference, notes)
  values (v_user, 'expense', coalesce(nullif(p_data->>'invoice_number',''), 'Compra de mercadoria'), 'Mercadoria', v_total,
    case when v_payment = 'paid' then 'paid' else 'pending' end,
    coalesce(nullif(p_data->>'purchase_date','')::date,current_date), nullif(p_data->>'due_date','')::date,
    case when v_payment = 'paid' then now() else null end, nullif(p_data->>'payment_method',''), 'purchase', v_purchase::text, nullif(p_data->>'notes',''));
  return v_purchase;
end;
$$;

create or replace function public.record_sale(p_data jsonb, p_items jsonb)
returns uuid language plpgsql set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_sale uuid;
  v_item jsonb;
  v_product uuid;
  v_quantity numeric;
  v_unit_price numeric;
  v_discount numeric;
  v_unit_cost numeric;
  v_stock numeric;
  v_gross numeric := 0;
  v_discount_total numeric := 0;
  v_fee numeric := coalesce(nullif(p_data->>'marketplace_fee','')::numeric, 0);
  v_shipping numeric := coalesce(nullif(p_data->>'shipping_cost','')::numeric, 0);
  v_other numeric := coalesce(nullif(p_data->>'other_costs','')::numeric, 0);
  v_payment text := coalesce(nullif(p_data->>'payment_status',''), 'pending');
  v_channel text := coalesce(nullif(p_data->>'channel',''), 'other');
begin
  if v_user is null then raise exception 'É necessário entrar na conta.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Inclua ao menos um produto.'; end if;
  if v_payment not in ('pending','partial','paid') then raise exception 'Status de recebimento inválido.'; end if;
  if v_channel not in ('direct','shopee','mercado_livre','other') then raise exception 'Canal inválido.'; end if;
  select coalesce(sum((x.item->>'quantity')::numeric * (x.item->>'unit_price')::numeric),0),
         coalesce(sum(coalesce(nullif(x.item->>'discount','')::numeric,0)),0)
    into v_gross, v_discount_total from jsonb_array_elements(p_items) as x(item);
  if v_gross <= 0 or v_discount_total < 0 or v_discount_total > v_gross then raise exception 'Valor da venda ou desconto inválido.'; end if;
  if v_fee < 0 or v_shipping < 0 or v_other < 0 or v_gross-v_discount_total-v_fee-v_shipping-v_other < 0 then
    raise exception 'Taxas, frete ou descontos deixam o valor líquido negativo.';
  end if;

  insert into public.sales(user_id, sale_date, channel, external_order_id, status, gross_amount, discount_amount, marketplace_fee, shipping_cost, other_costs, net_amount, payment_status, notes)
  values (v_user, coalesce(nullif(p_data->>'sale_date','')::timestamptz,now()), v_channel, nullif(p_data->>'external_order_id',''), 'completed',
    v_gross, v_discount_total, v_fee, v_shipping, v_other, v_gross-v_discount_total-v_fee-v_shipping-v_other, v_payment, nullif(p_data->>'notes',''))
  returning id into v_sale;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::numeric;
    v_unit_price := (v_item->>'unit_price')::numeric;
    v_discount := coalesce(nullif(v_item->>'discount','')::numeric,0);
    select p.purchase_cost into v_unit_cost from public.products as p
      where p.id = v_product and p.user_id = v_user for update;
    if not found then raise exception 'Produto não encontrado para esta conta.'; end if;
    select coalesce(sum(case
      when movement_type in ('purchase','in','return','opening') then abs(quantity)
      when movement_type in ('sale','out') then -abs(quantity)
      when movement_type in ('adjustment_in') then abs(quantity)
      when movement_type in ('adjustment_out') then -abs(quantity)
      when movement_type = 'adjustment' then quantity
      else quantity end),0)
      into v_stock from public.stock_movements
      where user_id = v_user and product_id = v_product;
    if v_quantity <= 0 or v_unit_price < 0 or v_discount < 0 or v_discount > v_quantity*v_unit_price then
      raise exception 'Quantidade, preço ou desconto inválido.';
    end if;
    if v_stock < v_quantity then raise exception 'Estoque insuficiente. Disponível: %, solicitado: %.', v_stock, v_quantity; end if;
    insert into public.sale_items(user_id, sale_id, product_id, quantity, unit_price, unit_cost, discount, line_total)
      values (v_user, v_sale, v_product, v_quantity, v_unit_price, v_unit_cost, v_discount, v_quantity*v_unit_price-v_discount);
    insert into public.stock_movements(user_id, product_id, movement_type, quantity, unit_cost, movement_date, source, reference_id, notes)
      values (v_user, v_product, 'sale', v_quantity, v_unit_cost, coalesce(nullif(p_data->>'sale_date','')::timestamptz,now()), 'sale', v_sale, 'Saída por venda');
  end loop;
  return v_sale;
end;
$$;

create or replace function public.adjust_stock(p_product_id uuid, p_delta numeric, p_notes text default null)
returns void language plpgsql set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_cost numeric;
  v_stock numeric;
begin
  if v_user is null then raise exception 'É necessário entrar na conta.'; end if;
  if p_delta = 0 then raise exception 'O ajuste deve ser diferente de zero.'; end if;
  select purchase_cost into v_cost from public.products where id = p_product_id and user_id = v_user for update;
  if not found then raise exception 'Produto não encontrado para esta conta.'; end if;
  select coalesce(sum(case
    when movement_type in ('purchase','in','return','opening') then abs(quantity)
    when movement_type in ('sale','out') then -abs(quantity)
    when movement_type in ('adjustment_in') then abs(quantity)
    when movement_type in ('adjustment_out') then -abs(quantity)
    when movement_type = 'adjustment' then quantity
    else quantity end),0)
    into v_stock from public.stock_movements where user_id=v_user and product_id=p_product_id;
  if v_stock + p_delta < 0 then raise exception 'O ajuste deixaria o estoque negativo.'; end if;
  insert into public.stock_movements(user_id, product_id, movement_type, quantity, unit_cost, movement_date, source, notes)
    values (v_user, p_product_id, 'adjustment', p_delta, v_cost, now(), 'manual', p_notes);
end;
$$;

revoke all on function public.record_purchase(jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.record_sale(jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.adjust_stock(uuid,numeric,text) from public, anon, authenticated;
grant execute on function public.record_purchase(jsonb,jsonb) to authenticated;
grant execute on function public.record_sale(jsonb,jsonb) to authenticated;
grant execute on function public.adjust_stock(uuid,numeric,text) to authenticated;

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
  created_at timestamptz not null default now()
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