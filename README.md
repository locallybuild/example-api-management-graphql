```
ooooo                                      oooo  oooo              
`888'                                      `888  `888              
 888          .ooooo.   .ooooo.   .oooo.    888   888  oooo    ooo 
 888         d88' `88b d88' `"Y8 `P  )88b   888   888   `88.  .8'
 888         888   888 888        .oP"888   888   888    `88..8'
 888       o 888   888 888   .o8 d8(  888   888   888     `888'
o888ooooood8 `Y8bod8P' `Y8bod8P' `Y888""8o o888o o888o     .8'
                                                       .o..P'
                                                       `Y8P'
```

# Example: Front GraphQL Function Apps and an HTML Web App with API Management within Locally

This example shows how to publish two GraphQL Function Apps and an HTML storefront through one Azure API Management instance on [Locally Build](https://locally.build). Each Function App is a **pass-through GraphQL API**: the gateway checks every operation against the API's schema before forwarding it, so a query that doesn't match is refused without reaching the app. The storefront is an ordinary website behind the same gateway, and gets its data by calling the two GraphQL APIs through the gateway itself. Each app sits behind an API Management **backend** that adds the app's credential to every request, and none of the apps accepts a call without that credential, so the gateway is the only way in.

```
                                API Management (Developer)
                             ┌───────────────────────────────────────────────┐
 curl ───────────────────▶   │  subscription key check (Shop product)        │
   Ocp-Apim-Subscription-Key │  rate-limit: 20 calls / 60s per key           │
                             │                                               │
                             │  /catalog  GraphQL: checked against schema ───│──▶ catalog Function App
                             │              x-functions-key: {{catalog-…}}   │      POST /api/graphql
                             │  /orders   GraphQL: checked against schema ───│──▶ orders Function App
                             │              x-functions-key: {{orders-…}}    │      POST /api/graphql
                             │                                               │
 browser ────────────────▶   │  /shop/*   no key needed ─────────────────────│──▶ storefront Web App
                             │              x-api-key: {{storefront-api-key}}│      HTML pages
                             └───────────────────────────────────────────────┘
                                      ▲                                             │
                                      └──── GraphQL, with its own subscription key ─┘
```

The apps:

* **catalog** ([`functions/catalog`](./functions/catalog)) - a Function App with one GraphQL endpoint. It answers `products` and `product(id)`.
* **orders** ([`functions/orders`](./functions/orders)) - a Function App with one GraphQL endpoint. It answers `orders`, and the `placeOrder(productId, quantity)` mutation.
* **storefront** ([`app/storefront`](./app/storefront)) - a Web App, in plain Node.js with no dependencies, that serves the shop's HTML pages: the products, a page for each product with its reviews, forms to order and review it, and the orders placed so far. The reviews are its own; products and orders come from the two GraphQL APIs.

Each Function App's schema is in its directory (`schema.graphql`). The function answers queries against that file, and Terraform gives the same file to API Management as the API's schema, so the two can't drift apart.

The functions use `authLevel: "function"`, so a request without a function key gets a `401` from the Function App itself. The Web App answers `401` to any request without the `x-api-key` it was configured with. Both GraphQL schemas have a `via` field, and the storefront's pages have a footer, which say whether the request came through the gateway or went to the app directly.

### What API Management is configured with

| Resource | What it does |
| --- | --- |
| `azurerm_api_management` | The gateway itself, on the Developer SKU |
| `azurerm_api_management_named_value` (x3) | Each app's credential, stored as a **secret**: the two Function Apps' default function keys, and the Web App's API key |
| `azurerm_api_management_backend` (x3) | One per app: its `url`, its `resource_id` (the app's ARM ID, as Azure's import writes it), and `credentials` with the header the app checks, set to `{{<named value>}}` |
| `azurerm_api_management_api` (x2, GraphQL) | `api_type = "graphql"` at `/catalog` and `/orders`, with each app's endpoint as its `service_url`, which makes it a pass-through API |
| `azurerm_api_management_api_schema` (x2) | Each GraphQL API's schema, read from the app's `schema.graphql` |
| `azurerm_api_management_api` (storefront) | An HTTP API at `/shop` that needs no subscription key, since browsers don't send one |
| `azurerm_api_management_api_operation` (x5) | One per storefront page or form. The gateway only routes requests that match an operation, and returns `404` for anything else without calling the app. GraphQL APIs have no operations: the gateway reads the operation from the request |
| `azurerm_api_management_api_policy` (x3) | `set-backend-service backend-id="<app>"`, plus an `x-forwarded-by` header. The storefront's also sets `x-forwarded-prefix: /shop`, so the links on its pages go through the gateway |
| `azurerm_api_management_product` | **Shop**, which contains the two GraphQL APIs and requires a subscription |
| `azurerm_api_management_product_policy` | `rate-limit`: 20 calls per 60 seconds for each subscription |
| `azurerm_api_management_subscription` (x2) | Two keys scoped to the Shop product: yours, and the storefront's. Each has its own rate limit allowance |

A GraphQL API's endpoint is the API's URL itself, and the gateway sends it to the backend's `url` as it is:

| Gateway request | Forwarded to |
| --- | --- |
| `POST <gateway>/catalog` | `POST <catalog app>/api/graphql` |
| `POST <gateway>/orders` | `POST <orders app>/api/graphql` |
| `GET  <gateway>/shop/products/mug` | `GET  <storefront app>/products/mug` |

### What the gateway checks in a GraphQL request

Before calling the app, the gateway parses the request and checks the operation against the API's schema. A request that fails gets a GraphQL `errors` response from the gateway, and the app never sees it:

* a query that doesn't parse, or asks for a field or argument the schema doesn't have
* a missing or wrongly-typed variable
* a mutation sent with `GET`
* a subscription (not supported yet)

The app's answer is checked on the way back too: a response that isn't GraphQL becomes a GraphQL error, so callers of a GraphQL API always get GraphQL.

### Backend credentials

Each backend carries the header its app checks, with the value taken from a secret named value:

```hcl
resource "azurerm_api_management_backend" "main" {
  # ...
  url         = "https://<catalog app>/api/graphql"
  resource_id = "https://management.azure.com/subscriptions/.../sites/<catalog app>"

  credentials {
    header = {
      "x-functions-key" = "{{catalog-function-key}}"
    }
  }
}
```

and each API's policy only has to pick its backend:

```xml
<set-backend-service backend-id="catalog" />
```

The gateway fills in the named value for each request and replaces any value the caller sent under that header. As a result, the credential never appears in a policy, the callers never see it, and they only need their subscription key.

Terraform reads each Function App's default function key with the `azurerm_function_app_host_keys` data source. The Web App's key is generated with `random_password` and given to both the app (its `API_KEY` app setting) and API Management.

### The storefront calls the gateway

The storefront doesn't hold a function key: it calls the GraphQL APIs through the gateway like any other caller, with the gateway's URL and a Shop subscription key of its own (its `GATEWAY_URL` and `SUBSCRIPTION_KEY` app settings). So a product page is two trips through the gateway: the browser's request for the page, and the storefront's GraphQL query for the product. The orders page makes two GraphQL calls, one to each API, and joins the orders to the products' names itself.

### Identity

The Function Apps connect to nothing except their host storage (`AzureWebJobsStorage`). Both run as a single **user-assigned managed identity** that holds `Storage Blob Data Owner` and `Storage Queue Data Contributor` on the Storage Account. Shared-key access is switched off on the account (`shared_access_key_enabled = false`). The Web App doesn't use storage. All three apps share one App Service plan.

## Requirements

* [Locally Build](https://locally.build). Using API Management needs the Standard plan or above.
* Either [HashiCorp Terraform](https://terraform.io) or [OpenTofu](https://opentofu.org).
* Either [Docker](https://www.docker.com) or [Podman](https://podman.io) (recommended).
* [Node.js](https://nodejs.org) 24, to install the functions' dependencies. Locally runs the functions with the Node.js on your machine, so its major version needs to match the Function Apps' `node_version`.
* [jq](https://jqlang.org), which some of the commands below use to read Terraform's JSON outputs.
* The Locally Plugin for `Microsoft.ApiManagement` installed (`locally plugin install --name Microsoft.ApiManagement`).
* The Locally Plugin for `Microsoft.Insights` installed (`locally plugin install --name Microsoft.Insights`).
* The Locally Plugin for `Microsoft.OperationalInsights` installed (`locally plugin install --name Microsoft.OperationalInsights`).
* The Locally Plugin for `Microsoft.Storage` installed (`locally plugin install --name Microsoft.Storage`).
* The Locally Plugin for `Microsoft.Web` installed (`locally plugin install --name Microsoft.Web`).

## Running the example

First up, we need to ensure our container runtime (Docker or Podman) is running, then launch Locally:

```bash
locally build
```

Each app is deployed from a zip that Terraform builds from its directory. The Function Apps' zips have to include their dependencies, so we first install those (the Web App has none):

```bash
(cd functions/catalog && npm install)
(cd functions/orders && npm install)
```

With Locally running, in another terminal we can initialise Terraform, which both downloads the providers we need and configures the module for use:

```bash
cd environments/locally
terraform init
```

> [!NOTE]
> You can use OpenTofu instead by running `tofu` wherever this says `terraform`.

With Terraform initialised, we can then provision the example by running:

```bash
locally run terraform apply
```

A single apply creates everything: the three apps with their code, the API Management instance with its backends, APIs, schemas, operations, policies and product, and the two subscriptions. When it finishes, the URLs are in the outputs:

```
gateway_url    = "https://locally-example-apimgql-apim.switchboard.locally:5670"
catalog_url    = "https://locally-example-apimgql-apim.switchboard.locally:5670/catalog"
orders_url     = "https://locally-example-apimgql-apim.switchboard.locally:5670/orders"
storefront_url = "https://locally-example-apimgql-apim.switchboard.locally:5670/shop/"
```

### The storefront

Open `storefront_url` in a browser. Pick a product, place an order and add a review, then look at the Orders page. Every page's footer says `via locally-example-apimgql-apim`, which shows it came through the gateway.

### The GraphQL APIs

The subscription key is a sensitive output. Read it into a variable, along with the URLs:

```bash
KEY=$(locally run terraform output -raw subscription_key)
CATALOG=$(locally run terraform output -raw catalog_url)
ORDERS=$(locally run terraform output -raw orders_url)
```

Then query both APIs through the gateway:

```bash
curl -H "Ocp-Apim-Subscription-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"query": "{ products { id name price currency } via }"}' "$CATALOG"

curl -H "Ocp-Apim-Subscription-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"query": "query Product($id: ID!) { product(id: $id) { name price } }", "variables": {"id": "mug"}}' "$CATALOG"

curl -H "Ocp-Apim-Subscription-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"query": "mutation { placeOrder(productId: \"mug\", quantity: 2) { id placedAt } }"}' "$ORDERS"

curl -H "Ocp-Apim-Subscription-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"query": "{ orders { productId quantity placedAt } via }"}' "$ORDERS"
```

A query can also be sent with `GET`:

```bash
curl -G -H "Ocp-Apim-Subscription-Key: $KEY" --data-urlencode 'query={ product(id: "teapot") { name } }' "$CATALOG"
```

Each `via` says `"locally-example-apimgql-apim"`, which shows the request came through the gateway.

### What the gateway refuses

```bash
# No subscription key: 401 from API Management
curl -i -H 'Content-Type: application/json' -d '{"query": "{ products { id } }"}' "$CATALOG"

# A field the schema doesn't have: a GraphQL error from API Management, without calling the app
curl -H "Ocp-Apim-Subscription-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"query": "{ products { id stock } }"}' "$CATALOG"

# A mutation over GET: 405 from API Management
curl -i -G -H "Ocp-Apim-Subscription-Key: $KEY" \
  --data-urlencode 'query=mutation { placeOrder(productId: "mug") { id } }' "$ORDERS"

# A storefront path with no matching operation: 404 from API Management
curl -i "$(locally run terraform output -raw storefront_url)admin"

# Going around the gateway: 401 from each app, which wants its credential
APPS=$(locally run terraform output -json app_urls)
curl -i -H 'Content-Type: application/json' -d '{"query": "{ via }"}' "$(echo "$APPS" | jq -r .catalog)"
curl -i -H 'Content-Type: application/json' -d '{"query": "{ via }"}' "$(echo "$APPS" | jq -r .orders)"
curl -i "$(echo "$APPS" | jq -r .storefront)"

# More than 20 calls in a minute: 429 from API Management, with a Retry-After header
for i in $(seq 1 25); do
  curl -s -o /dev/null -w "%{http_code}\n" -H "Ocp-Apim-Subscription-Key: $KEY" \
    -H 'Content-Type: application/json' -d '{"query": "{ via }"}' "$CATALOG"
done
```

The rate limit is counted per subscription, so running out of calls with your key doesn't stop the storefront, which has its own.

### Seeing what the gateway did

Send `Ocp-Apim-Trace: true` with a request to have the gateway trace it:

```bash
curl -H "Ocp-Apim-Subscription-Key: $KEY" -H "Ocp-Apim-Trace: true" \
  -H 'Content-Type: application/json' -d '{"query": "{ products { id } }"}' "$CATALOG"
```

The trace is in the Requests page of the API Management instance's admin UI, at `https://locally-example-apimgql-apim-admin.switchboard.locally:5670/_ui/requests`. Open the request to see each step: the GraphQL operation the gateway read from it, the policies that ran, the backend the request went to (with its `resource_id`), the credentials that backend added (by name, never their values), and the app's answer. The storefront's own GraphQL calls show up there too, under the storefront's subscription.

The functions send their logs to a Log Analytics Workspace. You can query them in [the Monitoring section of the Locally Dashboard](https://localhost:5678/monitoring/components) by running:

```
FunctionAppLogs | order by TimeGenerated desc
```

## Notes

The orders and reviews are kept in memory (orders in the orders app, reviews in the storefront), so they're lost when the apps restart. This keeps the example focused on API Management and the apps behind it. A real app would store them in a database.

The GraphQL APIs here are **pass-through**: the apps run the queries, and the gateway checks and forwards them. API Management can also run **synthetic** GraphQL APIs, which have a schema but no `service_url`, and answer each field with a resolver policy (such as `http-data-source`) in the gateway itself.

Every policy keeps `<base />` in each section, so the product's rate limit (the outer scope) runs before the API's own policy.

[`example-api-management-backends`](https://github.com/locallybuild/example-api-management-backends) is the same shop with REST APIs instead of GraphQL.

The rate limit is set by the `rate_limit_calls` and `rate_limit_period` variables on the module.

Terraform writes each package to `.build/<app>-<hash>.zip`, where the hash covers everything in that app's directory. The provider only redeploys the code when `zip_deploy_file` changes, so the hash in the name is what makes an edit to the code (or an `npm install`) reach the app on the next apply.

## Tearing it down

```bash
cd environments/locally
locally run terraform destroy
```
