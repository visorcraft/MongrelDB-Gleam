%% mongreldb_ffi - Erlang FFI for the Gleam MongrelDB client.
%%
%% These functions are called from `src/mongreldb.gleam` via `@external(erlang,
%% "mongreldb_ffi", ...)`. They provide:
%%   - `send/1`: run a gleam/http Request(BitArray) through Erlang's built-in
%%     `httpc`, returning a gleam/http Response(BitArray) or a tagged error.
%%   - `base64_encode/1`: base64-encode credentials for HTTP Basic auth.
%%
%% `httpc` is started (via `inets`) at the top of `send/1` so callers never have
%% to manage the inets application themselves.
%%
%% The gleam/http record shapes for gleam_http 3.6.0 are (custom types compile
%% to Erlang tuples tagged by the constructor name in element 1):
%%   Request:  {request, Method, Headers, Body, Scheme, Host, Port, Path, Query}
%%   Response: {response, Status, Headers, Body}
%% where Headers is a list of {BinaryName, BinaryValue} tuples and Body is a
%% 2-tuple of {ContentType, BitArray} as set by the Gleam client. The record
%% tuples are accessed by index so this file does not need to include
%% gleam_http header records.

-module(mongreldb_ffi).

-export([send/1, base64_encode/1, start_mock_server/0, stop_mock_server/0,
         set_mock_response/2, last_mock_request/0]).

-define(MAX_RESPONSE_BYTES, 268435456).

%% `send/1` runs the given gleam/http request through httpc and returns a
%% gleam/http response, or an error tagged for the Gleam type `MongrelError`.
%%
%% The error tuples here MUST line up with the Gleam `MongrelError` variant
%% order as decoded by the caller. Gleam represents custom-type errors from
%% externals by variant index, so we emit:
%%   {error, {http, BinaryMsg}}        -> Http(String)
%%   {error, {response_too_large}}     -> ResponseTooLarge
%% The success path returns the gleam/http response tuple verbatim.
-spec send(tuple()) -> {ok, tuple()} | {error, term()}.
send(Req) ->
    %% Ensure inets/httpc are available. inets:start/0 is idempotent.
    ok = maybe_start_inets(),
    %% gleam/http 3.6.0 Request record:
    %%   {request, Method, Headers, Body, Scheme, Host, Port, Path, Query}
    MethodAtom = erlang:element(2, Req),
    HeadersList = erlang:element(3, Req),
    %% HeadersList is a list of {Name, Value} binaries already; pass through
    %% unchanged (httpc accepts {string|binary, string|binary} header tuples).
    %% The Gleam client sets the body to a plain BitArray (empty <<>> when
    %% there is no body); the content type travels in the headers instead.
    BodyBytes = erlang:element(4, Req),
    Scheme = erlang:element(5, Req),
    Host = erlang:element(6, Req),
    Port = erlang:element(7, Req),
    Path = erlang:element(8, Req),
    Query = erlang:element(9, Req),
    Url = build_url(Scheme, Host, Port, Path, Query),
    Headers = [{normalize_header_name(K), V} || {K, V} <- HeadersList],
    HttpOpts = [
        {timeout, 30000},
        %% Disable automatic redirect-following; the Gleam client maps 3xx to
        %% a transport error category.
        {autoredirect, false},
        {relaxed, true}
    ],
    Opts = [{body_format, binary}, {full_result, true}],
    HttpcMethod = method_to_atom(MethodAtom),
    %% httpc rejects an empty body in the 4-tuple request form, so GET/DELETE
    %% (no body) use the 2-tuple {Url, Headers} form.
    RequestTuple = case byte_size(BodyBytes) of
        0 -> {Url, Headers};
        _ -> {Url, Headers, "application/json", BodyBytes}
    end,
    Result = httpc:request(HttpcMethod, RequestTuple, HttpOpts, Opts),
    case Result of
        {ok, {{_Ver, Status, _Reason}, RespHeaders, RespBody}} ->
            case byte_size(RespBody) > ?MAX_RESPONSE_BYTES of
                true ->
                    {error, response_too_large};
                false ->
                    Normalized = [{list_to_binary(string:lowercase(K)), list_to_binary(V)} || {K, V} <- RespHeaders],
                    %% gleam/http response record: {response, Status, Headers, Body}
                    Response = {response, Status, Normalized, RespBody},
                    {ok, Response}
            end;
        {error, Reason} ->
            Msg = unicode:characters_to_binary(io_lib:format("~p", [Reason])),
            {error, {http, Msg}}
    end.

%% `build_url/5` reconstructs the request URL string from the gleam/http Request
%% components (Scheme, Host, Port, Path, Query). Port is {some, Int} | none;
%% Query is {some, String} | none; Scheme/Host/Path are atoms/strings/binary as
%% encoded by gleam.
-spec build_url(term(), term(), term(), term(), term()) -> string().
build_url(Scheme, Host, Port, Path, Query) ->
    SchemeStr = to_latin1_string(Scheme),
    HostStr = to_latin1_string(Host),
    PortStr = case Port of
        {some, PortNum} when PortNum =/= 80, PortNum =/= 443 ->
            ":" ++ erlang:integer_to_list(PortNum);
        _ ->
            ""
    end,
    RawPath = to_latin1_string(Path),
    PathStr = case RawPath of
        "" -> "/";
        _ -> RawPath
    end,
    QueryStr = case Query of
        {some, Q} -> "?" ++ to_latin1_string(Q);
        _ -> ""
    end,
    SchemeStr ++ "://" ++ HostStr ++ PortStr ++ PathStr ++ QueryStr.

%% `to_latin1_string/1` coerces a gleam-encoded scheme/host/path value (atom,
%% binary, or list) into the latin1 string httpc expects.
-spec to_latin1_string(term()) -> string().
to_latin1_string(V) when is_binary(V) -> erlang:binary_to_list(V);
to_latin1_string(V) when is_atom(V) -> erlang:atom_to_list(V);
to_latin1_string(V) when is_list(V) -> V.

%% `normalize_header_name/1` lowercases a header name for httpc. Accepts binary
%% or list header names (gleam emits binaries).
-spec normalize_header_name(term()) -> string().
normalize_header_name(K) when is_binary(K) ->
    string:lowercase(erlang:binary_to_list(K));
normalize_header_name(K) when is_list(K) ->
    string:lowercase(K).

%% `base64_encode/1` base64-encodes a string for HTTP Basic auth credentials.
-spec base64_encode(binary()) -> binary().
base64_encode(Input) ->
    base64:encode(Input).

%% `method_to_atom/1` converts a gleam/http Method to the lowercased atom
%% httpc:request/4 expects.
method_to_atom(connect) -> connect;
method_to_atom(delete) -> delete;
method_to_atom(get) -> get;
method_to_atom(head) -> head;
method_to_atom(options) -> options;
method_to_atom(patch) -> patch;
method_to_atom(post) -> post;
method_to_atom(put) -> put;
method_to_atom(trace) -> trace;
method_to_atom(other) -> get.

%% `maybe_start_inets/0` starts inets if it is not already running. Swallows the
%% `{error, {already_started, inets}}` return so repeated calls are safe.
-spec maybe_start_inets() -> ok.
maybe_start_inets() ->
    case inets:start() of
        ok -> ok;
        {error, {already_started, inets}} -> ok;
        _ -> ok
    end.

%% ── Mock TCP HTTP server (test-only) ──────────────────────────────────────
%%
%% A minimal HTTP/1.1 mock used by the Gleam transport tests. Listens on a
%% kernel-assigned port, records each incoming request (method, path, body)
%% to an ETS table, and responds with a canned status+body. The server
%% handles one request per accepted connection (Connection: close), which is
%% all the MongrelDB client needs for the retention transport tests.
%%
%% Uses only Erlang/OTP built-ins (gen_tcp, ets) - no new dependencies.
%%
%% The exported functions are: start_mock_server/0, stop_mock_server/0,
%% set_mock_response/2, and last_mock_request/0. The Gleam test module
%% reaches them via @external(erlang, "mongreldb_ffi", ...).

-define(MOCK_REQS, mongreldb_mock_reqs).
-define(MOCK_RESP, mongreldb_mock_resp).
-define(MOCK_SRV, mongreldb_mock_srv).

%% `start_mock_server/0` starts the mock on a kernel-assigned port. It is
%% idempotent: any previously-started mock is stopped first. Returns
%% `{ok, Port}` or `{error, Reason}`.
-spec start_mock_server() -> {ok, integer()} | {error, term()}.
start_mock_server() ->
    stop_mock_server(),
    ets:new(?MOCK_REQS, [named_table, public, ordered_set]),
    ets:new(?MOCK_RESP, [named_table, public, set]),
    ets:insert(?MOCK_RESP, {response, 200, <<"{}">>}),
    Parent = self(),
    Pid = spawn(fun() -> mock_init(Parent) end),
    receive
        {mock_started, Port} ->
            register(?MOCK_SRV, Pid),
            {ok, Port};
        {mock_failed, _Reason} ->
            {error, nil}
    after 5000 ->
            {error, nil}
    end.

%% `mock_init/1` runs in the spawned process so it owns the listening socket
%% (gen_tcp gives socket ownership to the caller). On success it signals the
%% parent with the assigned port and enters the accept loop.
mock_init(Parent) ->
    case gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {packet, raw}]) of
        {ok, ListenSock} ->
            {ok, Port} = inet:port(ListenSock),
            Parent ! {mock_started, Port},
            mock_loop(ListenSock);
        {error, Reason} ->
            Parent ! {mock_failed, Reason}
    end.

%% `mock_loop/1` accepts one connection at a time, handles the request, then
%% loops. Exits when the listening socket is closed (gen_tcp:accept returns
%% an error), which `stop_mock_server/0` triggers by killing the process
%% (Erlang closes owned sockets on process exit).
mock_loop(ListenSock) ->
    case gen_tcp:accept(ListenSock, 60000) of
        {ok, Sock} ->
            handle_mock_request(Sock),
            mock_loop(ListenSock);
        {error, timeout} ->
            mock_loop(ListenSock);
        {error, _Reason} ->
            ok
    end.

%% `handle_mock_request/1` reads the full request (looping until the
%% `\r\n\r\n` header terminator is seen), records it, and writes back the
%% canned response. The MongrelDB client sends small JSON payloads, so the
%% body is almost always delivered with the headers in the first read; the
%% loop only exists to be robust against a split delivery.
handle_mock_request(Sock) ->
    ReqBytes = read_full_request(Sock, <<>>),
    case ReqBytes of
        <<>> ->
            ok = gen_tcp:close(Sock);
        _ ->
            {Method, Path, Body} = parse_http(ReqBytes),
            ets:insert(?MOCK_REQS, {erlang:unique_integer([monotonic]), Method, Path, Body}),
            [{response, Status, RespBody}] = ets:lookup(?MOCK_RESP, response),
            Resp = build_response(Status, RespBody),
            gen_tcp:send(Sock, Resp),
            ok = gen_tcp:close(Sock)
    end.

%% `read_full_request/2` accumulates chunks until the `\r\n\r\n` header
%% terminator appears (so we know at least the head arrived) or the socket
%% closes.
read_full_request(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 10000) of
                {ok, Chunk} ->
                    read_full_request(Sock, <<Acc/binary, Chunk/binary>>);
                {error, _} ->
                    Acc
            end;
        _ ->
            Acc
    end.

%% `parse_http/1` extracts {Method, Path, Body} from the raw request bytes.
parse_http(Bytes) ->
    case binary:split(Bytes, <<"\r\n\r\n">>) of
        [Head, Body] ->
            ok;
        [Head] ->
            Body = <<>>
    end,
    [FirstLine | _] = binary:split(Head, <<"\r\n">>, [global]),
    case binary:split(FirstLine, <<" ">>, [global]) of
        [Method, Path, _Version] ->
            {Method, Path, Body};
        _ ->
            {<<"GET">>, <<"/">>, Body}
    end.

%% `build_response/2` formats a complete HTTP/1.1 response. Content-Length
%% and Connection: close guarantee the client's parser sees a complete
%% message and does not try to reuse the connection.
build_response(Status, Body) ->
    Reason = http_reason(Status),
    [
        <<"HTTP/1.1 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
        <<"Content-Type: application/json\r\n">>,
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n">>,
        <<"Connection: close\r\n\r\n">>,
        Body
    ].

http_reason(200) -> <<"OK">>;
http_reason(404) -> <<"Not Found">>;
http_reason(500) -> <<"Internal Server Error">>;
http_reason(_) -> <<"Error">>.

%% `stop_mock_server/0` kills the accept loop (which closes the listening
%% socket and any in-flight connection) and deletes the ETS tables. Waits
%% for the process to die before deleting ETS so the handler cannot insert
%% into a table that has just been removed.
-spec stop_mock_server() -> ok.
stop_mock_server() ->
    case whereis(?MOCK_SRV) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 1000 -> ok
            end
    end,
    try ets:delete(?MOCK_REQS)
    catch _:_ -> ok
    end,
    try ets:delete(?MOCK_RESP)
    catch _:_ -> ok
    end,
    ok.

%% `set_mock_response/2` configures the canned status+body the mock will
%% emit for subsequent requests.
-spec set_mock_response(integer(), binary()) -> ok.
set_mock_response(Status, Body) ->
    ets:insert(?MOCK_RESP, {response, Status, Body}),
    ok.

%% `last_mock_request/0` returns the most recently recorded request as
%% `{ok, {Method, Path, Body}}` (binaries), or `{error, nil}` if no request
%% has been recorded yet.
-spec last_mock_request() -> {ok, {binary(), binary(), binary()}} | {error, nil}.
last_mock_request() ->
    case ets:last(?MOCK_REQS) of
        '$end_of_table' ->
            {error, nil};
        Key ->
            [{_, Method, Path, Body}] = ets:lookup(?MOCK_REQS, Key),
            {ok, {Method, Path, Body}}
    end.
