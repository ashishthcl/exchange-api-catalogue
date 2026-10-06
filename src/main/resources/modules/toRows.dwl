%dw 2.0
/** Flattens the catalog into one row per API / endpoint / field (for CSV or Excel). */
fun toRows(catalog: Array) =
    catalog flatMap ((api) ->
        (api.endpoints default []) flatMap ((ep) -> do {
            var base = {
                apiName: api.name default api.apiName,
                assetId: api.assetId,
                assetVersion: api.version,
                method: ep.method,
                path: ep.path,
                summary: ep.summary
            }
            var paramRows = (ep.parameters default []) map (base ++ {
                location: "param:" ++ ($."in" default ""),
                field: $.name, "type": $."type", required: $.required
            })
            var reqRows = (ep.requestBody default []) flatMap ((b) -> b.fields map (base ++ {
                location: "request", field: $.field, "type": $."type", required: $.required
            }))
            var respRows = (ep.responses default [])
                filter ((r) -> (r.status default "") startsWith "2")
                flatMap ((r) -> r.body flatMap ((b) -> b.fields map (base ++ {
                    location: "response:" ++ r.status, field: $.field, "type": $."type", required: $.required
                })))
            var all = paramRows ++ reqRows ++ respRows
            ---
            if (isEmpty(all)) [base ++ {location: "", field: "", "type": "", required: ""}] else all
        }))
