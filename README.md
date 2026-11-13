# Gestão Comercial

Painel web para controlar financeiro, estoque, compras, vendas e fornecedores, preparado para GitHub Pages + Supabase.

## Módulos

- Visão financeira: caixa, recebíveis, pagamentos, lucro estimado e alertas de estoque.
- Produtos e estoque: custo médio, preço de venda, estoque mínimo e fornecedor preferencial.
- Fornecedores, compras e vendas por linha de produto.
- Despesas e ajustes de caixa.
- Simulador de preço por marketplace, com taxas configuráveis.
- Calendário de campanhas de marketing e exportação CSV.

## Configuração

1. A migração `gestao_comercial_app_setup` já foi aplicada no projeto existente `gestao-comercial` (região São Paulo). Não reutilize o projeto `meu-armazem`, que contém dados de outro assunto.
2. O script `supabase/setup.sql` documenta essa migração aditiva para revisão ou recriação em outro projeto. Ele preserva as tabelas comerciais existentes.
3. A configuração pública do app já está em `config.js`. Ela usa somente a publishable key, apropriada para o navegador; nunca inclua uma chave `service_role`/secret.
4. Em Supabase Auth → URL Configuration, cadastre `https://martyns1-auto.github.io/gestao-comercial/` em Site URL e Redirect URLs.
5. O workflow `.github/workflows/pages.yml` publica a raiz do repositório pelo GitHub Pages após cada envio à branch `main`.

## Marketplace

O cadastro de vendas funciona manualmente. A sincronização automática com Shopee e Mercado Livre exige credenciais de vendedor e autorização das APIs oficiais; esses segredos devem permanecer no servidor, nunca no código público do site.
