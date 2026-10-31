// The products on sale. They're fixed, so the catalog needs no storage of its
// own: the point of this app is to be one of the two backends API Management
// routes to, not to manage a catalog.

const PRODUCTS = [
    { id: "kettle", name: "Kettle", price: 24.99, currency: "EUR" },
    { id: "teapot", name: "Teapot", price: 18.5, currency: "EUR" },
    { id: "mug", name: "Mug", price: 6.0, currency: "EUR" },
    { id: "tea-tin", name: "Tea tin", price: 9.75, currency: "EUR" },
];

module.exports = { PRODUCTS };
