%% Session Management tests
-module(sm_SUITE).

-export([suite/0,
         all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

%% parallel group
-export([server_announces_sm/1,
         server_enables_sm_before_session/1,
         server_enables_sm_after_session/1,
         server_returns_failed_after_start/1,
         server_returns_failed_after_auth/1,
         server_enables_resumption/1,
         client_enables_sm_twice_fails_with_correct_error_stanza/1,
         session_resumed_then_old_session_is_closed_gracefully_with_correct_error_stanza/1,
         session_resumed_and_old_session_dead_doesnt_route_error_to_new_session/1,
         basic_ack/1,
         h_ok_before_session/1,
         h_ok_after_session_enabled_before_session/1,
         h_ok_after_session_enabled_after_session/1,
         h_ok_after_a_chat/1,
         h_non_given_closes_stream_gracefully/1,
         resend_unacked_on_reconnection/1,
         session_established/1,
         wait_for_resumption/1,
         resume_session/1,
         resume_session_with_wrong_h_does_not_leak_sessions/1,
         resume_session_with_wrong_sid_returns_item_not_found/1,
         resume_session_with_wrong_namespace_is_a_noop/1,
         resume_dead_session_results_in_item_not_found/1,
         resume_session_kills_old_C2S_gracefully/1,
         aggressively_pipelined_resume/1,
         replies_are_processed_by_resumed_session/1,
         subscription_requests_are_buffered_properly/1,
         messages_are_properly_flushed_during_resumption/1,
         messages_are_properly_flushed_during_resumption_p1_fsm_old/1]).

%% manual_ack_freq_2 group
-export([server_requests_ack_freq_2/1]).

-export([client_acks_more_than_sent/1,
         too_many_unacked_stanzas/1,
         resend_unacked_after_resume_timeout/1,
         resume_session_state_send_message/1,
         resume_session_state_stop_c2s/1,
         server_requests_ack_after_session/1,
         resend_more_offline_messages_than_buffer_size/1,
         server_requests_ack/1]).

%% stale_h group
-export([resume_expired_session_returns_correct_h/1,
         gc_repeat_after_never_means_no_cleaning/1,
         gc_repeat_after_timeout_does_clean/1]).

%% stream_mgmt_disabled group
-export([no_crash_if_stream_mgmt_disabled_but_client_requests_stream_mgmt/1,
         no_crash_if_stream_mgmt_disabled_but_client_requests_stream_mgmt_with_resumption/1]).

%% manual_ack_freq_long_session_timeout group
-export([preserve_order/1]).

%% unacknowledged_message_hook group
-export([unacknowledged_message_hook_bounce/1,
         unacknowledged_message_hook_offline/1,
         unacknowledged_message_hook_resume/1]).

%% Injected code callbacks
-export([rpc_start_hook_handler/3,
         rpc_stop_hook_handler/2,
         hook_handler_fn/3,
         regression_handler/5]).

-include_lib("exml/include/exml.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").

-define(MOD_SM, mod_stream_management).
-define(CONSTRAINT_CHECK_TIMEOUT, 5000).

-import(distributed_helper, [mim/0,
                             require_rpc_nodes/1,
                             rpc/4]).

-import(escalus_stanza, [setattr/3]).

-import(domain_helper, [host_type/0]).

-import(sm_helper, [connect_fresh/3,
                    connect_fresh/4,
                    connect_spec/2,
                    connect_spec/3,
                    connect_same/2,
                    connect_same/3,
                    connect_resume/2,
                    client_to_spec0/1,
                    client_to_spec/1,
                    client_to_smid/1,
                    wait_until_disconnected/1,
                    try_to_resume_stream/3,
                    kill_and_connect_with_resume_session_without_waiting_for_result/1,
                    stop_client_and_wait_for_termination/1,
                    assert_alive_resources/2,
                    get_user_present_resources/1,
                    get_sid_by_stream_id/1,
                    wait_for_c2s_unacked_count/2,
                    wait_for_resource_count/2,
                    wait_for_process_termination/1,
                    process_initial_stanza/1,
                    send_initial_presence/1,
                    kill_and_connect_resume/1,
                    monitor_session/1,
                    wait_for_process_termination/1,
                    wait_for_queue_length/2,
                    send_messages/3,
                    wait_for_messages/2,
                    get_ack/1,
                    ack_initial_presence/1]).

-define(LONG_TIMEOUT, 3600).
-define(SHORT_TIMEOUT, 3).
-define(SMALL_SM_BUFFER, 3).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, parallel},
     {group, parallel_manual_ack_freq_1},
     {group, manual_ack_freq_2},
     {group, stale_h},
     {group, stream_mgmt_disabled},
     {group, unacknowledged_message_hook}
     ].

groups() ->
    G = [{parallel, [parallel], parallel_test_cases()},
         {parallel_manual_ack_freq_1, [parallel], parallel_manual_ack_test_cases()},
         {manual_ack_freq_2, [], [server_requests_ack_freq_2]},
         {stale_h, [], stale_h_test_cases()},
         {stream_mgmt_disabled, [], stream_mgmt_disabled_cases()},
         {manual_ack_freq_long_session_timeout, [parallel], [preserve_order]},
         {unacknowledged_message_hook, [parallel], unacknowledged_message_hook()}],
    ct_helper:repeat_all_until_all_ok(G).


parallel_test_cases() ->
    [server_announces_sm,
     server_enables_sm_before_session,
     server_enables_sm_after_session,
     server_returns_failed_after_start,
     server_returns_failed_after_auth,
     server_enables_resumption,
     client_enables_sm_twice_fails_with_correct_error_stanza,
     session_resumed_then_old_session_is_closed_gracefully_with_correct_error_stanza,
     session_resumed_and_old_session_dead_doesnt_route_error_to_new_session,
     basic_ack,
     h_ok_before_session,
     h_ok_after_session_enabled_before_session,
     h_ok_after_session_enabled_after_session,
     h_ok_after_a_chat,
     h_non_given_closes_stream_gracefully,
     resend_unacked_on_reconnection,
     session_established,
     wait_for_resumption,
     resume_session,
     resume_session_with_wrong_h_does_not_leak_sessions,
     resume_session_with_wrong_sid_returns_item_not_found,
     resume_session_with_wrong_namespace_is_a_noop,
     resume_dead_session_results_in_item_not_found,
     resume_session_kills_old_C2S_gracefully,
     aggressively_pipelined_resume,
     replies_are_processed_by_resumed_session,
     subscription_requests_are_buffered_properly,
     messages_are_properly_flushed_during_resumption,
     messages_are_properly_flushed_during_resumption_p1_fsm_old
    ].

parallel_manual_ack_test_cases() ->
    [client_acks_more_than_sent,
     too_many_unacked_stanzas,
     resend_unacked_after_resume_timeout,
     resume_session_state_send_message,
     resume_session_state_stop_c2s,
     server_requests_ack_after_session,
     resend_more_offline_messages_than_buffer_size,
     server_requests_ack
     ].

stale_h_test_cases() ->
    [
     resume_expired_session_returns_correct_h,
     gc_repeat_after_never_means_no_cleaning,
     gc_repeat_after_timeout_does_clean
    ].

stream_mgmt_disabled_cases() ->
    [
     no_crash_if_stream_mgmt_disabled_but_client_requests_stream_mgmt,
     no_crash_if_stream_mgmt_disabled_but_client_requests_stream_mgmt_with_resumption
    ].

unacknowledged_message_hook() ->
    [unacknowledged_message_hook_bounce,
     unacknowledged_message_hook_offline,
     unacknowledged_message_hook_resume].

suite() ->
    require_rpc_nodes([mim]) ++ escalus:suite().

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    NewConfig = dynamic_modules:save_modules(host_type(), Config),
    NewConfigWithSM = escalus_users:update_userspec(NewConfig, alice, stream_management, true),
    mongoose_helper:inject_module(?MODULE),
    escalus:init_per_suite(NewConfigWithSM).

end_per_suite(Config) ->
    escalus_fresh:clean(),
    dynamic_modules:restore_modules(Config),
    escalus:end_per_suite(Config).

init_per_group(Group, Config) when Group =:= unacknowledged_message_hook;
                                   Group =:= manual_ack_freq_long_session_timeout;
                                   Group =:= parallel_manual_ack_freq_1;
                                   Group =:= manual_ack_freq_2 ->
    dynamic_modules:ensure_modules(host_type(), required_modules(group, Group)),
    Config;
init_per_group(stale_h, Config) ->
    escalus_users:update_userspec(Config, alice, manual_ack, true);
init_per_group(stream_mgmt_disabled, Config) ->
    dynamic_modules:stop(host_type(), ?MOD_SM),
    rpc(mim(), mnesia, delete_table, [sm_session]),
    Config;
init_per_group(Group, Config) ->
    dynamic_modules:ensure_modules(host_type(), required_modules(group, Group)),
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(resume_expired_session_returns_correct_h = CN, Config) ->
    dynamic_modules:ensure_modules(host_type(), required_modules(testcase, CN)),
    escalus:init_per_testcase(CN, Config);
init_per_testcase(CN, Config) when CN =:= gc_repeat_after_never_means_no_cleaning;
                                   CN =:= gc_repeat_after_timeout_does_clean ->
    dynamic_modules:ensure_modules(host_type(), required_modules(testcase, CN)),
    Config2 = register_some_smid_h(Config),
    escalus:init_per_testcase(CN, Config2);
init_per_testcase(server_requests_ack_freq_2 = CN, Config) ->
    escalus:init_per_testcase(CN, Config);
init_per_testcase(replies_are_processed_by_resumed_session = CN, Config) ->
    register_handler(),
    escalus:init_per_testcase(CN, Config);
init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CN, Config) when CN =:= resume_expired_session_returns_correct_h;
                                  CN =:= gc_repeat_after_never_means_no_cleaning;
                                  CN =:= gc_repeat_after_timeout_does_clean ->
    rpc(mim(), ejabberd_sup, stop_child, [stream_management_stale_h]),
    escalus:end_per_testcase(CN, Config);
end_per_testcase(replies_are_processed_by_resumed_session = CN, Config) ->
    unregister_handler(),
    escalus:end_per_testcase(CN, Config);
end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

%% Module configuration per group (in case of stale_h group it is per testcase)

required_modules(Scope, Name) ->
    SMConfig = case required_sm_opts(Scope, Name) of
                   stopped -> stopped;
                   ExtraOpts -> common_sm_opts() ++ ExtraOpts
               end,
    [{mod_stream_management, SMConfig}, {mod_offline, []}].

required_sm_opts(group, parallel) ->
    [{ack_freq, never}];
required_sm_opts(group, parallel_manual_ack_freq_1) ->
    [{ack_freq, 1},
     {resume_timeout, ?SHORT_TIMEOUT}];
required_sm_opts(group, manual_ack_freq_2) ->
    [{ack_freq, 2}];
required_sm_opts(group, stream_mgmt_disabled) ->
    stopped;
required_sm_opts(group, Group) when Group =:= unacknowledged_message_hook;
                                    Group =:= manual_ack_freq_long_session_timeout ->
    [{ack_freq, 1}];
required_sm_opts(testcase, resume_expired_session_returns_correct_h) ->
    [{ack_freq, 1},
     {resume_timeout, ?SHORT_TIMEOUT} | stale_h(?LONG_TIMEOUT, ?LONG_TIMEOUT)];
required_sm_opts(testcase, gc_repeat_after_never_means_no_cleaning) ->
    stale_h(?LONG_TIMEOUT, ?SHORT_TIMEOUT);
required_sm_opts(testcase, gc_repeat_after_timeout_does_clean) ->
    stale_h(?SHORT_TIMEOUT, ?SHORT_TIMEOUT).

common_sm_opts() ->
    [{buffer_max, ?SMALL_SM_BUFFER}].

stale_h(RepeatAfter, Geriatric) ->
    [{stale_h, [{enabled, true},
                {stale_h_repeat_after, RepeatAfter},
                {stale_h_geriatric, Geriatric}]}].

make_smid() ->
    base64:encode(crypto:strong_rand_bytes(21)).

register_smid(IntSmidId) ->
    S = {SMID = make_smid(), IntSmidId},
    ok = rpc(mim(), ?MOD_SM, register_stale_smid_h, [host_type(), SMID, IntSmidId]),
    S.

register_some_smid_h(Config) ->
    TestSmids = lists:map(fun register_smid/1, lists:seq(1, 3)),
    [{smid_test, TestSmids} | Config].

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

server_announces_sm(Config) ->
    AliceSpec = escalus_fresh:freshen_spec(Config, alice),
    {ok, #client{props = Props}, Features} = escalus_connection:start(AliceSpec,
                                                                      [start_stream]),
    true = escalus_session:can_use_stream_management(Props, Features).


server_enables_sm_before_session(Config) ->
    connect_fresh(Config, alice, sm_after_bind).

server_enables_sm_after_session(Config) ->
    connect_fresh(Config, alice, sm_after_session).

server_returns_failed_after_start(Config) ->
    Alice = connect_fresh(Config, alice, before_auth),
    server_returns_failed(Alice).

server_returns_failed_after_auth(Config) ->
    Alice = connect_fresh(Config, alice, auth),
    server_returns_failed(Alice).

server_enables_resumption(Config) ->
    Alice = connect_fresh(Config, alice, sr_presence),
    escalus_connection:stop(Alice).

server_returns_failed(Alice) ->
    escalus_connection:send(Alice, escalus_stanza:enable_sm()),
    escalus:assert(is_sm_failed, [<<"unexpected-request">>],
                   escalus_connection:get_stanza(Alice, enable_sm_failed)).

client_enables_sm_twice_fails_with_correct_error_stanza(Config) ->
    Alice = connect_fresh(Config, alice, sm_before_session),
    escalus_connection:send(Alice, escalus_stanza:enable_sm()),
    escalus:assert(is_sm_failed, [<<"unexpected-request">>],
                   escalus_connection:get_stanza(Alice, enable_sm_failed)),
    escalus:assert(is_stream_end,
                   escalus_connection:get_stanza(Alice, enable_sm_failed)),
    true = escalus_connection:wait_for_close(Alice, timer:seconds(5)).

session_resumed_then_old_session_is_closed_gracefully_with_correct_error_stanza(Config) ->
    %% GIVEN USER WITH STREAM RESUMPTION ENABLED
    Alice = connect_fresh(Config, alice, sr_presence),
    SMH = escalus_connection:get_sm_h(Alice),
    %% WHEN USER RESUMES SESSION FROM NEW CLIENT
    Alice2 = connect_resume(Alice, SMH),
    process_initial_stanza(Alice2),
    %% THEN: Old session is gracefully closed with the correct error stanza
    escalus:assert(is_stream_error, [<<"conflict">>, <<>>],
                   escalus_connection:get_stanza(Alice, close_old_stream)),
    escalus:assert(is_stream_end,
                   escalus_connection:get_stanza(Alice, close_old_stream)),
    true = escalus_connection:wait_for_close(Alice, timer:seconds(5)),
    true = escalus_connection:is_connected(Alice2),
    escalus_connection:stop(Alice2).

session_resumed_and_old_session_dead_doesnt_route_error_to_new_session(Config) ->
    %% GIVEN USER WITH STREAM RESUMPTION ENABLED
    Alice = connect_fresh(Config, alice, sr_presence),
    %% WHEN FIRST SESSION DIES AND USER RESUMES FROM NEW CLIENT
    Alice2 = kill_and_connect_resume(Alice),
    process_initial_stanza(Alice2),
    %% THEN new session does not have any message rerouted
    false = escalus_client:has_stanzas(Alice2),
    true = escalus_connection:is_connected(Alice2),
    escalus_connection:stop(Alice2).

basic_ack(Config) ->
    Alice = connect_fresh(Config, alice, sm_after_session),
    escalus_connection:send(Alice, escalus_stanza:roster_get()),
    escalus:assert(is_roster_result,
                   escalus_connection:get_stanza(Alice, roster_result)),
    escalus_connection:send(Alice, escalus_stanza:sm_request()),
    escalus:assert(is_sm_ack,
                   escalus_connection:get_stanza(Alice, stream_mgmt_ack)).

%% Test that "h" value is valid when:
%% - SM is enabled *before* the session is established
%% - <r/> is sent *before* the session is established
h_ok_before_session(Config) ->
    Alice = connect_fresh(Config, alice, sm_after_bind),
    escalus_connection:send(Alice, escalus_stanza:sm_request()),
    escalus:assert(is_sm_ack, [0],
                   escalus_connection:get_stanza(Alice, stream_mgmt_ack)).

%% Test that "h" value is valid when:
%% - SM is enabled *before* the session is established
%% - <r/> is sent *after* the session is established
h_ok_after_session_enabled_before_session(Config) ->
    Alice = connect_fresh(Config, alice, sm_before_session),
    escalus_connection:send(Alice, escalus_stanza:sm_request()),
    escalus:assert(is_sm_ack, [1],
                   escalus_connection:get_stanza(Alice, stream_mgmt_ack)).

%% Test that "h" value is valid when:
%% - SM is enabled *after* the session is established
%% - <r/> is sent *after* the session is established
h_ok_after_session_enabled_after_session(Config) ->
    Alice = connect_fresh(Config, alice, sm_after_session),
    escalus_connection:send(Alice, escalus_stanza:roster_get()),
    escalus:assert(is_roster_result,
                   escalus_connection:get_stanza(Alice, roster_result)),
    escalus_connection:send(Alice, escalus_stanza:sm_request()),
    escalus:assert(is_sm_ack, [1],
                   escalus_connection:get_stanza(Alice, stream_mgmt_ack)).

%% Test that "h" value is valid after exchanging a few messages.
h_ok_after_a_chat(ConfigIn) ->
    Config = escalus_users:update_userspec(ConfigIn, alice,
                                           stream_management, true),
    escalus:fresh_story(Config, [{alice,1}, {bob,1}], fun(Alice, Bob) ->
        escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"Hi, Bob!">>)),
        escalus:assert(is_chat_message, [<<"Hi, Bob!">>],
                       escalus:wait_for_stanza(Bob)),
        escalus:send(Bob, escalus_stanza:chat_to(Alice, <<"Hi, Alice!">>)),
        escalus:assert(is_chat_message, [<<"Hi, Alice!">>],
                       escalus:wait_for_stanza(Alice)),
        escalus:send(Bob, escalus_stanza:chat_to(Alice, <<"How's life?">>)),
        escalus:assert(is_chat_message, [<<"How's life?">>],
                       escalus:wait_for_stanza(Alice)),
        escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"Pretty !@#$%^$">>)),
        escalus:assert(is_chat_message, [<<"Pretty !@#$%^$">>],
                       escalus:wait_for_stanza(Bob)),
        escalus:send(Alice, escalus_stanza:sm_request()),
        escalus:assert(is_sm_ack, [3], escalus:wait_for_stanza(Alice)),
        %% Ack, so that unacked messages don't go into offline store.
        escalus:send(Alice, escalus_stanza:sm_ack(3))
    end).

h_non_given_closes_stream_gracefully(ConfigIn) ->
    AStanza = #xmlel{name = <<"a">>,
               attrs = [{<<"xmlns">>, <<"urn:xmpp:sm:3">>}]},
    Config = escalus_users:update_userspec(ConfigIn, alice,
                                           stream_management, true),
    escalus:fresh_story(Config, [{alice,1}], fun(Alice) ->
        C2SPid = mongoose_helper:get_session_pid(Alice),
        escalus:send(Alice, AStanza),
        escalus:assert(is_stream_error,
                       [<<"policy-violation">>, <<>>],
                       escalus:wait_for_stanza(Alice)),
        mongoose_helper:wait_for_pid_to_die(C2SPid),
        escalus:assert(is_stream_end, escalus_connection:get_stanza(Alice, stream_end)),
        true = escalus_connection:wait_for_close(Alice, timer:seconds(5))
    end).

client_acks_more_than_sent(Config) ->
    Alice = connect_fresh(Config, alice, sm_after_session),
    escalus:send(Alice, escalus_stanza:sm_ack(5)),
    StreamErrorStanza = escalus:wait_for_stanza(Alice),
    %% Assert "undefined-condition" children
    escalus:assert(is_stream_error, [<<"undefined-condition">>, <<>>], StreamErrorStanza),
    %% Assert "handled-count-too-high" children with correct attributes
    HandledCountSubElement = exml_query:path(StreamErrorStanza,
                                             [{element_with_ns,
                                               <<"handled-count-too-high">>,
                                               <<"urn:xmpp:sm:3">>}]),
    <<"5">> = exml_query:attr(HandledCountSubElement, <<"h">>),
    <<"0">> = exml_query:attr(HandledCountSubElement, <<"send-count">>),
    %% Assert graceful stream end
    escalus:assert(is_stream_end, escalus_connection:get_stanza(Alice, stream_end)),
    true = escalus_connection:wait_for_close(Alice, timer:seconds(5)).

too_many_unacked_stanzas(Config) ->
    Bob = connect_fresh(Config, bob, presence),
    Alice = connect_fresh(Config, alice, sm_presence, manual),
    get_ack(Alice),
    [escalus:send(Bob, escalus_stanza:chat_to(Alice,
        <<(integer_to_binary(N))/binary, ": Hi, Alice!">>))
     || N <- lists:seq(1,?SMALL_SM_BUFFER)],
    escalus:wait_for_stanzas(Alice, ?SMALL_SM_BUFFER * 2), % messages and ack requests
    escalus:assert(is_stream_error, [<<"resource-constraint">>,
                                     <<"too many unacked stanzas">>],
                   %% wait for deferred buffer check
                   escalus:wait_for_stanza(Alice, ?CONSTRAINT_CHECK_TIMEOUT + 1000)).

server_requests_ack(Config) ->
    server_requests_ack(Config, 1).

server_requests_ack_freq_2(Config) ->
    server_requests_ack(Config, 2).

server_requests_ack(Config, N) ->
    Bob = connect_fresh(Config, bob, presence),
    Alice = connect_fresh(Config, alice, sm_presence, manual),
    %% ack request after initial presence
    maybe_assert_ack_request(1, N, Alice),
    escalus:send(Bob, escalus_stanza:chat_to(Alice, <<"Hi, Alice!">>)),
    escalus:assert(is_chat_message, [<<"Hi, Alice!">>],
                   escalus:wait_for_stanza(Alice)),
    maybe_assert_ack_request(2, N, Alice).

maybe_assert_ack_request(StanzasRec, AckRequests, Alice) ->
    ct:log("StanzasRec: ~p, AckRequests: ~p", [StanzasRec, AckRequests]),
    case StanzasRec rem AckRequests of
        0 ->
            escalus:assert(is_sm_ack_request, escalus:wait_for_stanza(Alice));
        _ ->
            ok
    end,
    StanzasRec.

server_requests_ack_after_session(Config) ->
    Alice = connect_fresh(Config, alice, sm_before_session, manual),
    escalus:assert(is_sm_ack_request, escalus_connection:get_stanza(Alice, stream_mgmt_req)).

resend_more_offline_messages_than_buffer_size(Config) ->
    %% connect bob and alice
    Bob = connect_fresh(Config, bob, presence),
    AliceSpec = escalus_fresh:create_fresh_user(Config, alice),

    % sent some messages - more than unacked buffer size
    MessagesToSend = ?SMALL_SM_BUFFER + 1,
    JID = common_helper:get_bjid(AliceSpec),
    [escalus_connection:send(Bob, escalus_stanza:chat_to(JID, integer_to_binary(I)))
     || I <- lists:seq(1, MessagesToSend)],

    % connect alice who wants to receive all messages from offline storage
    Alice = connect_spec(AliceSpec, sm_after_session, manual),
    mongoose_helper:wait_for_n_offline_messages(Alice, MessagesToSend),
    send_initial_presence(Alice),

    escalus:wait_for_stanzas(Alice, MessagesToSend * 2), %messages and ack requests

    escalus_connection:get_stanza(Alice, presence),
    get_ack(Alice), % ack request

    % confirm messages + presence
    escalus_connection:send(Alice, escalus_stanza:sm_ack(4)),
    % wait for check constraint message on server side

    ct:sleep(?CONSTRAINT_CHECK_TIMEOUT + 1000),
    false = escalus_client:has_stanzas(Alice),
    % should not receive anything especially any stream errors

    escalus_connection:stop(Alice),
    escalus_connection:stop(Bob).

resend_unacked_on_reconnection(Config) ->
    Texts = three_texts(),
    Bob = connect_fresh(Config, bob, presence),
    Alice = connect_fresh(Config, alice, sm_presence),
    AliceSpec = client_to_spec0(Alice),
    %% Bob sends some messages to Alice.
    send_messages(Bob, Alice, Texts),
    %% Alice receives the messages.
    wait_for_messages(Alice, Texts),
    %% Alice disconnects without acking the messages.
    stop_client_and_wait_for_termination(Alice),
    %% Messages go to the offline store.
    %% Alice receives the messages from the offline store.
    NewAlice = connect_spec(AliceSpec, session, manual),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    wait_for_messages(NewAlice, Texts),
    %% Alice acks the delayed messages so they won't go again
    %% to the offline store.
    escalus_connection:send(NewAlice, escalus_stanza:sm_ack(3)).

preserve_order(Config) ->
    %% connect bob and alice
    Bob = connect_fresh(Config, bob, presence),
    Alice = connect_fresh(Config, alice, sr_presence),
    AliceSpec = client_to_spec(Alice),
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"1">>)),

    %% kill alice connection
    escalus_connection:kill(Alice),
    wait_until_disconnected(Alice),

    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"2">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"3">>)),

    NewAlice = connect_spec(AliceSpec, session),
    escalus_connection:send(NewAlice, escalus_stanza:enable_sm([resume])),

    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"4">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"5">>)),

    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"6">>)),

    receive_all_ordered(NewAlice, 1, 6),

    % replace connection
    NewAlice2 = connect_spec(AliceSpec, session),
    % allow messages to go to the offline storage
    mongoose_helper:wait_for_n_offline_messages(NewAlice, 6),

    escalus_connection:send(NewAlice2, escalus_stanza:presence(<<"available">>)),

    % receves messages in correct order
    receive_all_ordered(NewAlice2, 1, 6),

    escalus_connection:stop(Bob),
    escalus_connection:stop(NewAlice2).

receive_all_ordered(Conn, N, Total) ->
    case catch escalus_connection:get_stanza(Conn, msg) of
        #xmlel{} = Stanza ->
            NN = case Stanza#xmlel.name of
                     <<"message">> ->
                         escalus:assert(is_chat_message, [integer_to_binary(N)], Stanza),
                         N + 1;
                     _ ->
                         N
                 end,
            receive_all_ordered(Conn, NN, Total);
        _Error when N =:= Total ->
            ok
    end.

resend_unacked_after_resume_timeout(Config) ->
    %% connect bob and alice
    Bob = connect_fresh(Config, bob, presence),
    Alice = connect_fresh(Config, alice, sr_presence),
    AliceSpec = client_to_spec(Alice),

    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-1">>)),
    %% kill alice connection
    escalus_connection:kill(Alice),

    %% ensure there is no session
    wait_until_disconnected(Alice),

    %% alice come back and receives unacked message
    NewAlice = connect_spec(AliceSpec, session),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),

    escalus_new_assert:mix_match([is_presence, is_chat(<<"msg-1">>)],
                                 escalus:wait_for_stanzas(NewAlice, 2)),

    escalus_connection:stop(Bob),
    escalus_connection:stop(NewAlice).

resume_expired_session_returns_correct_h(Config) ->
    %% connect bob and alice
    Bob = connect_fresh(Config, bob, sr_presence),
    Alice = connect_fresh(Config, alice, sr_presence),
    %% Bob sends a message to Alice, and Alice receives it but doesn't acknowledge
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-1">>)),
    escalus:wait_for_stanza(Alice),
    %% alice comes back, but too late, so resumption doesn't work,
    %% but she receives the previous h = 1 anyway
    NewAlice = kill_and_connect_with_resume_session_without_waiting_for_result(Alice),
    FailedResumption = escalus_connection:get_stanza(NewAlice, failed_resumption),
    <<"1">> = exml_query:attr(FailedResumption, <<"h">>),
    %% And we can continue with bind and session
    escalus_session:session(escalus_session:bind(NewAlice)),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    Stanzas = [escalus_connection:get_stanza(NewAlice, msg),
               escalus_connection:get_stanza(NewAlice, msg)],
    escalus_new_assert:mix_match([is_presence, is_chat(<<"msg-1">>)], Stanzas),
    escalus_connection:stop(Bob),
    escalus_connection:stop(NewAlice).

gc_repeat_after_never_means_no_cleaning(Config) ->
    [{SMID1, _}, {SMID2, _}, {SMID3, _}] = ?config(smid_test, Config),
    {stale_h, 1} = rpc(mim(), ?MOD_SM, get_session_from_smid, [host_type(), SMID1]),
    {stale_h, 2} = rpc(mim(), ?MOD_SM, get_session_from_smid, [host_type(), SMID2]),
    {stale_h, 3} = rpc(mim(), ?MOD_SM, get_session_from_smid, [host_type(), SMID3]).

gc_repeat_after_timeout_does_clean(Config) ->
    [{SMID1, _} | _ ] = ?config(smid_test, Config),
    mongoose_helper:wait_until(fun() ->
                                       rpc(mim(), ?MOD_SM, get_stale_h, [host_type(), SMID1])
                               end,
                               {error, smid_not_found},
                               #{name => smid_garbage_collected}).

resume_session_state_send_message(Config) ->
    %% connect bob and alice
    Bob = connect_fresh(Config, bob, presence),
    Alice = connect_fresh(Config, alice, sr_presence, manual),
    ack_initial_presence(Alice),

    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-1">>)),
    %% kill alice connection
    C2SPid = mongoose_helper:get_session_pid(Alice),
    escalus_connection:kill(Alice),
    mongoose_helper:wait_for_c2s_state_name(C2SPid, resume_session),
    assert_alive_resources(Alice, 1),

    %% send some messages and check if c2s can handle it
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-2">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-3">>)),
    %% suspend the process to ensure that Alice has enough time to reconnect,
    %% before resumption timeout occurs.
    ok = rpc(mim(), sys, suspend, [C2SPid]),

    %% alice comes back and receives unacked message
    NewAlice = connect_same(Alice, session),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    escalus:assert(is_presence, escalus_connection:get_stanza(NewAlice, presence)),
    %% now we can resume c2s process of the old connection
    %% and let it process session resumption timeout
    ok = rpc(mim(), sys, resume, [C2SPid]),
    Stanzas = escalus:wait_for_stanzas(NewAlice, 3),

    % what about order ?
    % alice receive presence from herself and 3 unacked messages from bob
    escalus_new_assert:mix_match([is_chat(<<"msg-1">>),
                                  is_chat(<<"msg-2">>),
                                  is_chat(<<"msg-3">>)],
                                 Stanzas),
    escalus_connection:stop(Bob),
    escalus_connection:stop(NewAlice).

%%for instance it can be done by mod ping
resume_session_state_stop_c2s(Config) ->
    Bob = connect_fresh(Config, bob, presence),
    Alice = connect_fresh(Config, alice, sr_presence, manual),

    get_ack(Alice),
    ack_initial_presence(Alice),

    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-1">>)),
    escalus:assert(is_chat_message, [<<"msg-1">>], escalus_connection:get_stanza(Alice, msg)),

    %% get pid of c2s
    C2SPid = mongoose_helper:get_session_pid(Alice),
    %% Wait c2s process to process our presence ack.
    %% Otherwise, we can receive two initial presences sometimes.
    wait_for_c2s_unacked_count(C2SPid, 1),

    % kill alice connection
    escalus_connection:kill(Alice),
    % session should be alive
    assert_alive_resources(Alice, 1),
    rpc(mim(), ejabberd_c2s, stop, [C2SPid]),
    mongoose_helper:wait_for_c2s_state_name(C2SPid, resume_session),
    %% suspend the process to ensure that Alice has enough time to reconnect,
    %% before resumption timeout occurs.
    ok = rpc(mim(), sys, suspend, [C2SPid]),

    %% alice comes back and receives unacked message
    NewAlice = connect_same(Alice, presence, manual),
    %% now we can resume c2s process of the old connection
    %% and let it process session resumption timeout
    ok = rpc(mim(), sys, resume, [C2SPid]),

    escalus:assert(is_chat_message, [<<"msg-1">>], escalus_connection:get_stanza(NewAlice, msg)),
    escalus_connection:stop(Bob),
    escalus_connection:stop(NewAlice).

%% This test only verifies the validity of helpers (get_session_pid,
%% get_c2s_state_name) written for wait_for_resumption
%% testcase.
session_established(Config) ->
    Alice = connect_fresh(Config, alice, presence),
    C2SPid = mongoose_helper:get_session_pid(Alice),
    session_established = mongoose_helper:get_c2s_state_name(C2SPid),
    escalus_connection:stop(Alice).

%% Ensure that after a violent disconnection,
%% the c2s waits for resumption (but don't resume yet).
wait_for_resumption(Config) ->
    AliceSpec = escalus_fresh:create_fresh_user(Config, alice),
    Bob = connect_fresh(Config, bob, session),
    Texts = three_texts(),
    {C2SPid, _} = buffer_unacked_messages_and_die(Config, AliceSpec, Bob, Texts),
    mongoose_helper:wait_for_c2s_state_name(C2SPid, resume_session).

unacknowledged_message_hook_resume(Config) ->
    unacknowledged_message_hook_common(fun unacknowledged_message_hook_resume/4, Config).

unacknowledged_message_hook_resume(AliceSpec, Resource, SMID, _C2SPid) ->
    NewAlice = connect_spec(AliceSpec, {resume, SMID, 1}, manual),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    {Resource, NewAlice}.

unacknowledged_message_hook_bounce(Config) ->
    unacknowledged_message_hook_common(fun unacknowledged_message_hook_bounce/4, Config).

unacknowledged_message_hook_bounce(AliceSpec, Resource, _SMID, C2SPid) ->
    NewResource = <<"new_", Resource/binary>>,
    NewSpec = lists:keystore(resource, 1, AliceSpec, {resource, NewResource}),
    NewAlice = connect_spec(NewSpec, sr_session, manual),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    %% ensure second C2S is registered so all the messages are bounced properly
    wait_for_resource_count(NewAlice, 2),
    ok = rpc(mim(), sys, terminate, [C2SPid, normal]),
    {NewResource, NewAlice}.

unacknowledged_message_hook_offline(Config) ->
    unacknowledged_message_hook_common(fun unacknowledged_message_hook_offline/4, Config).

unacknowledged_message_hook_offline(AliceSpec, Resource, _SMID, C2SPid) ->
    C2SRef = erlang:monitor(process, C2SPid),
    %%reset the session, so old C2S process is stopped
    NewAlice = connect_spec(AliceSpec, sr_session, manual),
    %% wait for old C2S termination before send presence. other way
    %% some of the latest unacknowledged messages can be bounced to
    %% the new C2S process instead of going to the mod_offline storage.
    %% looks like all the unacknowledged messages arrive to the new
    %% C2S, but the message sequence is broken (the bounced messages
    %% delivered before the messages from the mod_offline storage)
    wait_for_process_termination(C2SRef),
    escalus_connection:send(NewAlice, escalus_stanza:presence(<<"available">>)),
    {Resource, NewAlice}.

unacknowledged_message_hook_common(RestartConnectionFN, Config) ->
    %% connect bob and alice
    Bob = connect_fresh(Config, bob, presence),

    AliceSpec0 = escalus_fresh:create_fresh_user(Config, alice),
    Resource = proplists:get_value(username, AliceSpec0),
    AliceSpec = [{resource, Resource} | AliceSpec0],
    HookHandlerExtra = start_hook_listener(Resource),
    Alice = connect_spec(AliceSpec, sr_presence, manual),
    %% Ack the presence stanza
    get_ack(Alice),
    ack_initial_presence(Alice),

    SMID = client_to_smid(Alice),

    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-1">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-2">>)),
    %% kill alice connection
    C2SPid = mongoose_helper:get_session_pid(Alice),
    escalus_connection:kill(Alice),
    mongoose_helper:wait_for_c2s_state_name(C2SPid, resume_session),
    assert_alive_resources(Alice, 1),

    escalus:assert(is_chat_message, [<<"msg-1">>], wait_for_unacked_msg_hook(0, Resource, 100)),
    escalus:assert(is_chat_message, [<<"msg-2">>], wait_for_unacked_msg_hook(0, Resource, 100)),
    ?assertEqual(timeout, wait_for_unacked_msg_hook(0, Resource, 100)),

    %% send some messages and check if c2s can handle it
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-3">>)),
    escalus_connection:send(Bob, escalus_stanza:chat_to_short_jid(Alice, <<"msg-4">>)),
    escalus:assert(is_chat_message, [<<"msg-3">>], wait_for_unacked_msg_hook(0, Resource, 100)),
    escalus:assert(is_chat_message, [<<"msg-4">>], wait_for_unacked_msg_hook(0, Resource, 100)),
    ?assertEqual(timeout, wait_for_unacked_msg_hook(0, Resource, 100)),

    %% alice comes back and receives unacked message
    {NewResource, NewAlice} = RestartConnectionFN(AliceSpec, Resource, SMID, C2SPid),

    mongoose_helper:wait_until(
        fun() ->
            Stanza = escalus_connection:get_stanza(NewAlice, msg),
            escalus:assert(is_chat_message, [<<"msg-4">>], Stanza),
            ok
        end, ok),

    NewC2SPid = mongoose_helper:get_session_pid(NewAlice),
    escalus_connection:kill(NewAlice),
    mongoose_helper:wait_for_c2s_state_name(NewC2SPid, resume_session),

    escalus:assert(is_chat_message, [<<"msg-1">>], wait_for_unacked_msg_hook(1, NewResource, 100)),
    escalus:assert(is_chat_message, [<<"msg-2">>], wait_for_unacked_msg_hook(1, NewResource, 100)),
    escalus:assert(is_chat_message, [<<"msg-3">>], wait_for_unacked_msg_hook(1, NewResource, 100)),
    escalus:assert(is_chat_message, [<<"msg-4">>], wait_for_unacked_msg_hook(1, NewResource, 100)),
    ?assertEqual(timeout, wait_for_unacked_msg_hook(0, Resource, 100)),
    stop_hook_listener(HookHandlerExtra),
    escalus_connection:stop(Bob).

resume_session(Config) ->
    AliceSpec = escalus_fresh:create_fresh_user(Config, alice),
    Texts = three_texts(),
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->
        {_, SMID} = buffer_unacked_messages_and_die(Config, AliceSpec, Bob, Texts),
        %% Resume the session.
        Alice = connect_spec(AliceSpec, {resume, SMID, 1}, manual),
        %% Alice receives the unacked messages from the previous
        %% interrupted session.
        wait_for_messages(Alice, Texts),
        %% Alice acks the received messages.
        escalus_connection:send(Alice, escalus_stanza:sm_ack(5)),
        escalus_connection:stop(Alice)
    end).

resume_session_with_wrong_h_does_not_leak_sessions(Config) ->
    AliceSpec = escalus_fresh:create_fresh_user(Config, alice),
    Messages = three_texts(),
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->
        {_, SMID} = buffer_unacked_messages_and_die(Config, AliceSpec, Bob, Messages),
        %% Resume the session.
        Alice = connect_spec(AliceSpec, auth, manual),
        Resumed = try_to_resume_stream(Alice, SMID, 30),
        escalus:assert(is_stream_error, [<<"undefined-condition">>, <<>>], Resumed),

        [] = get_user_present_resources(Alice),
        {error, smid_not_found} = get_sid_by_stream_id(SMID),
        escalus_connection:wait_for_close(Alice, timer:seconds(5))
    end).

resume_session_with_wrong_sid_returns_item_not_found(Config) ->
    session_resumption_expects_item_not_found(Config, <<"wrong-sid">>).

resume_session_with_wrong_namespace_is_a_noop(Config) ->
    Alice = connect_fresh(Config, alice, auth),
    #xmlel{attrs = Attrs} = Resume = escalus_stanza:resume(<<"doesnt_matter">>, 4),
    Attrs2 = lists:keyreplace(<<"xmlns">>, 1, Attrs, {<<"xmlns">>, <<"not-stream-mgnt">>}),
    escalus_connection:send(Alice, Resume#xmlel{attrs = Attrs2}),
    escalus_assert:has_no_stanzas(Alice),
    [] = get_user_present_resources(Alice),
    true = escalus_connection:is_connected(Alice),
    escalus_connection:stop(Alice).

resume_dead_session_results_in_item_not_found(Config) ->
    SMID = base64:encode(crypto:strong_rand_bytes(21)),
    SID = {os:timestamp(), undefined},
    rpc(mim(), ?MOD_SM, register_smid, [SMID, SID]),
    session_resumption_expects_item_not_found(Config, SMID).

session_resumption_expects_item_not_found(Config, SMID) ->
    Alice = connect_fresh(Config, alice, auth),
    Resumed = try_to_resume_stream(Alice, SMID, 2),
    escalus:assert(is_sm_failed, [<<"item-not-found">>], Resumed),
    [] = get_user_present_resources(Alice),
    true = escalus_connection:is_connected(Alice),
    escalus_connection:stop(Alice).

resume_session_kills_old_C2S_gracefully(Config) ->
    Alice = connect_fresh(Config, alice, sr_presence, manual),
    C2SPid = mongoose_helper:get_session_pid(Alice),

    %% Monitor the C2S process and disconnect Alice.
    MonitorRef = erlang:monitor(process, C2SPid),
    escalus_client:kill_connection(Config, Alice),

    %% Ensure the c2s process is waiting for resumption.
    mongoose_helper:wait_for_c2s_state_name(C2SPid, resume_session),

    %% Resume the session.
    NewAlice = connect_resume(Alice, 1),

    %% C2S process should die gracefully with Reason=normal.
    receive
        {'DOWN', MonitorRef, process, C2SPid, normal} ->
            ok;
        Msg ->
            ct:fail("C2S did not die gracefully. Instead received: ~p", [Msg])
    after timer:seconds(1) ->
        ct:fail("Old C2S did not die in time after session resumption.")
    end,
    escalus_connection:stop(NewAlice).

buffer_unacked_messages_and_die(Config, AliceSpec, Bob, Texts) ->
    Alice = connect_spec(AliceSpec, sr_presence, manual),
    %% Bobs sends some messages to Alice.
    send_messages(Bob, Alice, Texts),
    %% Alice receives them, but doesn't ack.
    wait_for_messages(Alice, Texts),
    %% Alice's connection is violently terminated.
    escalus_client:kill_connection(Config, Alice),
    C2SPid = mongoose_helper:get_session_pid(Alice),
    SMID = client_to_smid(Alice),
    {C2SPid, SMID}.

aggressively_pipelined_resume(Config) ->
    AliceSpec = [{manual_ack, true}, {parser_opts, [{start_tag, <<"stream:stream">>}]}
                 | escalus_fresh:create_fresh_user(Config, alice)],
    UnackedMessages = three_texts(),
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->
        {_, SMID} = buffer_unacked_messages_and_die(Config, AliceSpec, Bob, UnackedMessages),
        %% Resume the session.
        Alice = escalus_connection:connect(AliceSpec),

        Username = proplists:get_value(username, AliceSpec),
        Password = proplists:get_value(password, AliceSpec),
        Payload = <<0:8,Username/binary,0:8,Password/binary>>,
        Server = proplists:get_value(server, AliceSpec),

        Stream = escalus_stanza:stream_start(Server, <<"jabber:client">>),
        Auth = escalus_stanza:auth(<<"PLAIN">>, [#xmlcdata{content = base64:encode(Payload)}]),
        AuthStream = escalus_stanza:stream_start(Server, <<"jabber:client">>),
        Resume = escalus_stanza:resume(SMID, 2),

        escalus_client:send(Alice, [Stream, Auth, AuthStream, Resume]),
        Messages = [escalus_connection:get_stanza(Alice, {get_resumed, I}) || I <- lists:seq(1, 6)],
        escalus:assert(is_sm_resumed, [SMID], lists:last(Messages)),

        escalus_connection:stop(Alice)
    end).

%% This is a regression test for a case when a session processes a request, which will
%% receive a response from the server, i.e. will have the same origin SID in mongoose_acc.
%% Without proper handling, the reply would be rejected because the resumed session
%% has new SID.
replies_are_processed_by_resumed_session(Config) ->
    %% GIVEN a session and registered special IQ handler (added in init_per_testcase),
    %% that waits for old session process to terminate (at this point new process
    %% has fully taken over) and then actually sends the reply.
    Alice = connect_fresh(Config, alice, sr_presence),

    %% WHEN a client sends IQ request to the special handler...
    IQReq = escalus_stanza:iq_get(regression_ns(), []),
    escalus:send(Alice, IQReq),

    %% ... goes down and session is resumed.
    Alice2 = kill_and_connect_resume(Alice),

    %% THEN the client receives the reply properly.
    IQReply = escalus:wait_for_stanza(Alice2),
    escalus:assert(is_iq_result, [IQReq], IQReply),
    escalus_connection:stop(Alice2).

%% This is a regression test for a bug, which manifested in following scenario
%% (due to improper presence sub requests buffering):
%% 1. A is online, B is offline
%% 2. A subscribes to B's presence;
%% 3. B becomes online
%% 4. A sends a message to B
%% 5. B doesn't SM-ack the request or message, terminates the connection
%% 6. B reconnects but with session *replace*, not resume
%% 7. Packet rerouting crashes on the buffered sub request, preventing resending whole buffer
%% 8. B doesn't receive the buffered message
subscription_requests_are_buffered_properly(Config) ->
    AliceSpec = [{manual_ack, true} | escalus_fresh:create_fresh_user(Config, alice)],
    MsgBody = <<"buffered">>,
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->
        % GIVEN Bob's pending subscription to Alice's presence
        AliceJid = common_helper:get_bjid(AliceSpec),
        escalus:send(Bob, escalus_stanza:presence_direct(AliceJid, <<"subscribe">>)),
        _RosterPushReq = escalus:wait_for_stanza(Bob),

        % WHEN Alice becomes online...
        Alice = connect_spec(AliceSpec, sr_session),
        send_initial_presence(Alice),
        %% subscribe could come before the initial presence
        escalus:assert_many([is_presence(<<"available">>), is_presence(<<"subscribe">>)],
                            escalus:wait_for_stanzas(Alice, 2)),

        % ...and Bob sends a message to Alice...
        escalus:send(Bob, escalus_stanza:chat_to(Alice, MsgBody)),
        MsgStanza = escalus:wait_for_stanza(Alice),
        escalus:assert(is_chat_message, [MsgBody], MsgStanza),

        % ...and Alice terminates connection without acking anything...
        escalus_client:kill_connection(Config, Alice),

        % ...and reconnects with session replacement.
        Alice2 = connect_spec(AliceSpec, session),

        % THEN Alice receives (without sending initial presence):
        % * buffered available presence (because it's addressed to full JID)
        % * buffered Bob's message (like above)
        % Alice DOESN'T receive:
        % * buffered subscription request because it is dropped by ejabberd_sm
        %   because it's treated like repeated sub request to bare JID, so it's not
        %   processed by any sub req handler (like mod_roster)
        escalus:assert_many([is_presence(<<"available">>), is_chat(MsgBody)],
                            escalus:wait_for_stanzas(Alice2, 2)),

        escalus_connection:stop(Alice2)
    end).

%% This is a regression test for a bug, due to which messages sent to old session
%% in a middle of state handover were not appended properly to SM buffer.
%% Scenario to reproduce:
%% 1. Online Bob and Alice
%% 2. Alice kills the connection
%% 3. Alice's session is suspended
%% 4. Alice resumes session with new connection. At this moment new session is still not
%%    present in session table. `resume` request is stuck in old proc mailbox.
%% 5. Bob sends a message to Alice. Only old proc is present in session table so now
%%    old session has two messages in mailbox: `resume` and XML from Bob
%% 6. We resume old process and it begins session handover
%% 7. Bob's message is appended to SM buffer in "flush" step
%% 8. With bug fixed, the message is retransmitted properly
messages_are_properly_flushed_during_resumption(Config) ->
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->
        % GIVEN (online Bob) and (Alice in resume state); Alice's session is suspended
        Alice = connect_fresh(Config, alice, sr_presence),
        SMH = escalus_connection:get_sm_h(Alice),
        escalus_client:kill_connection(Config, Alice),
        %% The receiver process would stop now
        C2SPid = mongoose_helper:get_session_pid(Alice),
        mongoose_helper:wait_for_c2s_state_name(C2SPid, resume_session),

        wait_for_queue_length(C2SPid, 0),
        ok = rpc(mim(), sys, suspend, [C2SPid]),

        % WHEN new session requests resumption
        % we wait until that old session has resumption request enqueued;
        % we need it to ensure the order of messages: resume first, Bob's chat second.
        % Actual wait and message sent by Bob is done in separate process
        % because new client start will block until old process is resumed

        MsgBody = <<"flush-regression">>,
        spawn_link(fun() ->
                      wait_for_queue_length(C2SPid, 1),

                      % Bob sends a message...
                      escalus:send(Bob, escalus_stanza:chat_to(Alice, MsgBody)),

                      % ...we ensure that a message is enqueued in Alice's session...
                      % (2 messages = resume request + Bob's message)
                      wait_for_queue_length(C2SPid, 2),

                      % ...and old process is resumed.
                      ok = rpc(mim(), sys, resume, [C2SPid])
              end),
        Alice2 = connect_resume(Alice, SMH),
        % THEN Alice's new session receives Bob's message
        RecvMsg = escalus:wait_for_stanza(Alice2),
        escalus:assert(is_chat_message, [MsgBody], RecvMsg)
      end).

messages_are_properly_flushed_during_resumption_p1_fsm_old(Config) ->
    %% the same as messages_are_properly_flushed_during_resumption,
    %% but tests that buffered by p1_fsm_old messages are delivered
    escalus:fresh_story(Config, [{bob, 1}], fun(Bob) ->
        Alice = connect_fresh(Config, alice, sr_presence),
        SMH = escalus_connection:get_sm_h(Alice),
        escalus_client:kill_connection(Config, Alice),
        C2SPid = mongoose_helper:get_session_pid(Alice),
        mongoose_helper:wait_for_c2s_state_name(C2SPid, resume_session),
        ok = rpc(mim(), sys, suspend, [C2SPid]),

        %% send some dummy event. ignored by c2s but ensures that
        %% p1_old_fsm buffers the messages, sent after this one
        rpc(mim(), p1_fsm_old, send_all_state_event, [C2SPid, dummy_event]),

        MsgBody = <<"flush-regression">>,
        spawn_link(fun() ->
                    wait_for_queue_length(C2SPid, 2),

                    % Bob sends a message...
                    escalus:send(Bob, escalus_stanza:chat_to(Alice, MsgBody)),

                    % ...we ensure that a message is enqueued in Alice's session...
                    % (2 messages = resume request + Bob's message)
                    wait_for_queue_length(C2SPid, 3),

                    % ...and old process is resumed.
                    ok = rpc(mim(), sys, resume, [C2SPid])
              end),
        Alice2 = connect_resume(Alice, SMH),
        % THEN Alice's new session receives Bob's message
        RecvMsg = escalus:wait_for_stanza(Alice2),
        escalus:assert(is_chat_message, [MsgBody], RecvMsg)
      end).

no_crash_if_stream_mgmt_disabled_but_client_requests_stream_mgmt(Config) ->
    Alice = connect_fresh(Config, alice, session, manual),
    %% Should not crash anything!
    escalus_connection:send(Alice, escalus_stanza:enable_sm()),
    Response = escalus_connection:get_stanza(Alice, service_unavailable),
    escalus:assert(is_sm_failed, [<<"feature-not-implemented">>], Response),
    escalus_connection:stop(Alice).

no_crash_if_stream_mgmt_disabled_but_client_requests_stream_mgmt_with_resumption(Config) ->
    Alice = connect_fresh(Config, alice, session, manual),
    %% Should not crash anything!
    escalus_connection:send(Alice, escalus_stanza:enable_sm([resume])),
    Response = escalus_connection:get_stanza(Alice, service_unavailable),
    escalus:assert(is_sm_failed, [<<"feature-not-implemented">>], Response),
    escalus_connection:stop(Alice).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
start_hook_listener(Resource) ->
    TestCasePid = self(),
    rpc(mim(), ?MODULE, rpc_start_hook_handler, [TestCasePid, Resource, host_type()]).

stop_hook_listener(HookExtra) ->
    rpc(mim(), ?MODULE, rpc_stop_hook_handler, [HookExtra, host_type()]).

rpc_start_hook_handler(TestCasePid, User, HostType) ->
    LUser = jid:nodeprep(User),
    Extra = #{luser => LUser, pid => TestCasePid},
    gen_hook:add_handler(unacknowledged_message, HostType,
                         fun ?MODULE:hook_handler_fn/3,
                         Extra, 50),
    Extra.

rpc_stop_hook_handler(HookExtra, HostType) ->
    gen_hook:delete_handler(unacknowledged_message, HostType,
                            fun ?MODULE:hook_handler_fn/3,
                            HookExtra, 50).

hook_handler_fn(Acc,
                #{args := [Jid]} = _Params,
                #{luser := LUser, pid := TestCasePid} = _Extra) ->
    {U, _S, R} = jid:to_lower(Jid),
    case U of
        LUser ->
            Counter = mongoose_acc:get(sm_test, counter, 0, Acc),
            El = mongoose_acc:element(Acc),
            TestCasePid ! {sm_test, Counter, R, El},
            {ok, mongoose_acc:set_permanent(sm_test, counter, Counter + 1, Acc)};
        _ -> {ok, Acc}
    end.

wait_for_unacked_msg_hook(Counter, Res, Timeout) ->
    receive
        {sm_test, AccCounter, Resource, Stanza} = Msg ->
            ?assertEqual(Counter, AccCounter, Msg),
            ?assertEqual(Res, Resource, Msg),
            Stanza
    after Timeout ->
        timeout
    end.

is_chat(Content) ->
    fun(Stanza) -> escalus_pred:is_chat_message(Content, Stanza) end.

is_presence(Type) ->
    fun(Stanza) -> escalus_pred:is_presence_with_type(Type, Stanza) end.

three_texts() ->
    [<<"msg-1">>, <<"msg-2">>, <<"msg-3">>].

%%--------------------------------------------------------------------
%% IQ handler necessary for reproducing "replies_are_processed_by_resumed_session"
%%--------------------------------------------------------------------

regression_ns() ->
    <<"regression">>.

register_handler() ->
    HostType = host_type(),
    rpc(mim(), gen_iq_handler, add_iq_handler_for_domain,
        [HostType, regression_ns(), ejabberd_sm,
         fun ?MODULE:regression_handler/5, #{}, one_queue]).

unregister_handler() ->
    HostType = host_type(),
    rpc(mim(), gen_iq_handler, remove_iq_handler_for_domain,
        [HostType, regression_ns(), ejabberd_sm]).

regression_handler(Acc, _From, _To, IQ, _Extra) ->
    %% A bit of a hack - will no longer work when the SID format changes
    {_, Pid} = mongoose_acc:get(c2s, origin_sid, undefined, Acc),
    erlang:monitor(process, Pid),
    receive
        {'DOWN', _, _, _, _} ->
            ok
    after
        10000 ->
            error({c2s_not_stopped_after_timeout, Pid})
    end,
    %% We avoid another race condition - there is a short window where user session
    %% is not registered in ejabberd_sm: between old process termination and the moment
    %% when the new process stores new session in memory. It should be fixed separately.
    wait_for_session(mongoose_acc:get(c2s, origin_jid, undefined, Acc), 50, 100),
    {Acc, jlib:make_result_iq_reply(IQ)}.

wait_for_session(JID, Retries, SleepTime) ->
    case ejabberd_sm:get_session(JID) of
        offline ->
            timer:sleep(SleepTime),
            wait_for_session(JID, Retries - 1, SleepTime);
        _ ->
            ok
    end.
