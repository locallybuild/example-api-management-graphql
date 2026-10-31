// GraphQL - the orders app's one endpoint.
//
//   POST /api/graphql  {"query": "mutation { placeOrder(productId: \"mug\", quantity: 2) { id } }"}
//   POST /api/graphql  {"query": "{ orders { id productId quantity placedAt } }"}
//
// It answers operations against ../../schema.graphql, the same schema API
// Management checks each operation against before forwarding it (see
// 5-api-management.tf). Mutations are only accepted over POST.
//
// It uses authLevel "function": a caller needs one of the app's function keys,
// so the app can't be called around API Management. The gateway's backend for
// this app holds the key and adds it to each request.
//
// Orders are kept in memory, so they last as long as the worker process does.
// That keeps the example to API Management and the apps behind it; a real app
// would write them to a database.

const { randomUUID } = require("node:crypto");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const { app } = require("@azure/functions");
const { buildSchema, getOperationAST, graphql, parse } = require("graphql");

const schema = buildSchema(readFileSync(path.join(__dirname, "..", "..", "schema.graphql"), "utf8"));

const MAX_QUANTITY = 100;
const orders = [];

// Set by API Management on the requests it forwards, so the response shows
// which way the request came in.
function via(request) {
    return request.headers.get("x-forwarded-by") || "direct";
}

// The resolvers for the Query and Mutation types' fields.
function rootValue(request, context) {
    return {
        orders: () => orders,
        via: () => via(request),
        placeOrder: ({ productId, quantity }) => {
            productId = productId.trim();
            if (!productId) {
                throw new Error("productId is required");
            }
            if (quantity < 1 || quantity > MAX_QUANTITY) {
                throw new Error(`quantity must be from 1 to ${MAX_QUANTITY}`);
            }
            const order = { id: randomUUID(), productId, quantity, placedAt: new Date().toISOString() };
            orders.unshift(order);
            context.log(`placeOrder: order ${order.id} for ${quantity} x ${productId} (via ${via(request)})`);
            return order;
        },
    };
}

// The GraphQL-over-HTTP request: the query string for a GET, the JSON body for
// a POST.
async function readRequest(request) {
    if (request.method === "GET") {
        const q = request.query;
        let variables;
        if (q.get("variables")) {
            variables = JSON.parse(q.get("variables"));
        }
        return { query: q.get("query"), variables, operationName: q.get("operationName") || undefined };
    }
    return await request.json();
}

// isMutation reports whether the operation the request runs is a mutation. A
// query that doesn't parse isn't one; graphql() reports its syntax error.
function isMutation(body) {
    try {
        const op = getOperationAST(parse(body.query), body.operationName);
        return op !== null && op !== undefined && op.operation === "mutation";
    } catch {
        return false;
    }
}

app.http("GraphQL", {
    route: "graphql",
    methods: ["GET", "POST"],
    authLevel: "function",
    handler: async (request, context) => {
        let body;
        try {
            body = await readRequest(request);
        } catch {
            return { status: 400, jsonBody: { errors: [{ message: "the request must be JSON, with variables as a JSON object" }] } };
        }
        if (!body || typeof body.query !== "string" || body.query.trim() === "") {
            return { status: 400, jsonBody: { errors: [{ message: "a query is required" }] } };
        }
        // A GET must not change anything, so a mutation has to be a POST.
        if (request.method === "GET" && isMutation(body)) {
            return { status: 405, headers: { Allow: "POST" }, jsonBody: { errors: [{ message: "mutations must be sent with POST" }] } };
        }

        const result = await graphql({
            schema,
            source: body.query,
            rootValue: rootValue(request, context),
            variableValues: body.variables,
            operationName: body.operationName,
        });
        return { jsonBody: result };
    },
});
