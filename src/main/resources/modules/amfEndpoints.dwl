%dw 2.0
/**
 * Turns an Anypoint Exchange AMF model (flattened JSON-LD with "@graph")
 * into a list of endpoints -> operations -> parameters / request & response fields.
 */

fun asArray(v) = v match {
    case a is Array -> a
    case is Null -> []
    else -> [v]
}

fun indexGraph(amf) = (amf."@graph" default []) reduce ((n, acc = {}) -> acc ++ {(n."@id"): n})

fun node(ix, ref) = if (ref == null) null else (ix[ref."@id" as String] default ref)

fun refs(ix, n, key: String) = asArray(n[key]) map node(ix, $)

fun isA(n, t: String) = asArray(n."@type") contains t

fun lastPart(s, sep: String) = if (s == null) null else (s splitBy sep)[-1]

fun datatype(shape) = lastPart(asArray(shape."sh:datatype")[0]."@id", "#")

fun enumValues(ix, shape) = do {
    var l = node(ix, shape."sh:in")
    ---
    if (l == null) null
    else ((l filterObject ((v, k) -> (k as String) startsWith "rdfs:_")) pluck node(ix, $)) map $."data:value"
}

fun options(ix, shape) = refs(ix, shape, "raml-shapes:anyOf") ++ refs(ix, shape, "sh:xone")

fun typeOf(ix, shape, depth = 0): String =
    if (shape == null) "any"
    else if (depth > 4) "object"
    else if (isA(shape, "raml-shapes:ScalarShape")) (datatype(shape) default "string")
    else if (isA(shape, "raml-shapes:ArrayShape")) "array<" ++ typeOf(ix, node(ix, shape."raml-shapes:items"), depth + 1) ++ ">"
    else if (isA(shape, "raml-shapes:NilShape")) "null"
    else if (isA(shape, "raml-shapes:RecursiveShape")) "object(" ++ (shape."sh:name" default "recursive") ++ ")"
    else if (!isEmpty(options(ix, shape))) (options(ix, shape) map typeOf(ix, $, depth + 1)) joinBy " | "
    else if (isA(shape, "sh:NodeShape")) "object"
    else "any"

fun fields(ix, shape, prefix: String, seen: Array, depth: Number): Array =
    if (shape == null or depth > 8 or (seen contains shape."@id")) []
    else do {
        var nextSeen = seen + shape."@id"
        ---
        if (isA(shape, "raml-shapes:ArrayShape"))
            fields(ix, node(ix, shape."raml-shapes:items"),
                   (if (prefix endsWith ".") prefix[0 to -2] else prefix) ++ "[].", nextSeen, depth + 1)
        else if (!isEmpty(options(ix, shape)))
            (options(ix, shape) flatMap fields(ix, $, prefix, nextSeen, depth + 1)) distinctBy $.field
        else
            // allOf (sh:and) parents first, then own properties
            (refs(ix, shape, "sh:and") flatMap fields(ix, $, prefix, nextSeen, depth + 1))
            ++ (refs(ix, shape, "sh:property") flatMap ((p) -> do {
                    var range = node(ix, p."raml-shapes:range")
                    var path  = prefix ++ (p."sh:name" default lastPart(asArray(p."sh:path")[0]."@id", "#"))
                    var en    = enumValues(ix, range)
                    ---
                    [{
                        field: path,
                        "type": typeOf(ix, range),
                        required: (p."sh:minCount" default 0) > 0,
                        (description: range."core:description") if (range."core:description" != null),
                        (format: range."raml-shapes:format") if (range."raml-shapes:format" != null),
                        ("enum": en) if (!isEmpty(en))
                    }] ++ fields(ix, range, path ++ ".", nextSeen, depth + 1)
               }))
    }

fun schemaName(ix, shape) =
    if (shape == null) null
    else if (isA(shape, "raml-shapes:ArrayShape")) "array<" ++ (schemaName(ix, node(ix, shape."raml-shapes:items")) default "any") ++ ">"
    else if (["schema", "items", "body", "default", null] contains shape."sh:name") typeOf(ix, shape)
    else shape."sh:name"

fun body(ix, message) = refs(ix, message, "apiContract:payload") map ((pl) -> do {
    var schema = node(ix, pl."raml-shapes:schema")
    ---
    {
        mediaType: pl."core:mediaType",
        schema: schemaName(ix, schema),
        fields: fields(ix, schema, "", [], 0)
    }
})

fun params(ix, n) =
    (refs(ix, n, "apiContract:uriParameter") ++ refs(ix, n, "apiContract:parameter")
     ++ refs(ix, n, "apiContract:queryParameter") ++ refs(ix, n, "apiContract:header"))
    map ((p) -> {
        name: p."apiContract:paramName" default p."core:name",
        "in": p."apiContract:binding",
        "type": typeOf(ix, node(ix, p."raml-shapes:schema")),
        required: p."apiContract:required" default false,
        (description: p."core:description") if (p."core:description" != null)
    })

fun endpointsFromAmf(amf) = do {
    var ix  = indexGraph(amf)
    var api = (amf."@graph" filter isA($, "apiContract:WebAPI"))[0]
    ---
    {
        apiName: api."core:name",
        apiVersion: api."core:version",
        endpoints: refs(ix, api, "apiContract:endpoint") flatMap ((ep) ->
            refs(ix, ep, "apiContract:supportedOperation") map ((op) -> do {
                var req = refs(ix, op, "apiContract:expects")[0]
                ---
                {
                    path: ep."apiContract:path",
                    method: upper(op."apiContract:method"),
                    summary: op."apiContract:guiSummary" default op."core:name",
                    operationId: op."apiContract:operationId",
                    parameters: params(ix, ep) ++ params(ix, req),
                    requestBody: body(ix, req),
                    responses: refs(ix, op, "apiContract:returns") map ((r) -> {
                        status: r."apiContract:statusCode",
                        description: r."core:description",
                        body: body(ix, r)
                    })
                }
            }))
    }
}
