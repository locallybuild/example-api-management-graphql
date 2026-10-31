// The storefront Web App: the shop's HTML pages, behind API Management.
//
//   GET  /                        the products on sale
//   GET  /products/{id}           one product, its reviews, and forms to order it and review it
//   POST /products/{id}/orders    places an order (a form post: quantity)
//   POST /products/{id}/reviews   adds a review (a form post: rating, text)
//   GET  /orders                  the orders placed so far
//
// Products and orders come from the catalog and orders GraphQL APIs, which
// it calls through the API Management gateway with its own subscription key
// (GATEWAY_URL and SUBSCRIPTION_KEY). Reviews are its own, kept in memory.
//
// It answers only requests carrying the x-api-key that API Management adds
// from its backend's credentials (see 5-api-management.tf), so it can't be
// called around the gateway. It has no dependencies, so there's nothing to
// install before deploying it.
"use strict";

const http = require("node:http");

const apiKey = process.env.API_KEY || "";
const gatewayURL = (process.env.GATEWAY_URL || "").replace(/\/$/, "");
const subscriptionKey = process.env.SUBSCRIPTION_KEY || "";
const port = Number(process.env.PORT || 8080);
const MAX_BODY = 16 * 1024;

const reviews = [
  { productId: "mug", rating: 5, text: "Holds tea. Recommended." },
  { productId: "teapot", rating: 4, text: "Pours without dripping, which is rarer than it should be." },
];

// ---------------------------------------------------------------------------
// GraphQL, through the gateway
// ---------------------------------------------------------------------------

// A GraphQL API that failed or returned errors: the page says what went
// wrong, with a 502.
class GraphQLError extends Error {}

// A form that can't be accepted: the page says why, with a 400.
class InputError extends Error {}

// Sends one GraphQL operation to an API on the gateway (catalog or orders)
// and returns its data, or throws with the errors it returned.
async function graphql(api, query, variables) {
  const res = await fetch(`${gatewayURL}/${api}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Ocp-Apim-Subscription-Key": subscriptionKey },
    body: JSON.stringify({ query, variables }),
  });
  let body;
  try {
    body = await res.json();
  } catch {
    throw new GraphQLError(`the ${api} API answered ${res.status} without a GraphQL response`);
  }
  if (body.errors && body.errors.length > 0) {
    throw new GraphQLError(`the ${api} API: ${body.errors.map((e) => e.message).join("; ")}`);
  }
  if (!res.ok || !body.data) {
    throw new GraphQLError(`the ${api} API answered ${res.status}`);
  }
  return body.data;
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function money(p) {
  return `${p.price.toFixed(2)} ${esc(p.currency)}`;
}

// page wraps a page's content. base is the path the gateway publishes the
// storefront under, so links work through it.
function page(base, via, title, content) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} - Tea Shop</title>
<style>
  :root { color-scheme: light dark; --accent: #2f6f4f; }
  body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 0 auto; padding: 1rem; line-height: 1.5; }
  header { display: flex; justify-content: space-between; align-items: baseline; border-bottom: 1px solid #8884; margin-bottom: 1rem; }
  header a { color: inherit; text-decoration: none; }
  a { color: var(--accent); }
  ul.products { list-style: none; padding: 0; }
  ul.products li { display: flex; justify-content: space-between; padding: .5rem 0; border-bottom: 1px solid #8882; }
  form { margin: 1rem 0; display: grid; gap: .5rem; }
  label { display: grid; gap: .25rem; }
  input, select, textarea, button { font: inherit; padding: .4rem; }
  button { background: var(--accent); color: white; border: 0; border-radius: .25rem; cursor: pointer; justify-self: start; padding: .4rem 1rem; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: .4rem; border-bottom: 1px solid #8882; }
  .error { border-left: 4px solid #b33; padding: .5rem 1rem; background: #b331; }
  footer { margin-top: 2rem; font-size: .85rem; opacity: .7; }
</style>
</head>
<body>
<header><h1><a href="${base}/">Tea Shop</a></h1><a href="${base}/orders">Orders</a></header>
${content}
<footer>Served by the storefront Web App, via ${esc(via)}.</footer>
</body>
</html>`;
}

function stars(n) {
  return "★".repeat(n) + "☆".repeat(5 - n);
}

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------

async function productsPage(base) {
  const { products } = await graphql("catalog", "{ products { id name price currency } }");
  const items = products
    .map((p) => `<li><a href="${base}/products/${encodeURIComponent(p.id)}">${esc(p.name)}</a><span>${money(p)}</span></li>`)
    .join("\n");
  return { title: "Products", content: `<h2>Products</h2>\n<ul class="products">\n${items}\n</ul>` };
}

async function productPage(base, id) {
  const { product } = await graphql("catalog", "query Product($id: ID!) { product(id: $id) { id name price currency } }", { id });
  if (!product) {
    return null;
  }
  const own = reviews.filter((r) => r.productId === product.id);
  const list = own.length
    ? `<ul>${own.map((r) => `<li><span aria-label="${r.rating} out of 5">${stars(r.rating)}</span> ${esc(r.text)}</li>`).join("")}</ul>`
    : "<p>No reviews yet.</p>";
  const action = `${base}/products/${encodeURIComponent(product.id)}`;
  return {
    title: product.name,
    content: `<h2>${esc(product.name)}</h2>
<p>${money(product)}</p>
<form method="post" action="${action}/orders">
  <label>Quantity <input type="number" name="quantity" value="1" min="1" max="100" required></label>
  <button>Place order</button>
</form>
<h3>Reviews</h3>
${list}
<form method="post" action="${action}/reviews">
  <label>Rating <select name="rating">${[5, 4, 3, 2, 1].map((n) => `<option value="${n}">${stars(n)}</option>`).join("")}</select></label>
  <label>Review <textarea name="text" rows="3" maxlength="500"></textarea></label>
  <button>Add review</button>
</form>`,
  };
}

async function ordersPage() {
  // Two APIs, two calls: the orders, and the products to name them by.
  const [{ orders }, { products }] = await Promise.all([
    graphql("orders", "{ orders { id productId quantity placedAt } }"),
    graphql("catalog", "{ products { id name } }"),
  ]);
  const names = Object.fromEntries(products.map((p) => [p.id, p.name]));
  const rows = orders
    .map((o) => `<tr><td>${esc(names[o.productId] || o.productId)}</td><td>${o.quantity}</td><td>${esc(new Date(o.placedAt).toUTCString())}</td></tr>`)
    .join("\n");
  return {
    title: "Orders",
    content: orders.length
      ? `<h2>Orders</h2>\n<table><thead><tr><th>Product</th><th>Quantity</th><th>Placed</th></tr></thead><tbody>\n${rows}\n</tbody></table>`
      : "<h2>Orders</h2>\n<p>No orders yet.</p>",
  };
}

async function placeOrder(id, form) {
  const quantity = Number(form.get("quantity") || 1);
  if (!(Number.isInteger(quantity) && quantity >= 1 && quantity <= 100)) {
    throw new InputError("a quantity from 1 to 100 is required");
  }
  await graphql(
    "orders",
    "mutation Place($productId: ID!, $quantity: Int!) { placeOrder(productId: $productId, quantity: $quantity) { id } }",
    { productId: id, quantity },
  );
}

function addReview(id, form) {
  const rating = Number(form.get("rating"));
  if (!(Number.isInteger(rating) && rating >= 1 && rating <= 5)) {
    throw new InputError("a rating from 1 to 5 is required");
  }
  reviews.push({ productId: id, rating, text: String(form.get("text") || "").slice(0, 500) });
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

function send(res, status, html) {
  res.writeHead(status, { "Content-Type": "text/html; charset=utf-8" });
  res.end(html);
}

function readForm(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
      if (raw.length > MAX_BODY) {
        reject(new InputError("the form is too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(new URLSearchParams(raw)));
    req.on("error", reject);
  });
}

http.createServer(async (req, res) => {
  // Set by API Management on the requests it forwards: the instance's name,
  // and the path it publishes the storefront under.
  const via = req.headers["x-forwarded-by"] || "direct";
  const base = (req.headers["x-forwarded-prefix"] || "").replace(/\/$/, "");
  const render = (status, title, content) => send(res, status, page(base, via, title, content));

  if (!apiKey || req.headers["x-api-key"] !== apiKey) {
    res.writeHead(401, { "Content-Type": "text/plain; charset=utf-8" });
    return res.end(`401: missing or wrong x-api-key (via ${via})\n`);
  }

  try {
    const url = new URL(req.url, "http://localhost");
    let parts;
    try {
      parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);
    } catch {
      return render(404, "Not found", "<h2>Not found</h2>");
    }

    if (req.method === "GET" && parts.length === 0) {
      const p = await productsPage(base);
      return render(200, p.title, p.content);
    }
    if (req.method === "GET" && parts.length === 1 && parts[0] === "orders") {
      const p = await ordersPage();
      return render(200, p.title, p.content);
    }
    if (parts.length >= 2 && parts[0] === "products") {
      const id = parts[1];
      if (req.method === "GET" && parts.length === 2) {
        const p = await productPage(base, id);
        return p ? render(200, p.title, p.content) : render(404, "Not found", `<h2>Not found</h2><p>There's no product "${esc(id)}".</p>`);
      }
      // Each form post redirects (303) to a page, so reloading it doesn't
      // post the form again.
      if (req.method === "POST" && parts.length === 3 && parts[2] === "orders") {
        await placeOrder(id, await readForm(req));
        res.writeHead(303, { Location: `${base}/orders` });
        return res.end();
      }
      if (req.method === "POST" && parts.length === 3 && parts[2] === "reviews") {
        addReview(id, await readForm(req));
        res.writeHead(303, { Location: `${base}/products/${encodeURIComponent(id)}` });
        return res.end();
      }
    }
    render(404, "Not found", "<h2>Not found</h2>");
  } catch (err) {
    if (err instanceof InputError) {
      return render(400, "Check the form", `<h2>Check the form</h2><p class="error">${esc(err.message)}</p>`);
    }
    console.error(err);
    const msg = err instanceof GraphQLError ? err.message : "something went wrong";
    render(502, "Something went wrong", `<h2>Something went wrong</h2><p class="error">${esc(msg)}</p>`);
  }
}).listen(port, () => console.log(`storefront listening on ${port}`));
