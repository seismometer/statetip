%%%---------------------------------------------------------------------------
%%% @doc
%%%   Data types and functions for stored values.
%%%
%%% @todo `-include("statip_value.hrl").'
%%% @see statip_keeper
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value).

%% general-purpose interface
-export([timestamp/0]).
%% value serialization and deserialization
-export([to_struct/3, to_struct/4, from_struct/1, to_json/3, from_json/1]).
%% data access interface
-export([add/4, restore/4]).
-export([delete/1, delete/2, delete/3]).
-export([list_names/0, list_origins/1]).
-export([list_keys/2, list_values/2, get_value/3]).

-export_type([name/0, origin/0, key/0]).
-export_type([state/0, severity/0, info/0]).
-export_type([timestamp/0, expiry/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-include("statip_value.hrl").

-type name() :: binary().
%% Value group name.

-type origin() :: binary() | undefined.
%% Value group's origin.

-type key() :: binary().
%% Value's key, which identifies a particular value in a value group of
%% specific origin.

-type state() :: binary() | undefined.
%% State of a monitored object recorded in the value.

-type severity() :: expected | warning | error.
%% Value's severity.

-type info() :: statip_json:struct().
%% Additional data associated with the value.

-type timestamp() :: integer().
%% Time (unix timestamp) when the value was collected.

-type expiry() :: pos_integer().
%% Number of seconds after {@type timestamp()} when the value is valid. After
%% this time, the value is deleted.

%%% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% data access interface
%%%---------------------------------------------------------------------------

%% @doc Restore a value group keeper after application reboot.

-spec restore(name(), origin(), [#value{}], related | unrelated) ->
  ok | {error, exists}.

restore(GroupName, GroupOrigin, Values, GroupType) ->
  case start_keeper(GroupName, GroupOrigin, GroupType) of
    {Pid, Module} -> Module:restore(Pid, Values);
    none -> {error, exists}
  end.

%% @doc Remember a value.
%%
%%   If a value's type ("related" or "unrelated") doesn't match the type of
%%   value group, the value is ignored.

-spec add(name(), origin(), #value{}, related | unrelated) ->
  ok.

add(GroupName, GroupOrigin, Value = #value{key = Key, sort_key = undefined},
    GroupType) ->
  NewValue = Value#value{sort_key = Key},
  add(GroupName, GroupOrigin, NewValue, GroupType);
add(GroupName, GroupOrigin, Value, GroupType) ->
  case get_keeper(GroupName, GroupOrigin, GroupType) of
    {Pid, Module} -> Module:add(Pid, Value);
    none -> ok
  end.

%% @doc Delete whole value group.

-spec delete(name()) ->
  ok.

delete(GroupName) ->
  lists:foreach(fun(GroupOrigin) -> delete(GroupName, GroupOrigin) end,
                statip_registry:list_origins(GroupName)),
  ok.

%% @doc Delete all values from value group of specifc origin.

-spec delete(name(), origin()) ->
  ok.

delete(GroupName, GroupOrigin) ->
  for_keeper(GroupName, GroupOrigin,
             fun(Pid, Module) -> Module:shutdown(Pid) end),
  ok.

%% @doc Delete a value.

-spec delete(name(), origin(), key()) ->
  ok.

delete(GroupName, GroupOrigin, Key) ->
  for_keeper(GroupName, GroupOrigin,
             fun(Pid, Module) -> Module:delete(Pid, Key) end),
  ok.

%% @doc List names of value groups.

-spec list_names() ->
  [name()].

list_names() ->
  statip_registry:list_names().

%% @doc List all origins in a value group.

-spec list_origins(name()) ->
  [origin()].

list_origins(GroupName) ->
  lists:sort(statip_registry:list_origins(GroupName)).

%% @doc List the keys in an origin of a value group.

-spec list_keys(name(), origin()) ->
  [key()].

list_keys(GroupName, GroupOrigin) ->
  ListKeysFun = fun(Pid, Module) -> Module:list_keys(Pid) end,
  case for_keeper(GroupName, GroupOrigin, ListKeysFun) of
    Result when is_list(Result) -> Result;
    none -> []
  end.

%% @doc List the values from specific origin in a value group.

-spec list_values(name(), origin()) ->
  [#value{}].

list_values(GroupName, GroupOrigin) ->
  ListValuesFun = fun(Pid, Module) -> Module:list_values(Pid) end,
  case for_keeper(GroupName, GroupOrigin, ListValuesFun) of
    Result when is_list(Result) -> Result;
    none -> []
  end.

%% @doc Get a specific value.

-spec get_value(name(), origin(), key()) ->
  #value{} | none.

get_value(GroupName, GroupOrigin, Key) ->
  for_keeper(GroupName, GroupOrigin,
             fun(Pid, Module) -> Module:get_value(Pid, Key) end).

%%----------------------------------------------------------
%% helpers
%%----------------------------------------------------------

%% @doc Run an operation for a keeper process.
%%
%%   `Operation' receives a pid of a keeper and its communication module as
%%   its arguments.
%%
%%   If no keeper process was found, `Operation' is not called and `none' is
%%   returned. If an error from {@link gen_server:call/2} is detected (namely,
%%   `noproc' error), `none' is returned as well. If `Operation' returned
%%   successfully, its return value is returned.

-spec for_keeper(name(), origin(), fun((pid(), module()) -> Result)) ->
  Result | none.

for_keeper(GroupName, GroupOrigin, Operation) ->
  case statip_registry:find_process(GroupName, GroupOrigin) of
    {Pid, Module} ->
      try
        Operation(Pid, Module)
      catch
        exit:{noproc, {gen_server, call, _Args}} -> none
      end;
    none ->
      none
  end.

%% @doc Get a keeper process (possibly starting it) and its communication
%%   module.
%%
%%   This function tries first to find an already started keeper process. If
%%   no keeper is started, it tries to start one and use that. If starting
%%   failed, it means somebody else already started one, so the function tries
%%   to find and use that one instead. If all that fails, function gives up
%%   and returns `none'.
%%
%%   If the value group's type expected and running are mismatched (incoming
%%   "related" value while "unrelated" keeper is running or the reverse),
%%   function returns `none'.

-spec get_keeper(name(), origin(), related | unrelated) ->
  {pid(), module()} | none.

get_keeper(GroupName, GroupOrigin, GroupType) ->
  case try_get_keeper(GroupName, GroupOrigin, GroupType) of
    {Pid, Module} ->
      {Pid, Module};
    mismatch ->
      none;
    none ->
      case start_keeper(GroupName, GroupOrigin, GroupType) of
        {Pid, Module} ->
          {Pid, Module};
        none ->
          case try_get_keeper(GroupName, GroupOrigin, GroupType) of
            {Pid, Module} ->
              {Pid, Module};
            mismatch ->
              none;
            none ->
              statip_log:warn(value,
                "couldn't start a value group keeper: race condition occurred",
                log_context(GroupName, GroupOrigin, GroupType)
              ),
              none
          end
      end
  end.

-spec try_get_keeper(name(), origin(), related | unrelated) ->
  {pid(), module()} | mismatch | none.

try_get_keeper(GroupName, GroupOrigin, GroupType) ->
  case statip_registry:find_process(GroupName, GroupOrigin) of
    {Pid, statip_keeper_related = Module} when GroupType == related ->
      {Pid, Module};
    {Pid, statip_keeper_unrelated = Module} when GroupType == unrelated ->
      {Pid, Module};
    {_Pid, _Module} ->
      % incoming value type and registered value type don't match
      mismatch;
    none ->
      none
  end.

log_context(GroupName, GroupOrigin, GroupType) when is_binary(GroupOrigin) ->
  _Context = [
    {group_name, GroupName}, {group_origin, GroupOrigin},
    {group_type, GroupType}
  ];
log_context(GroupName, undefined = _GroupOrigin, GroupType) ->
  _Context = [
    {group_name, GroupName}, {group_origin, null},
    {group_type, GroupType}
  ].

%% @doc Start a new value group keeper process, depending on value group's
%%   type.

-spec start_keeper(name(), origin(), related | unrelated) ->
  {pid(), module()} | none.

start_keeper(GroupName, GroupOrigin, related = _GroupType) ->
  case statip_keeper_related:spawn_keeper(GroupName, GroupOrigin) of
    {ok, Pid} when is_pid(Pid) -> {Pid, statip_keeper_related};
    {ok, undefined} -> none
  end;
start_keeper(GroupName, GroupOrigin, unrelated = _GroupType) ->
  case statip_keeper_unrelated:spawn_keeper(GroupName, GroupOrigin) of
    {ok, Pid} when is_pid(Pid) -> {Pid, statip_keeper_unrelated};
    {ok, undefined} -> none
  end.

%%%---------------------------------------------------------------------------
%%% value serialization and deserialization
%%%---------------------------------------------------------------------------

%% @doc Encode a value to a JSON-serializable structure.
%%
%%   <i>NOTE</i>: Only a most commonly used portion of `Value' will be
%%   encoded. To encode each and every detail, see {@link to_struct/4}.
%%
%% @see to_struct/4
%% @see statip_json
%% @see from_struct/1
%% @see from_json/1
%% @see to_json/3

-spec to_struct(name(), origin(), #value{}) ->
  statip_json:struct().

to_struct(GroupName, GroupOrigin, Value = #value{}) ->
  to_struct(GroupName, GroupOrigin, Value, []).

%% @doc Encode a value to a JSON-serializable structure.
%%
%%   By default, only most commonly used fields of {@type #value@{@}} (key,
%%   state, severity, info) will be encoded. To include them all, specify
%%   `full' as an option.
%%
%% @see to_struct/4
%% @see statip_json
%% @see from_struct/1
%% @see from_json/1
%% @see to_json/3

-spec to_struct(name(), origin(), #value{}, Options :: [Option]) ->
  statip_json:struct()
  when Option :: full.

to_struct(GroupName, GroupOrigin, Value, Options) ->
  Details = case proplists:get_bool(full, Options) of
    true -> [
      {sort_key, undef_null(Value#value.sort_key)},
      {created,  Value#value.created},
      {expires,  Value#value.expires}
    ];
    false -> []
  end,
  _Result = [
    {name, GroupName},
    {origin, undef_null(GroupOrigin)},
    {key,      Value#value.key},
    {state,    undef_null(Value#value.state)},
    {severity, Value#value.severity},
    {info,     Value#value.info} |
    Details
  ].

undef_null(undefined = _Value) -> null;
undef_null(Value) -> Value.

%% @doc Decode a JSON-serializable struct to a value.
%%
%% @see statip_json
%% @see to_struct/3
%% @see from_json/1
%% @see to_json/3

-spec from_struct(statip_json:struct()) ->
  {name(), origin(), #value{}}.

from_struct(Struct) ->
  [{created,   Created},
    {expires,  Expires},
    {info,     Info},
    {key,      Key},
    {name,     GroupName},
    {origin,   GroupOrigin},
    {severity, Severity},
    {sort_key, SortKey},
    {state,    State}] = lists:sort(filter_fields(Struct)),
  true = is_integer(Created),
  true = is_integer(Expires),
  % no test for `Info'
  true = is_binary(Key),
  true = is_binary(GroupName),
  true = is_binary(GroupOrigin) orelse GroupOrigin == null,
  true = (Severity == <<"expected">> orelse
          Severity == <<"warning">> orelse
          Severity == <<"error">>),
  true = is_binary(SortKey) orelse SortKey == null,
  true = is_binary(State) orelse State == null,
  Value = #value{
    key      = Key,
    sort_key = null_undef(SortKey),
    state    = null_undef(State),
    severity = binary_to_atom(Severity, utf8),
    info     = Info,
    created  = Created,
    expires  = Expires
  },
  {GroupName, null_undef(GroupOrigin), Value}.

null_undef(null = _Value) -> undefined;
null_undef(Value) -> Value.

filter_fields([{<<"related">>,  V} | Rest]) -> [{related,  V} | filter_fields(Rest)];
filter_fields([{<<"name">>,     V} | Rest]) -> [{name,     V} | filter_fields(Rest)];
filter_fields([{<<"origin">>,   V} | Rest]) -> [{origin,   V} | filter_fields(Rest)];
filter_fields([{<<"key">>,      V} | Rest]) -> [{key,      V} | filter_fields(Rest)];
filter_fields([{<<"sort_key">>, V} | Rest]) -> [{sort_key, V} | filter_fields(Rest)];
filter_fields([{<<"state">>,    V} | Rest]) -> [{state,    V} | filter_fields(Rest)];
filter_fields([{<<"severity">>, V} | Rest]) -> [{severity, V} | filter_fields(Rest)];
filter_fields([{<<"info">>,     V} | Rest]) -> [{info,     V} | filter_fields(Rest)];
filter_fields([{<<"created">>,  V} | Rest]) -> [{created,  V} | filter_fields(Rest)];
filter_fields([{<<"expires">>,  V} | Rest]) -> [{expires,  V} | filter_fields(Rest)];
filter_fields([{_, _} | Rest]) -> filter_fields(Rest);
filter_fields([]) -> [].

%% @doc Encode a value to JSON string.
%%
%% @see statip_json
%% @see from_json/1
%% @see from_struct/1
%% @see to_struct/3

-spec to_json(name(), origin(), #value{}) ->
  {ok, statip_json:json_string()} | {error, badarg}.

to_json(GroupName, GroupOrigin, Value = #value{}) ->
  Struct = to_struct(GroupName, GroupOrigin, Value),
  statip_json:encode(Struct).

%% @doc Decode a JSON string to a value.
%%
%% @see statip_json
%% @see to_json/3
%% @see from_struct/1
%% @see to_struct/3

-spec from_json(statip_json:json_string()) ->
  {ok, {name(), origin(), #value{}} } | {error, badarg}.

from_json(JSON) ->
  case statip_json:decode(JSON) of
    {ok, Struct} ->
      try
        from_struct(Struct)
      catch
        error:_ -> {error, badarg}
      end;
    {error, badarg} ->
      {error, badarg}
  end.

%%%---------------------------------------------------------------------------
%%% general-purpose interface
%%%---------------------------------------------------------------------------

%% @doc Return current time as a unix timestamp.

-spec timestamp() ->
  timestamp().

timestamp() ->
  {MS,S,_US} = os:timestamp(),
  MS * 1000 * 1000 + S.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
