No auth needed for testing via Postman.
api_key_required is set to false, 
so Postman can hit it directly with no headers beyond Content-Type.

Setup: create an environment with baseUrl = https://dsxg21wind.execute-api.eu-central-1.amazonaws.com/staging/health

The six requests

### The six requests

| # | Method | Body / URL                                                                                                                          | Expect |
| --- | --- |-------------------------------------------------------------------------------------------------------------------------------------| --- |
| 1 | POST | `{"payload": {"source": "postman", "note": "hello"}}`                                                                               | **200** |
| 2 | POST | `{"nope": true}`                                                                                                                    | **400** |
| 3 | POST | `{"payload":` — deliberately broken JSON                                                                                            | **400** |
| 4 | GET | `{{baseUrl}}?payload=postman-get` — no body                                                                                         | **200** |
| 5 | GET | `{{baseUrl}}` — no query string, no body                                                                                            | **400** |
| 6 | POST | a `payload` string of ~9000 characters. `{"payload": "{{bigPayload}}"`; script: `pm.variables.set("bigPayload", "x".repeat(9000));` | **400** |

For rows 1, 2, 3 and 6: Body → **raw** → **JSON**. For rows 4 and 5: Body → **none**; the value goes in the URL.



Request 1 returns the contract body plus the generated id, 
200 OK as expected. Response:

```bash
{
"status": "healthy",
"message": "Request processed and saved.",
"id": "3f2a…-uuid"
}
```
Request 2 returns error 400, rejected by API Gateway request validator, 
as expected. Response:

```bash
{
    "status": "error",
    "message": "Request body must be a JSON object containing a 'payload' key."
}
```

Request 3 returns error 400, broken json syntax, 
rejected by API Gateway request validator, as expected. Response:

```bash
{
    "status": "error",
    "message": "Request body must be a JSON object containing a 'payload' key."
}
```
Request 4 returns 200 ok, as expected Response:

```bash
{
    "status": "healthy",
    "message": "Request processed and saved.",
    "id": "dcafebf1-2cd3-4c48-843b-99db092b2c0b"
}
```
Request 5 returns error 400, as expected. Rejected by API Gateway. Response:

```bash
{
    "status": "error",
    "message": "Missing required 'payload' query-string parameter."
}
```
Request 6 returns error 400, as expected. Rejected by API Gateway. Response:

```bash
{
    "status": "error",
    "message": "Request body exceeds the maximum of 8192 bytes."
}
```
