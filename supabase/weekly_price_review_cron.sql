-- Execute depois de publicar a Edge Function e cadastrar três segredos no Vault:
-- project_url     = URL do projeto Supabase
-- publishable_key = chave publishable do Supabase
-- cron_secret     = mesmo valor definido como PRICE_REVIEW_CRON_SECRET nos Edge Function secrets
-- Nunca coloque OPENAI_API_KEY ou a chave service_role neste arquivo.

select cron.unschedule(jobid) from cron.job where jobname = 'weekly-market-price-review';

select cron.schedule(
  'weekly-market-price-review',
  '0 12 * * 1', -- segunda-feira, 09:00 no horário de Brasília (UTC-3)
  $$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/weekly-price-review',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'publishable_key'),
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 150000
    ) as request_id;
  $$
);
