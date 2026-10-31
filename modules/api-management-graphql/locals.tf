locals {
  # The two Function Apps. Each one's code lives in functions/<key>, and is
  # published through API Management as a GraphQL API at /<key>.
  function_apps = toset(["catalog", "orders"])

  # The storefront Web App's code, in app/storefront, hashed the same way.
  storefront_dir = "${path.module}/../../app/storefront"
  storefront_hash = substr(sha1(join(",", [
    for f in sort(fileset(local.storefront_dir, "**")) : "${f}:${filesha1("${local.storefront_dir}/${f}")}"
  ])), 0, 12)

  # A hash of everything in each app's directory, node_modules included, so any
  # change to the code or its dependencies produces a new package name and a
  # redeploy.
  functions_dir = "${path.module}/../../functions"
  function_hashes = {
    for app in local.function_apps : app => substr(sha1(join(",", [
      for f in sort(fileset("${local.functions_dir}/${app}", "**")) : "${f}:${filesha1("${local.functions_dir}/${app}/${f}")}"
    ])), 0, 12)
  }
}
