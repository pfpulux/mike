import ../context

import std/httpcore
import std/json

##
## Helpers for working with the response
##

proc `json=`*[T](ctx: Context, json: T) =
    ## Sets response of the context to be the json.
    ## Also sets the content type header to "application/json"
    ctx.response.headers["Content-Type"] = "application/json"
    ctx.response.body = $ %* json

proc addHeader*(ctx: Context, key, value: string) =
    ## Sets a header `key` to `value`
    ctx.response.headers[key] = value

func status*(ctx: Context): HttpCode =
    ## Returns the HTTP status code code of the current response
    ctx.response.code

proc `status=`*(ctx: Context, code: int | HttpCode) =
    ## Sets the HTTP status code of the response
    ctx.response.code = HttpCode(code)

proc redirect*(ctx: Context, url: string, code = Http301) =
    assert code.is3xx or code == Http201, "redirect only works with 3xx or 201 status codes"
    ctx.status = code
    ctx.addHeader("Location", url)
