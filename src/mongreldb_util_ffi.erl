%% mongreldb_util_ffi - small Erlang FFI helpers shared by the Gleam examples
%% and the live test suite.
%%
%% Provides:
%%   - `unique_suffix/0`: a process-unique string for per-run table names.
%%   - `getenv_str/1`: read an env var, returning "" when unset (Erlang's
%%     `os:getenv/1` returns the atom `false` when the var is missing, which
%%     has no direct Gleam equivalent).

-module(mongreldb_util_ffi).

-export([unique_suffix/0, getenv_str/1]).

-spec unique_suffix() -> binary().
unique_suffix() ->
    Ts = erlang:system_time(millisecond),
    Unique = erlang:unique_integer([positive]),
    Msg = io_lib:format("~p_~p", [Ts, Unique]),
    unicode:characters_to_binary(Msg).

-spec getenv_str(string()) -> binary().
getenv_str(Name) ->
    case os:getenv(Name) of
        false -> <<"">>;
        Value -> unicode:characters_to_binary(Value)
    end.
