import httpx
import asyncdispatch
import httpcore
import strtabs
import std/with

type
    Response* = ref object
        code*: HttpCode
        headers*: HttpHeaders
        body*: string
        
    AsyncHandler* = proc (ctx: Context): Future[string] {.gcsafe.}
    #MiddlewareAsyncHandler* = proc (ctx: Context): Future[void]
    
    Context* = ref object of RootObj
        handled*: bool
        response*: Response
        request*: Request
        pathParams*: StringTableRef
        queryParams*: StringTableRef
        handlers*: seq[AsyncHandler] # handlers are stored in the context
        index*: int # The current index in the handlers that is being run

    TestContext* = ref object of Context
        name*: string

    SubContext* {.explain.} = concept x
        # x.handled is bool
        # x.response is Response
        # x.request is Request
        # x.PathParams is StringTableRef
        # x.queryParams is StringTableRef
        # x.handlers is seq[AsyncHandler]
        # x.index is int
        x is Context


proc newResponse*(): Response =
    result = Response(
        code: Http200,
        headers: newHttpHeaders(),
        body: ""
    )
    
proc newContext*(req: Request, handlers: seq[AsyncHandler]): Context =
    result = new Context
    with result:
        handled = false
        handlers = handlers
        request = req
        response = newResponse()
        pathParams = newStringTable()
        queryParams = newStringTable()
    # result = Context(
    #     handled: false,
    #     handlers: handlers,
    #     response: newResponse(),
    #     request: req,
    #     pathParams: newStringTable(),
    #     queryParams: newStringTable()
    # )
