# Gestão Comercial

Aplicação web para gestão financeira, estoque, compras, vendas e fornecedores. O GitHub Pages é o destino principal escolhido para o app. O domínio próprio `autofácilbrasileiro.com.br` ainda está sendo servido pelo Netlify até que o DNS seja migrado. Autenticação e dados ficam no Supabase.

## Recursos

- Visão financeira com caixa, recebíveis, lucro estimado e alerta de estoque baixo.
- Catálogo com quantidades de estoque agrupadas por categoria, custos e preços.
- Fornecedores, compras, vendas, despesas e campanhas de marketing.
- Perfil do negócio e perfil da conta, além de sair da sessão e recuperar senha por e-mail.
- Simulador de preços por marketplace com taxas configuráveis.
- Comparação semanal de preços do Mercado Livre com métricas agregadas e recomendações da OpenAI.
- Gastos pessoais com gráficos, filtros, comparação mensal, limites por categoria, metas, contas recorrentes, faturas e parcelas.
- Diagnóstico técnico sem valores financeiros: registra versão, tabelas com falha e, para erros capturados, arquivo, linha, coluna e pilha de chamadas.
- Edição de lançamentos pessoais e contas parceladas; exclusão pede confirmação.
- Perfis protegidos no app e no banco: administrador com leitura de todas as contas; novas contas limitadas à aba pessoal.

## Publicação e autenticação

1. A migração `gestao_comercial_app_setup` já foi aplicada no projeto existente `gestao-comercial` (região São Paulo). Não reutilize o projeto `meu-armazem`, que contém dados de outro assunto.
2. O script `supabase/setup.sql` documenta as tabelas e políticas adicionadas; a configuração continua usando somente publishable key no navegador.
3. O workflow `.github/workflows/pages.yml` publica apenas `index.html`, `app.js`, `styles.css` e `config.js` da branch `main` em `https://martyns1-auto.github.io/gestao-comercial/`.
4. O domínio próprio observado continua no Netlify: `https://autofácilbrasileiro.com.br/`. Ele não muda junto com o GitHub Pages; para usar o domínio próprio no GitHub Pages será necessário configurar o domínio personalizado no repositório e migrar o DNS.
5. Em Supabase Auth → URL Configuration, use o endereço GitHub Pages como Site URL e mantenha o endereço Netlify nas Redirect URLs enquanto ele continuar sendo usado. A recuperação de senha retorna ao host de onde a pessoa iniciou o fluxo.
6. Nunca coloque `service_role`, chave OpenAI ou segredo do cron em `config.js` ou no GitHub.

## Perfis de acesso e gastos pessoais

1. `supabase/enable-personal-access.sql` contém o e-mail de administrador `martyns1@hotmail.com`; se a conta administradora mudar, atualize esse e-mail antes de aplicar o script. Ele cria/atualiza as tabelas pessoais e configura os perfis restritos.
2. A regra cria usuários novos com o perfil `personal_only` automaticamente. O perfil também é verificado pelo aplicativo e pelas políticas RLS do banco.
3. A mesma migração cria `personal_category_budgets`, para definir um limite por categoria e por mês. Na aba Gastos pessoais, o painel mostra o total usado, o limite e o percentual; limites podem ser editados ou removidos.
4. Depois, execute `supabase/personal-finance-enhancements.sql` no SQL Editor do mesmo projeto para ativar metas de economia, contas recorrentes e o vencimento das faturas pessoais. Esse script depende da função de administrador criada pela migração acima.

### Evite executar scripts duplicados

- Para a configuração atual, use `supabase/enable-personal-access.sql` e, depois, `supabase/personal-finance-enhancements.sql`. Não mantenha cópias paralelas dessas migrações.
- `supabase/access-roles.sql` repete a parte de perfis e políticas já incluída no final de `enable-personal-access.sql`; `supabase/personal-finances.sql` é uma cópia parcial antiga do setup pessoal. Não execute esses arquivos junto com o script principal. Se já executou `access-roles.sql` depois do compartilhamento, reaplique `personal-finance-sharing.sql` e, em seguida, `least-privilege-grants.sql`.
- O script de melhorias pode ser reexecutado; o de perfis reconstrói as políticas das tabelas listadas e não deve ser repetido se você criou políticas personalizadas nelas.
- `supabase/setup.sql` é a configuração complementar do aplicativo empresarial já aplicada neste projeto. Não o reexecute para corrigir a aba pessoal.
- `supabase/least-privilege-grants.sql` corrige privilégios de tabela excessivos sem alterar políticas ou dados; aplique uma vez depois dos scripts de tabelas e acesso. Ele pode ser reexecutado com segurança.
- Se reaplicar `enable-personal-access.sql`, ele reconstrói as políticas-base e remove as políticas de compartilhamento. Depois, reexecute na ordem `personal-finance-enhancements.sql`, `personal-finance-sharing.sql` e `least-privilege-grants.sql`. Não reaplique a migração de perfis se criou políticas personalizadas sem antes revisá-las.
- `supabase/weekly_price_review_cron.sql` é separado e só configura o agendamento semanal de pesquisa de preços.
- Criar/salvar várias consultas no SQL Editor não cria tabelas extras por si só. O efeito ocorre quando cada consulta é executada. Os scripts repetem os mesmos nomes de tabelas; `CREATE TABLE IF NOT EXISTS` evita tabelas homônimas duplicadas. Não apague tabelas nem dados para limpar consultas antigas.

## Comparação semanal de preços

1. Aplique a parte aditiva de `supabase/setup.sql` no projeto `gestao-comercial`.
2. Publique `supabase/functions/weekly-price-review` como Edge Function `weekly-price-review`. A configuração está em `supabase/config.toml`; a função valida a sessão do usuário para chamadas do app e um segredo próprio para o cron.
3. Em Supabase → Edge Functions → Secrets, cadastre `OPENAI_API_KEY`, `PRICE_REVIEW_CRON_SECRET`, `SHOPEE_AFFILIATE_APP_ID` e `SHOPEE_AFFILIATE_SECRET`. `OPENAI_MODEL` é opcional (padrão `gpt-4.1-mini`). Todas ficam apenas no servidor. A API de Afiliados Shopee exige acesso/credenciais aprovados; sem elas, o relatório informa que a fonte Shopee está pendente.
4. Habilite `pg_cron`, `pg_net` e Vault. No Vault, crie os segredos `project_url`, `publishable_key` e `cron_secret`; `cron_secret` deve ter o mesmo valor de `PRICE_REVIEW_CRON_SECRET`.
5. A função envia nomes/categorias dos produtos e os dados da comparação de preços à OpenAI para gerar recomendações; não envia tokens de sessão nem lançamentos pessoais.
6. Execute `supabase/weekly_price_review_cron.sql` para agendar a verificação às segundas-feiras, às 09:00 de Brasília. O botão “Comparar agora” permite executar manualmente, com limite de uma análise e chamada de IA por conta por semana.

A comparação consulta anúncios públicos do Mercado Livre e ofertas de produtos disponíveis pela API de Afiliados Shopee. A amostra da Shopee não representa necessariamente todo o catálogo do marketplace, e produtos podem não ser equivalentes; confira os exemplos. A OpenAI recebe somente nome/categoria, preço da loja e métricas agregadas (mínimo, mediana, média e quantidade de ofertas). O relatório limita chamadas por semana e nunca altera preços automaticamente.
