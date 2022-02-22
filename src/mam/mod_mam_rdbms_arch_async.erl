-module(mod_mam_rdbms_arch_async).

-behaviour(mongoose_batch_worker).

-include("mongoose_logger.hrl").

-define(PM_PER_MESSAGE_FLUSH_TIME, [mod_mam_rdbms_async_pool_writer, per_message_flush_time]).
-define(PM_FLUSH_TIME, [mod_mam_rdbms_async_pool_writer, flush_time]).

-define(MUC_MODULE, mod_mam_muc_rdbms_arch_async).
-define(MUC_PER_MESSAGE_FLUSH_TIME, [mod_mam_muc_rdbms_async_pool_writer, per_message_flush_time]).
-define(MUC_FLUSH_TIME, [mod_mam_muc_rdbms_async_pool_writer, flush_time]).

-behaviour(gen_mod).
-export([start/2, stop/1, config_spec/0, supported_features/0]).

-export([archive_pm_message/3, archive_muc_message/3]).
-export([mam_archive_sync/2, mam_muc_archive_sync/2]).
-export([flush/2]).

-type writer_type() :: pm | muc.

-ignore_xref([archive_pm_message/3, archive_muc_message/3]).
-ignore_xref([mam_archive_sync/2, mam_muc_archive_sync/2]).

-spec archive_pm_message(_Result, mongooseim:host_type(), mod_mam:archive_message_params()) -> ok.
archive_pm_message(_Result, HostType, Params = #{archive_id := ArcID}) ->
    mongoose_async_pools:put_task(HostType, pm_mam, ArcID, Params).

-spec archive_muc_message(_Result, mongooseim:host_type(), mod_mam:archive_message_params()) -> ok.
archive_muc_message(_Result, HostType, Params0 = #{archive_id := RoomID}) ->
    Params = mod_mam_muc_rdbms_arch:extend_params_with_sender_id(HostType, Params0),
    mongoose_async_pools:put_task(HostType, muc_mam, RoomID, Params).

-spec mam_archive_sync(term(), mongooseim:host_type()) -> term().
mam_archive_sync(Result, HostType) ->
    mongoose_async_pools:sync(HostType, pm_mam),
    Result.

-spec mam_muc_archive_sync(term(), mongooseim:host_type()) -> term().
mam_muc_archive_sync(Result, HostType) ->
    mongoose_async_pools:sync(HostType, muc_mam),
    Result.

%%% gen_mod callbacks
-spec start(mongooseim:host_type(), gen_mod:module_opts()) -> any().
start(HostType, Opts) ->
    [ start_pool(HostType, Mod) || Mod <- maps:to_list(Opts) ].

-spec stop(mongooseim:host_type()) -> any().
stop(HostType) ->
    Opts = gen_mod:get_loaded_module_opts(HostType, ?MODULE),
    [ stop_pool(HostType, Mod) || Mod <- maps:to_list(Opts) ].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    mongoose_async_pools:config_spec().

-spec supported_features() -> [atom()].
supported_features() ->
    [dynamic_domains].

%%% internal callbacks
-spec start_pool(mongooseim:host_type(), {writer_type(), gen_mod:module_opts()}) ->
    supervisor:startchild_ret().
start_pool(HostType, {Type, Opts}) ->
    {PoolOpts, Extra} = make_pool_opts(Type, Opts),
    prepare_insert_queries(Type, Extra),
    ensure_metrics(Type, HostType),
    register_hooks(Type, HostType),
    start_pool(Type, HostType, PoolOpts).

-spec make_pool_opts(writer_type(), gen_mod:module_opts()) ->
          {mongoose_async_pools:pool_opts(), mongoose_async_pools:pool_extra()}.
make_pool_opts(Type, Opts) ->
    Extra = add_batch_name(Type, Opts),
    PoolOpts = Extra#{pool_type => batch,
                      flush_callback => flush_callback(Type),
                      flush_extra => Extra},
    {PoolOpts, Extra}.

%% Put batch_size into a statement name, so we could survive the module restarts
%% with different batch sizes
add_batch_name(pm, #{batch_size := MaxSize} = Opts) ->
    Opts#{batch_name => multi_name(insert_mam_messages, MaxSize)};
add_batch_name(muc, #{batch_size := MaxSize} = Opts) ->
    Opts#{batch_name => multi_name(insert_mam_muc_messages, MaxSize)}.

flush_callback(pm) -> fun ?MODULE:flush/2;
flush_callback(muc) -> fun ?MUC_MODULE:flush/2.

prepare_insert_queries(pm, #{batch_size := MaxSize, batch_name := BatchName}) ->
    mod_mam_rdbms_arch:prepare_insert(insert_mam_message, 1),
    mod_mam_rdbms_arch:prepare_insert(BatchName, MaxSize);
prepare_insert_queries(muc, #{batch_size := MaxSize, batch_name := BatchName}) ->
    mod_mam_muc_rdbms_arch:prepare_insert(insert_mam_muc_message, 1),
    mod_mam_muc_rdbms_arch:prepare_insert(BatchName, MaxSize).

multi_name(Name, Times) ->
    list_to_atom(atom_to_list(Name) ++ integer_to_list(Times)).

ensure_metrics(pm, HostType) ->
    mongoose_metrics:ensure_metric(HostType, ?PM_PER_MESSAGE_FLUSH_TIME, histogram),
    mongoose_metrics:ensure_metric(HostType, ?PM_FLUSH_TIME, histogram);
ensure_metrics(muc, HostType) ->
    mongoose_metrics:ensure_metric(HostType, ?MUC_PER_MESSAGE_FLUSH_TIME, histogram),
    mongoose_metrics:ensure_metric(HostType, ?MUC_FLUSH_TIME, histogram).

register_hooks(pm, HostType) ->
    ejabberd_hooks:add(mam_archive_sync, HostType, ?MODULE, mam_archive_sync, 50),
    ejabberd_hooks:add(mam_archive_message, HostType, ?MODULE, archive_pm_message, 50);
register_hooks(muc, HostType) ->
    ejabberd_hooks:add(mam_muc_archive_sync, HostType, ?MUC_MODULE, mam_muc_archive_sync, 50),
    ejabberd_hooks:add(mam_muc_archive_message, HostType, ?MUC_MODULE, archive_muc_message, 50).

-spec start_pool(writer_type(), mongooseim:host_type(), mongoose_async_pools:pool_opts()) -> term().
start_pool(pm, HostType, Opts) ->
    mongoose_async_pools:start_pool(HostType, pm_mam, Opts);
start_pool(muc, HostType, Opts) ->
    mongoose_async_pools:start_pool(HostType, muc_mam, Opts).

-spec stop_pool(mongooseim:host_type(), {writer_type(), term()}) -> ok.
stop_pool(HostType, {pm, _}) ->
    ejabberd_hooks:delete(mam_archive_message, HostType, ?MODULE, archive_pm_message, 50),
    ejabberd_hooks:delete(mam_archive_sync, HostType, ?MODULE, mam_archive_sync, 50),
    mongoose_async_pools:stop_pool(HostType, pm_mam);
stop_pool(HostType, {muc, _}) ->
    ejabberd_hooks:delete(mam_muc_archive_sync, HostType, ?MUC_MODULE, mam_muc_archive_sync, 50),
    ejabberd_hooks:delete(mam_muc_archive_message, HostType, ?MUC_MODULE, archive_muc_message, 50),
    mongoose_async_pools:stop_pool(HostType, muc_mam).

%%% flush callbacks
flush(Acc, Extra = #{host_type := HostType, queue_length := MessageCount}) ->
    {FlushTime, Result} = timer:tc(fun do_flush_pm/2, [Acc, Extra]),
    mongoose_metrics:update(HostType, ?PM_PER_MESSAGE_FLUSH_TIME, round(FlushTime / MessageCount)),
    mongoose_metrics:update(HostType, ?PM_FLUSH_TIME, FlushTime),
    Result.

%% mam workers callbacks
do_flush_pm(Acc, #{host_type := HostType, queue_length := MessageCount,
                   batch_size := MaxSize, batch_name := BatchName}) ->
    Rows = [mod_mam_rdbms_arch:prepare_message(HostType, Params) || Params <- Acc],
    InsertResult =
        case MessageCount of
            MaxSize ->
                mongoose_rdbms:execute(HostType, BatchName, lists:append(Rows));
            OtherSize ->
                Results = [mongoose_rdbms:execute(HostType, insert_mam_message, Row) || Row <- Rows],
                case lists:keyfind(error, 1, Results) of
                    false -> {updated, OtherSize};
                    Error -> Error
                end
        end,
    case InsertResult of
        {updated, _Count} -> ok;
        {error, Reason} ->
            mongoose_metrics:update(HostType, modMamDropped, MessageCount),
            ?LOG_ERROR(#{what => archive_message_failed,
                         text => <<"archive_message query failed">>,
                         message_count => MessageCount, reason => Reason}),
            ok
    end,
    [mod_mam_rdbms_arch:retract_message(HostType, Params) || Params <- Acc],
    mongoose_hooks:mam_flush_messages(HostType, MessageCount),
    ok.
