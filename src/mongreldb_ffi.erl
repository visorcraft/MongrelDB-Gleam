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

-export([send/1, base64_encode/1]).

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
