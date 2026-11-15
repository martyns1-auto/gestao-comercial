-- Least-privilege hardening for the app's exposed public objects.
-- Apply after setup.sql, enable-personal-access.sql, enhancements and sharing.
-- This script changes table privileges only; it does not change data or RLS policies.
-- Safe to run more than once.

revoke all privileges on table
  public.business_profiles,
  public.marketplace_fees,
  public.marketing_campaigns,
  public.products,
  public.suppliers,
  public.purchases,
  public.purchase_items,
  public.sales,
  public.sale_items,
  public.stock_movements,
  public.expenses,
  public.financial_transactions,
  public.personal_transactions,
  public.personal_installments,
  public.personal_category_budgets,
  public.personal_recurring_bills,
  public.personal_savings_goals,
  public.market_price_reviews,
  public.app_user_roles,
  public.personal_finance_shares,
  public.inventory_summary
from PUBLIC, anon, authenticated;

grant select, insert, update on public.business_profiles to authenticated;
grant select, insert, update, delete on
  public.marketplace_fees,
  public.marketing_campaigns,
  public.products,
  public.suppliers,
  public.purchases,
  public.purchase_items,
  public.sales,
  public.sale_items,
  public.stock_movements,
  public.expenses,
  public.financial_transactions,
  public.personal_transactions,
  public.personal_installments,
  public.personal_category_budgets,
  public.personal_recurring_bills,
  public.personal_savings_goals
to authenticated;
grant select on public.market_price_reviews, public.app_user_roles, public.personal_finance_shares, public.inventory_summary to authenticated;

notify pgrst, 'reload schema';
