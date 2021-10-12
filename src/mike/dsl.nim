from context      import AsyncHandler
from std/httpcore import HttpMethod
import router
import macroutils
import httpx
import middleware
import context
import response
import std/[
    macros,
    macrocache,
    asyncdispatch,
    options,
    tables,
    uri,
    strutils,
    strformat,
    cpuinfo
]
##
## ..code-block ::
##      get "/" do:
##          "Hello world"
##


type 
    # This is used has a form of an IR to allow easy adding of pre and post handler
    RouteIR* = ref object 
        preHandlers: seq[AsyncHandler]
        handler: AsyncHandler
        postHandlers: seq[AsyncHandler]
        context: AsyncHandler

    Route = ref object
        handlers: seq[AsyncHandler]
        context: AsyncHandler # This is a closure which which is returned from a proc that knows the correct type. Will be moved to a middleware

    HandlerType* {.pure.} = enum # TODO, rename to HandlerPos
        Pre    = "before" # Runs before main handler
        Middle = ""       # The main handler
        Post   = "after"  # Runs after the main handler

proc joinHandlers(route: sink RouteIR): seq[AsyncHandler] =
    ## Moves all the handlers from the RouteIR into a list of handlers
    if route.context != nil:
        result &= move route.context
    result &= move route.preHandlers
    result &= move route.handler
    result &= move route.postHandlers

var
    mikeRouter = newRopeRouter()
    routes: array[HttpMethod, Table[string, RouteIR]]

const HttpMethods = ["head", "get", "post", "put", "delete", "trace", "options", "connect", "patch"]

# Store all methods that can be handled by the web server
const implementedMethods = [HttpGet, HttpHead, HttpPost, HttpPut, HttpPatch, HttpDelete, HttpOptions]

proc addHandler(path: string, ctxKind: typedesc, verb: HttpMethod, handType: HandlerType, handler: AsyncHandler) =
    ## Adds a handler to the routing IR
    if not routes[verb].hasKey(path):
            routes[verb][path] = RouteIR(preHandlers: newSeq[AsyncHandler](), postHandlers: newSeq[AsyncHandler]())
    case handType
        of Pre:
            routes[verb][path].preHandlers &= handler
        of Post:
            routes[verb][path].postHandlers &= handler
        of Middle:
            routes[verb][path].handler = handler
    if $ctxKind != "Context": # Only a custom ctx needs the extend context closure
        routes[verb][path].context = extendContext(ctxKind)

macro addMiddleware*(path: static[string], verb: static[HttpMethod], handType: static[HandlerType], handler: AsyncHandler) =
    ## Adds a middleware to a path
    ## `handType` can be either Pre or Post
    ## This is meant for adding plugins using procs, not adding blocks of code
    # This is different from addHandler since this injects a call
    # to get the ctxKind without the user having to explicitly say
    doAssert handType in {Pre, Post}, "Middleware must be pre or post"
    # Get the type of the context parameter
    let ctxKind = ident $handler.getImpl().params[1][1] # Desym the type

    result = quote do:
        addHandler(`path`, `ctxKind`, HttpMethod(`verb`), HandlerType(`handType`), `handler`)

proc getContextInfo(handler: NimNode): tuple[identifier: NimNode, contextType: NimNode] =
    ## Gets the context variable name and type from the handler
    result.identifier = "ctx".ident()
    result.contextType = "Context".ident()
    if handler.kind == nnkDo: # Only do statement can change the context type
        # For future release I'll need to do a typed macro like in dimscmd
        # to find the implementation of it to see if it extends Context
        if handler.params.len > 1:
            let param = handler.params[1]
            result.identifier = param[0]
            result.contextType = param[1]

macro createFullHandler*(path: static[string], httpMethod: HttpMethod, handlerPos: HandlerType,
                         handler: untyped, parameters: varargs[typed] = []): untyped =
    ## Does the needed AST transforms to add needed parsing code to a handler and then
    ## to add that handler to the routing tree
    let handlerProc = handler.createAsyncHandler(path, parameters.getParamPairs())
    var contextType = handlerProc.params[1][1]

    for parameter in parameters.getParamPairs():
        if parameter.kind.super().eqIdent("Context"):
            contextType = parameter.kind

    result = quote do:
        addHandler(`path`, `contextType`, HttpMethod(`httpMethod`), HandlerType(`handlerPos`), `handlerProc`)

template methodHandlerProc(procName, httpMethod, handlerPos) {.dirty.}=
    ## Template for how a route adding macro should look
    ## Passes needed info to `createFullHandler`. This second macro call is needed
    ## so that the parameters can be symed
    macro procName*(path: static[string], handler: untyped): untyped =
        result = newCall(
            bindSym "createFullHandler",
            newLit path,
            newLit HttpMethod(httpMethod),
            newLit HandlerType(handlerPos),
            handler
        )
        for parameter in handler.createParamPairs():
            result &= parameter
        # let (contextIdent, contextType) = handler.getContextInfo()
        # let body =
        # result = quote do:
        #     addHandler(`path`, `contextType`, HttpMethod(httpMethod), HandlerType(handlerPos)) do (`contextIdent`: `contextType`) -> Future[string] {.gcsafe, async.}:
        #         `body`

macro addMethodHandlers(): untyped =
    ## Goes through each HttpMethod and creates the macros that are needed to add routes
    result = newStmtList()
    for verb in HttpMethod:
        for handlerType in HandlerType:
            # Join before or after if applicable before a lower cased version of the http method name
            let name = ident((case handlerType
                of Pre: "before"
                of Middle: ""
                of Post: "after") & toLowerAscii($verb))

            result.add getAst(methodHandlerProc(name, verb, handlerType))

addMethodHandlers()

proc getContextInfoo(contentInfo: NimNode): tuple[verb: NimNode, parameters: seq[ProcParameter]] =
    ## Gets the specified verb along with the context variable and type if specified
    case contentInfo.kind:
        of nnkIdent:
            # Just plain verb ident so use default context
            result.verb = contentInfo
        of nnkObjConstr:
            result.verb = contentInfo[0]
            for parameter in contentInfo[1..^1]:
                parameter.expectKind(nnkExprColonExpr)
                result.parameters &= ProcParameter(
                    name: parameter[0].strVal,
                    kind: parameter[1]
                )

        else:
            raise newException(ValueError, "You have specified a route incorrectly. It should be like `get(ctx: Content):` or `get:`")

proc getHandlerVerbInfo(verbNode: NimNode): (HttpMethod, HandlerType) =
    ## Gets the position and method
    let normalisedName = ($verbNode).nimIdentNormalize()
    # Perform two loops to do a brute force check to find method and position
    # The more costly second loop is only performed if the ident starts with a certain position
    for position in [Pre, Post, Middle]:
        if normalisedName.startsWith($position):
            for methd in implementedMethods:
                # Method must be lowercase since $position when Middle is ""
                let fullVerb = $position & toLowerAscii($methd)
                if fullVerb.eqIdent(verbNode):
                    return (methd, position)
    error("Not a valid route verb " & $verbNode, verbNode)
    

macro `->`*(path: static[string], contextInfo: untyped, handler: untyped): untyped =
    ## Defines the operator used to create a handler
    ## context info is the info about the route e.g. get or get(c: Context)
    runnableExamples:
        "/home" -> get:
            return "You are home"

    let (verb, parameters) = contextInfo.getContextInfoo()
    let (httpMethod, handlerPos) = getHandlerVerbInfo(verb)
    result = newCall(
        bindSym "createFullHandler",
        newLit path,
        newLit HttpMethod(httpMethod),
        newLit HandlerType(handlerPos),
        handler
    )
    for parameter in parameters:
        result &= newLit parameter.name
        result &= parameter.kind


include groupDSL

template send404() =
    ctx.response.body = "Not Found =("
    ctx.response.code = Http404
    req.respond(ctx) 
    req.send()

proc onRequest(req: Request): Future[void] {.async.} =
    {.gcsafe.}:
        if req.path.isSome() and req.httpMethod.isSome():
            var routeResult = mikeRouter.route(req.httpMethod.get(), req.path.get())
            if likely(routeResult.status):
                let handlers = move routeResult.handler
                let ctx = req.newContext(handlers)
                ctx.pathParams = move routeResult.pathParams
                ctx.queryParams = move routeResult.queryParams

                while ctx.index < ctx.handlers.len():
                    let handler = ctx.handlers[ctx.index]
                    let response = await handler(ctx)

                    if response != "":
                        ctx.response.body = response

                    inc ctx.index

                if not ctx.handled:
                    req.respond(ctx)
                when defined(debug):
                    echo(fmt"{req.httpMethod.get()} {req.path.get()} = {ctx.response.code}")
            else:
                when defined(debug):
                    echo(fmt"{req.httpMethod.get()} {req.path.get()} = 404")
                req.send("Not Found =(", code = Http404)
        else:
            req.send(body = "This request is incorrect")



proc addRoutes*(router: var Router[seq[AsyncHandler]], routes: sink array[HttpMethod, Table[string, RouteIR]]) =
    ## Takes in an array of routes and adds them to the router
    ## it then compresses the router for performance
    for verb in HttpMethod:
        for path, route in routes[verb].pairs():
            let handlers = route.joinHandlers()
            router.map(verb, path, handlers)
    router.compress()
    
proc run*(port: int = 8080, threads: Natural = 0) {.gcsafe.}=
    {.gcsafe.}:
        mikeRouter.addRoutes(routes)
    when compileOption("threads"):
        # Use all processors if the user has not specified a number
        var threads = if threads > 0: threads else: countProcessors()
    echo "Started server \\o/ on 127.0.0.1:" & $port
    let settings = initSettings(
        Port(port),
        numThreads = threads
    )
    run(onRequest, settings)
