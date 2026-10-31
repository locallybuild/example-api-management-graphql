// GraphQL - the catalog's one endpoint.
//
//   POST /api/graphql  {"query": "{ products { id name price } }"}
//   GET  /api/graphql?query={ product(id: "mug") { name } }
//
// It answers queries against ../../schema.graphql, the same schema API
// Management checks each query against before forwarding it (see
// 5-api-management.tf).
//
// It uses authLevel "function": a caller needs one of the app's function keys,
// so the app can't be called around API Management. The gateway's backend for
// this app holds the key and adds it to each request.

const { readFileSync } = require("node:fs");
const path = require("node:path");
const { app } = require("@azure/functions");
const { buildSchema, graphql } = require("graphql");
const { PRODUCTS } = require("../products");

const schema = buildSchema(readFileSync(path.join(__dirname, "..", "..", "schema.graphql"), "utf8"));

// Set by API Management on the requests it forwards, so the response shows
// which way the request came in.
function via(request) {
    return request.headers.get("x-forwarded-by") || "direct";
}

// The resolvers for the Query type's fields.
function rootValue(request) {
    return {
        products: () => PRODUCTS,
        product: ({ id }) => PRODUCTS.find((p) => p.id === id) || null,
        via: () => via(request),
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

        const result = await graphql({
            schema,
            source: body.query,
            rootValue: rootValue(request),
            variableValues: body.variables,
            operationName: body.operationName,
        });
        context.log(`GraphQL: ${body.operationName || "anonymous"} operation, ${result.errors ? result.errors.length : 0} error(s) (via ${via(request)})`);
        return { jsonBody: result };
    },
});
