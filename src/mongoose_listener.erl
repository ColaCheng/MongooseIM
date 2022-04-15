%% @doc Manage starting and stopping of configured listeners

-module(mongoose_listener).

%% Only for tests
-export([start_listener/1, stop_listener/1]).
-ignore_xref([start_listener/1, stop_listener/1]).

%% API
-export([start/0, stop/0, socket_type/1]).

-callback start_listener(options()) -> ok.
-callback socket_type() -> socket_type().

-type options() :: #{port := inet:port_number(),
                     ip_tuple := inet:ip_address(),
                     ip_address := string(),
                     ip_version := 4 | 6,
                     proto := proto(),
                     any() => any()}.
-type id() :: {inet:port_number(), inet:ip_address(), proto()}.
-type proto() :: tcp | udp.
-type socket_type() :: independent | xml_stream | raw.

-export_type([options/0, id/0, proto/0, socket_type/0]).

%% API

start() ->
    Listeners = mongoose_config:get_opt(listen),
    Modules = lists:usort([Module || #{module := Module} <- Listeners]),
    [start_module_supervisor(Module) || Module <- Modules],
    [start_listener(Listener) || Listener <- Listeners],
    ok.

stop() ->
    Listeners = mongoose_config:get_opt(listen),
    Modules = lists:usort([Module || #{module := Module} <- Listeners]),
    [stop_listener(Listener) || Listener <- Listeners],
    [stop_module_supervisor(Module) || Module <- Modules],
    ok.

-spec socket_type(module()) -> any().
socket_type(Module) ->
    Module:socket_type().

%% Internal functions

start_module_supervisor(Module) ->
    supervisor:start_child(ejabberd_sup, module_supervisor_child_spec(Module)).

stop_module_supervisor(Module) ->
    SupervisorId = module_supervisor_id(Module),
    supervisor:terminate_child(ejabberd_sup, SupervisorId),
    supervisor:delete_child(ejabberd_sup, SupervisorId).

module_supervisor_id(Module) ->
    gen_mod:get_module_proc("sup", Module).

module_supervisor_child_spec(Module) ->
    SupervisorId = module_supervisor_id(Module),
    #{id => SupervisorId,
      start => {ejabberd_tmp_sup, start_link, [SupervisorId, Module]},
      shutdown => infinity,
      type => supervisor,
      modules => [ejabberd_tmp_sup]}.

start_listener(Opts = #{module := Module}) ->
    Module:start_listener(Opts).

stop_listener(Opts) ->
    ListenerId = mongoose_listener_config:listener_id(Opts),
    supervisor:terminate_child(mongoose_listener_sup, ListenerId),
    supervisor:delete_child(mongoose_listener_sup, ListenerId).
