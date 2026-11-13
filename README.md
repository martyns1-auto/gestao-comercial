# Gestão Comercial

Aplicação web para gestão financeira, estoque, compras, vendas e fornecedores. O site é publicado no GitHub Pages; autenticação e dados ficam no Supabase.

## Recursos

- Visão financeira com caixa, recebíveis, lucro estimado e alerta de estoque baixo.
- Catálogo com quantidades de estoque agrupadas por categoria, custos e preços.
- Fornecedores, compras, vendas, despesas e campanhas de marketing.
- Perfil do negócio e perfil da conta, além de sair da sessão e recuperar senha por e-mail.
- Simulador de preços por marketplace com taxas configuráveis.
- Comparação semanal de preços do Mercado Livre com métricas agregadas e recomendações da OpenAI.
- Gastos pessoais, parcelas e exportação de dados.

## Publicação e autenticação

1. A migração `gestao_comercial_app_setup` já foi aplicada no projeto existente `gestao-comercial` (região São Paulo). Não reutilize o projeto `meu-armazem`, que contém dados de outro assunto.
2. O script `supabase/setup.sql` documenta as tabelas e políticas adicionadas; a configuração continua usando somente publishable key no navegador.
3. O workflow `.github/workflows/pages.yml` publica o diretório do site quando há atualização na branch `main`.
4. Em Supabase Auth → URL Configuration, cadastre `https://martyns1-auto.github.io/gestao-comercial/` em Site URL e Redirect URLs. Isso permite que login e recuperação retornem ao site publicado.
5. Nunca coloque `service_role`, chave OpenAI ou segredo do cron em `config.js` ou no GitHub.

## Comparação semanal de preços

1. Aplique a parte aditiva de `supabase/setup.sql` no projeto `gestao-comercial`.
2. Publique `supabase/functions/weekly-price-review` como Edge Function `weekly-price-review`. A configuração está em `supabase/config.toml`; a função valida a sessão do usuário para chamadas do app e um segredo próprio para o cron.
3. Em Supabase → Edge Functions → Secrets, cadastre `OPENAI_API_KEY` e `PRICE_REVIEW_CRON_SECRET`. `OPENAI_MODEL` é opcional (padrão `gpt-4.1-mini`). A chave da OpenAI fica apenas no servidor.
4. Habilite `pg_cron`, `pg_net` e Vault. No Vault, crie os segredos `project_url`, `publishable_key` e `cron_secret`; `cron_secret` deve ter o mesmo valor de `PRICE_REVIEW_CRON_SECRET`.
5. Execute `supabase/weekly_price_review_cron.sql` para agendar a verificação às segundas-feiras, às 09:00 de Brasília. O botão “Comparar agora” permite executar manualmente, com limite de uma análise e chamada de IA por conta por semana.

A comparação consulta anúncios públicos e exibe exemplos para conferência. Produtos similares podem não ser equivalentes. A OpenAI recebe somente nome/categoria do produto, preço da loja e métricas agregadas da busca; ela oferece recomendações, mas nunca altera preços automaticamente.
