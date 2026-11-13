import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Product = {
  id: string;
  user_id: string;
  name: string;
  category: string | null;
  sale_price: number | string | null;
  min_stock: number | string | null;
  active?: boolean;
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function median(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function weekStart(date = new Date()) {
  const monday = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7));
  return monday.toISOString().slice(0, 10);
}

function adminHeaders(prefer?: string) {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!key) throw new Error("Supabase server key is not configured.");
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/json",
    ...(prefer ? { Prefer: prefer } : {}),
  };
}

async function restRows<T>(table: string, query: string): Promise<T[]> {
  const base = Deno.env.get("SUPABASE_URL");
  if (!base) throw new Error("Supabase URL is not configured.");
  const response = await fetch(`${base}/rest/v1/${table}?${query}`, { headers: adminHeaders() });
  if (!response.ok) throw new Error(`Supabase ${table} query failed (${response.status}).`);
  return await response.json() as T[];
}

async function mercadoLivreSearch(product: Product) {
  const url = new URL("https://api.mercadolibre.com/sites/MLB/search");
  url.searchParams.set("q", [product.name, product.category].filter(Boolean).join(" "));
  url.searchParams.set("limit", "50");
  const response = await fetch(url, { signal: AbortSignal.timeout(12000) });
  if (!response.ok) throw new Error(`Mercado Livre respondeu ${response.status}.`);
  const payload = await response.json();
  const listings = (payload.results || []).filter((item: any) => Number.isFinite(Number(item.price)) && Number(item.price) > 0);
  const prices = listings.map((item: any) => Number(item.price));
  return {
    sample_count: prices.length,
    minimum_price: prices.length ? Math.min(...prices) : null,
    median_price: prices.length ? median(prices) : null,
    average_price: prices.length ? prices.reduce((sum: number, value: number) => sum + value, 0) / prices.length : null,
    examples: listings.slice(0, 3).map((item: any) => ({
      title: String(item.title || "Anúncio").slice(0, 180),
      price: Number(item.price),
      url: String(item.permalink || ""),
    })),
  };
}

async function makeInsight(items: Record<string, unknown>[]) {
  if (!items.some((item) => Number(item.sample_count) > 0)) {
    return "Não encontrei anúncios comparáveis nesta busca. Confira se os nomes dos produtos estão claros e tente novamente.";
  }
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) throw new Error("OPENAI_API_KEY não está configurada nos segredos do Supabase.");
  const comparisonData = items.map((item) => ({
    product_name: item.product_name,
    category: item.category,
    our_price: item.our_price,
    minimum_price: item.minimum_price,
    median_price: item.median_price,
    average_price: item.average_price,
    sample_count: item.sample_count,
  }));
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: Deno.env.get("OPENAI_MODEL") || "gpt-4.1-mini",
      store: false,
      max_output_tokens: 700,
      input: [
        {
          role: "system",
          content: "Você é um assistente de gestão comercial. Responda em português brasileiro, com até 5 recomendações curtas e práticas. Use apenas os dados fornecidos. Compare preços de forma cautelosa: anúncios podem não ser exatamente equivalentes, e os preços são uma amostra pública do Mercado Livre. Aponte oportunidades de revisar preço e atenção ao estoque baixo. Não invente dados nem trate a sugestão como alteração automática de preço.",
        },
        { role: "user", content: JSON.stringify(comparisonData) },
      ],
    }),
    signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) throw new Error(`OpenAI respondeu ${response.status}.`);
  const payload = await response.json();
  return (payload.output || [])
    .flatMap((entry: any) => entry.content || [])
    .filter((entry: any) => entry.type === "output_text")
    .map((entry: any) => entry.text)
    .join("\n").trim() || "A análise não retornou recomendações.";
}

async function reviewUser(userId: string) {
  const existing = await restRows<Record<string, unknown>>(
    "market_price_reviews",
    `select=*&user_id=eq.${encodeURIComponent(userId)}&week_start=eq.${weekStart()}&limit=1`,
  );
  if (existing.length) return { review: existing[0], cached: true };

  const products = await restRows<Product>(
    "products",
    `select=id,user_id,name,category,sale_price,min_stock,active&user_id=eq.${encodeURIComponent(userId)}&order=name.asc`,
  );
  const activeProducts = products.filter((product) => product.active !== false);
  const stockRows = await restRows<{ product_id: string; stock: number | string }>(
    "inventory_summary",
    `select=product_id,stock&user_id=eq.${encodeURIComponent(userId)}`,
  );
  const stockById = new Map(stockRows.map((row) => [row.product_id, Number(row.stock) || 0]));
  const items: Record<string, unknown>[] = [];
  const errors: string[] = [];

  for (let offset = 0; offset < activeProducts.length; offset += 3) {
    const batch = activeProducts.slice(offset, offset + 3);
    const results = await Promise.all(batch.map(async (product) => {
      const stock = stockById.get(product.id) || 0;
      try {
        return {
          product_name: product.name,
          category: product.category,
          our_price: product.sale_price == null ? null : Number(product.sale_price),
          stock,
          min_stock: Number(product.min_stock) || 0,
          low_stock: stock <= (Number(product.min_stock) || 0),
          ...(await mercadoLivreSearch(product)),
        };
      } catch (error) {
        errors.push(`${product.name}: ${error instanceof Error ? error.message : "falha na busca"}`);
        return {
          product_name: product.name,
          category: product.category,
          our_price: product.sale_price == null ? null : Number(product.sale_price),
          stock,
          min_stock: Number(product.min_stock) || 0,
          low_stock: stock <= (Number(product.min_stock) || 0),
          sample_count: 0,
          minimum_price: null,
          median_price: null,
          average_price: null,
          examples: [],
        };
      }
    }));
    items.push(...results);
  }

  const insights = await makeInsight(items);
  const base = Deno.env.get("SUPABASE_URL");
  if (!base) throw new Error("Supabase URL is not configured.");
  const response = await fetch(`${base}/rest/v1/market_price_reviews?on_conflict=user_id,week_start`, {
    method: "POST",
    headers: adminHeaders("resolution=merge-duplicates,return=representation"),
    body: JSON.stringify({
      user_id: userId,
      week_start: weekStart(),
      created_at: new Date().toISOString(),
      products_checked: activeProducts.length,
      items,
      insights,
      errors,
    }),
  });
  if (!response.ok) throw new Error(`Could not save weekly report (${response.status}).`);
  const saved = await response.json();
  return { review: saved[0], cached: false };
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    const cronSecret = Deno.env.get("PRICE_REVIEW_CRON_SECRET");
    const suppliedCronSecret = request.headers.get("x-cron-secret");
    const isCron = Boolean(cronSecret && suppliedCronSecret && suppliedCronSecret === cronSecret);
    let userId: string | null = null;

    if (!isCron) {
      const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
      const base = Deno.env.get("SUPABASE_URL");
      const anon = Deno.env.get("SUPABASE_ANON_KEY");
      if (!token || !base || !anon) return json({ error: "Entre na plataforma para comparar os preços." }, 401);
      const authResponse = await fetch(`${base}/auth/v1/user`, {
        headers: { apikey: anon, Authorization: `Bearer ${token}` },
      });
      if (!authResponse.ok) return json({ error: "Sua sessão expirou. Entre novamente." }, 401);
      const user = await authResponse.json();
      userId = user.id;
    }

    if (isCron) {
      const profiles = await restRows<{ user_id: string }>("business_profiles", "select=user_id");
      let processed = 0;
      const failed: string[] = [];
      for (const profile of profiles) {
        try {
          await reviewUser(profile.user_id);
          processed++;
        } catch {
          failed.push(profile.user_id);
        }
      }
      return json({ processed, failed: failed.length });
    }

    const result = await reviewUser(userId!);
    return json({
      review: result.review,
      message: result.cached ? "A comparação desta semana já foi feita. Exibindo o relatório existente." : "Comparação semanal concluída.",
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Falha ao executar comparação semanal.";
    return json({ error: message }, 500);
  }
});
