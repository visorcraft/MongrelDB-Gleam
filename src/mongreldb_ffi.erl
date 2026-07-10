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
%% The gleam/http record shapes are kept stable across versions:
%%   request(Method, Url, Scheme, Host, Headers, Body)
%%   response(Status, Headers, Body)
%% where Headers is a gleam@dict:dict_ and Body is a 2-tuple of {ContentType,
%% BitArray}. The record tuples are built by tuple index so this file does not
%% need to include gleam_http header records.

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
    %% gleam/http request record: {request, Method, Url, Scheme, Host, Headers, Body}
    MethodAtom = erlang:element(2, Req),
    Url = erlang:binary_to_list(erlang:element(3, Req)),
    HeadersMap = erlang:element(6, Req),
    Headers0 = maps:to_list(HeadersMap),
    Headers = [{string:lowercase(erlang:atom_to_binary(K, utf8)), V} || {K, V} <- Headers0],
    %% Body is {ContentType, BitArray}; pass the raw bytes through.
    {_ContentType, BodyBytes} = erlang:element(7, Req),
    HttpOpts = [
        {timeout, 30000},
        %% Disable automatic redirect-following; the Gleam client maps 3xx to
        %% a transport error category.
        {autoredirect, false},
        {relaxed, true}
    ],
    Opts = [{body_format, binary}, {full_result, true}],
    HttpcMethod = method_to_atom(MethodAtom),
    Result = httpc:request(HttpcMethod, {Url, Headers, "application/json", BodyBytes}, HttpOpts, Opts),
    case Result of
        {ok, {{_Ver, Status, _Reason}, RespHeaders, RespBody}} ->
            case byte_size(RespBody) > ?MAX_RESPONSE_BYTES of
                true ->
                    {error, response_too_large};
                false ->
                    Normalized = [{list_to_binary(string:lowercase(K)), list_to_binary(V)} || {K, V} <- RespHeaders],
                    %% gleam/http response record: {response, Status, BodySize, Headers, Body}
                    Response = {response, Status, {some, byte_size(RespBody)}, maps:from_list(Normalized), RespBody},
                    {ok, Response}
            end;
        {error, Reason} ->
            Msg = unicode:characters_to_binary(io_lib:format("~p", [Reason])),
            {error, {http, Msg}}
    end.

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
