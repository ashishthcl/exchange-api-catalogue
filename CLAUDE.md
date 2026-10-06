# CLAUDE.md

This file gives Claude Code guidance for working in this repository.

## Purpose

`exchange-api-catalog` is a small Mule 4 application that builds a **catalog of every REST API published in an Anypoint Exchange organization**. It lists each API's endpoints and operations, with their parameters and request/response fields. It exposes one HTTP endpoint that returns the catalog as nested JSON or as flat CSV, one row per API, endpoint and field, so the CSV opens directly in Excel.

It works like this:
1. Authenticate to Anypoint Platform with a Connected App using client credentials.
2. Page through Exchange search to find all `rest-api` assets in the organization.
3. For each asset, run in parallel: download its AMF model (flattened JSON-LD with `@graph`) and convert it to endpoints and fields with DataWeave.
4. Render the result as JSON or CSV.

## Tech stack

- Mule runtime **4.12.x** (`app.runtime` 4.12.3, `minMuleVersion` 4.12.0), **Java 17**
- `mule-maven-plugin` 4.10.1, packaging `mule-application`
- Only connector: `mule-http-connector` 1.12.1. It and MUnit 3.7.1+ declare Java 25 support and fail to deploy on Mule 4.9.0 (4.12.3 is fine). Core components and `ee:transform` cover the rest.
- `mule-compression-module` 2.2.6 gunzips the AMF model (Exchange stores it gzipped)
- Tests: MUnit 3.7.4
- Built with Anypoint Code Builder (ACB) in VS Code. See `.vscode/launch.json` for the Run and Debug configurations.

## Layout

```
pom.xml                              Maven build (groupId com.mycompany, artifactId exchange-api-catalog)
mule-artifact.json                   Runtime/Java version; marks encryption.key as a secure property
src/main/mule/exchange-api-catalog.xml   All flows (single config file)
src/main/resources/modules/amfEndpoints.dwl  DataWeave module: AMF @graph -> endpoints/operations/params/fields
src/main/resources/modules/toRows.dwl        DataWeave module: catalog -> flat rows for CSV
src/main/resources/config.yaml       Plain properties (gitignored)
src/main/resources/secure-config.yaml  Encrypted properties (AES/CBC), read with the secure:: prefix
.encryption.key                      Local copy of the decryption key (gitignored, never commit)
sample-salesforce-management-sapi.csv  Example CSV output for one API
.tooling-project/, .mule/            ACB-generated tooling caches (gitignored, do not edit)
```

## Flows (`exchange-api-catalog.xml`)

| Name | Kind | What it does |
|---|---|---|
| `get-api-catalog-flow` | flow | `GET /api-catalog[?format=csv]` listener. Orchestrates the steps below, then a `choice` on `vars.format` renders CSV through `toRows` or JSON as `{ totalApis, failed, apis[] }` sorted by name. |
| `get-access-token` | sub-flow | `POST /accounts/api/v2/oauth2/token` (client_credentials). Stores the token in `vars.token`. |
| `search-rest-api-assets` | sub-flow | `GET /exchange/api/v2/assets/search?types=rest-api`, paged with `limit`/`offset`. Stops after the first short page or after `exchange.search.maxPages`. Deduplicates on `groupId:assetId` into `vars.assets`. |
| `get-api-endpoints` | flow | Called per asset inside `parallel-foreach` (`maxConcurrency` = `exchange.maxConcurrency`). Fetches the AMF model using `exchange.amfPathTemplate`, gunzips it (falling back to the raw body if it is not gzip), and transforms it with `endpointsFromAmf`. An `on-error-continue` keeps the run going and records `error` plus empty `endpoints` for that asset. |

`get-api-endpoints` is a full `flow` rather than a `sub-flow` because it needs a `try` scope and error handler.

## DataWeave modules

Import them with `import x from modules::<file>`.

- **`amfEndpoints.dwl`**: the core parsing logic. `indexGraph` builds an `@id`→node index so references can be resolved (`node`, `refs`). `endpointsFromAmf` locates the `apiContract:WebAPI` node and walks endpoints → `supportedOperation` → `expects` (request) and `returns` (responses).
  - `typeOf` maps SHACL/RAML shapes to type strings such as `string`, `array<object>` or `a | b`, and handles unions through `anyOf`/`xone`.
  - `fields` recursively flattens object properties into dotted paths. Arrays become `items[].field`, and `allOf` (`sh:and`) parents come first. Depth limits (typeOf > 4, fields > 8) and a `seen` list guard against recursive schemas.
- **`toRows.dwl`**: flattens the catalog into rows with the columns `apiName, assetId, assetVersion, method, path, summary, location, field, type, required`. `location` is `param:<binding>`, `request` or `response:<2xx status>`. Only 2xx responses are included. An endpoint without fields still gets one blank row.

If the AMF vocabulary changes (for example `apiContract:*`, `raml-shapes:*` or `sh:*` keys), only `amfEndpoints.dwl` needs to change.

## Configuration (`src/main/resources/config.yaml`)

| Key | Meaning |
|---|---|
| `http.port` | Listener port. Always `8089`. |
| `anypoint.host` | Control plane host. Use `eu1.anypoint.mulesoft.com` for EU. |
| `anypoint.organizationId` | Org to search. Also the fallback org in the AMF path. |
| `anypoint.groupId` | Defined but not currently used by any flow |
| `anypoint.clientId` | Connected App client ID. The app needs the **Exchange Viewer** scope on the business group(s). |
| `secure::anypoint.clientSecret` | Connected App secret, encrypted in `secure-config.yaml` |
| `exchange.maxConcurrency` | Parallelism for the per-API AMF downloads |
| `exchange.search.pageSize` / `maxPages` | Search paging. Caps the catalog at pageSize × maxPages assets. |
| `exchange.amfPathTemplate` | AMF model path with `{organizationId} {groupId} {assetId} {version}` placeholders |

## Secure properties

`anypoint.clientSecret` lives encrypted in `secure-config.yaml`, which the `secure-properties:config` element loads with `key="${encryption.key}"`, AES/CBC. Reference it as `${secure::anypoint.clientSecret}` or `Mule::p("secure::anypoint.clientSecret")`. The app will not start without the key.

- **Pass the key at runtime:** `-M-Dencryption.key=<key>`. In ACB, the Run/Debug launch configurations in `.vscode/launch.json` prompt for it (password input) on every launch. Paste the contents of `.encryption.key`. On CloudHub/RTF, set `encryption.key` as a protected property (it is listed in `mule-artifact.json` `secureProperties`).
- **Encrypt or rotate a value:** `java -cp secure-properties-tool-j17.jar com.mulesoft.tools.SecurePropertiesTool string encrypt AES CBC <key> <value>`, then paste the result as `"![<encrypted>]"`.
- Never put plaintext secrets in `config.yaml`, and never commit or echo the key.

## Running

- In ACB/VS Code, use the **Run Mule Application** or **Debug Mule Application** launch configurations.
- To build from the command line, run `mvn clean package`, which runs the MUnit tests and produces the deployable jar in `target/`. Add `-DskipMunitTests` to skip the tests.
- To call it:
  - `curl http://localhost:8089/api-catalog` returns JSON.
  - `curl "http://localhost:8089/api-catalog?format=csv" -o catalog.csv` returns CSV.

## Tests

- **Suite:** `src/test/munit/get-api-endpoints-test-suite.xml` has 8 tests for `get-api-endpoints`. It mocks the `GET AMF model` HTTP request (matched by `doc:name`) to return `src/test/resources/sample-amf.json`, a hand-written AMF model with 4 operations. Between them they cover enums, a union with null, nested objects, arrays, path/query/header parameters, a gzipped model (`sample-amf.json.gz`), and an HTTP error.
- **Run them:** `mvn test`. MUnit runs on `munit.runtime.version` (defaults to `app.runtime`). If ACB is open on the project it writes to `target/` too, which can lock `mvn clean` or remove files mid-build. Close ACB's run first, or build a copy of the project.
- **Encryption key:** the suite sets a placeholder `encryption.key` global property, because `get-api-endpoints` never decrypts anything.
- **Not covered yet:** `get-api-catalog-flow`, the token and search sub-flows, and `toRows.dwl`. To check CSV output, run the app and compare with `sample-salesforce-management-sapi.csv`.

## Conventions

- Every processor has a `doc:name`. Keep this so the flows read well in the ACB canvas.
- Read properties with `${...}` in attributes and `Mule::p('...')` inside DataWeave. Cast numeric properties explicitly (`as Number`).
- Keep heavy transformation logic in `src/main/resources/modules/*.dwl` (they must be under `resources` to be on the classpath) and keep inline `ee:transform` scripts thin.
