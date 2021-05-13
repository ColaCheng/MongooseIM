-module(mongoose_subdomain_core_SUITE).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-define(STATIC_HOST_TYPE, <<"static type">>).
-define(STATIC_DOMAIN, <<"example.com">>).
-define(DYNAMIC_HOST_TYPE1, <<"dynamic type #1">>).
-define(DYNAMIC_HOST_TYPE2, <<"dynamic type #2">>).
-define(DYNAMIC_DOMAINS, [<<"localhost">>, <<"local.host">>]).
-define(STATIC_PAIRS, [{?STATIC_DOMAIN, ?STATIC_HOST_TYPE}]).
-define(ALLOWED_HOST_TYPES, [?DYNAMIC_HOST_TYPE1, ?DYNAMIC_HOST_TYPE2]).

-define(assertEqualLists(L1, L2), ?assertEqual(lists:sort(L1), lists:sort(L2))).

all() ->
    [can_register_and_unregister_subdomain,
     can_register_and_unregister_fqdn,
     can_add_and_remove_domain,
     can_get_host_type_and_subdomain_details,
     handles_domain_removal_during_subdomain_registration,
     prevents_subdomain_overriding,
     detects_domain_subdomain_collisions].

init_per_suite(Config) ->
    meck:new(mongoose_hooks, [no_link]),
    meck:new(mongoose_subdomain_core, [no_link, passthrough]),
    meck:expect(mongoose_hooks, disable_domain, fun(_, _) -> ok end),
    meck:expect(mongoose_hooks, disable_subdomain, fun(_, _) -> ok end),
    Config.

end_per_suite(Config) ->
    meck:unload(),
    Config.

init_per_testcase(_, Config) ->
    %% mongoose_domain_core preconditions:
    %%   - one "static" host type with only one configured domain name
    %%   - one "dynamic" host type without any configured domain names
    %%   - one "dynamic" host type with two configured domain names
    %% initial mongoose_subdomain_core conditions:
    %%   - no subdomains configured for any host type
    ok = mongoose_domain_core:start(?STATIC_PAIRS, ?ALLOWED_HOST_TYPES),
    ok = mongoose_subdomain_core:start(),
    [mongoose_domain_core:insert(Domain, ?DYNAMIC_HOST_TYPE2, dummy_source)
     || Domain <- ?DYNAMIC_DOMAINS],
    [meck:reset(M) || M <- [mongoose_hooks, mongoose_subdomain_core]],
    Config.

end_per_testcase(_, Config) ->
    mongoose_domain_core:stop(),
    mongoose_subdomain_core:stop(),
    Config.

%%-------------------------------------------------------------------
%% test cases
%%-------------------------------------------------------------------
can_register_and_unregister_subdomain(_Config) ->
    ?assertEqual(0, get_subdomains_table_size()),
    Handler = mongoose_packet_handler:new(?MODULE),
    Pattern1 = mongoose_subdomain_utils:make_subdomain_pattern("subdomain.@HOST@"),
    Pattern2 = mongoose_subdomain_utils:make_subdomain_pattern("subdomain2.@HOST@"),
    Subdomains1 = [mongoose_subdomain_utils:get_fqdn(Pattern1, Domain)
                          || Domain <- [?STATIC_DOMAIN | ?DYNAMIC_DOMAINS]],
    Subdomains2 = [mongoose_subdomain_utils:get_fqdn(Pattern2, Domain)
                          || Domain <- ?DYNAMIC_DOMAINS],
    %% register one "prefix" subdomain for static host type.
    %% check that ETS table contains all the expected subdomains and nothing else.
    %% make a snapshot of subdomains ETS table and check its size.
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?STATIC_HOST_TYPE,
                                                                Pattern1, Handler)),
    ?assertEqualLists(get_all_subdomains(), [hd(Subdomains1)]),
    TableSnapshot1 = get_subdomains_table(),
    ?assertEqual(1, get_subdomains_table_size()),
    %% register one "prefix" subdomain for dynamic host type with 2 domains.
    %% check that ETS table contains all the expected subdomains and nothing else.
    %% make a snapshot of subdomains ETS table and check its size.
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                Pattern1, Handler)),
    ?assertEqualLists(get_all_subdomains(), Subdomains1),
    TableSnapshot2 = get_subdomains_table(),
    ?assertEqual(1 + length(?DYNAMIC_DOMAINS), get_subdomains_table_size()),
    %% register one more "prefix" subdomain for dynamic host type with 2 domains.
    %% check that ETS table contains all the expected subdomains and nothing else.
    %% make a snapshot of subdomains ETS table and check its size.
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                Pattern2, Handler)),
    ?assertEqualLists(get_all_subdomains(), Subdomains1 ++ Subdomains2),
    TableSnapshot3 = get_subdomains_table(),
    ?assertEqual(1 + 2 * length(?DYNAMIC_DOMAINS), get_subdomains_table_size()),
    %% check mongoose_subdomain_core:get_all_subdomains_for_domain/1 interface.
    [DynamicDomain | _] = ?DYNAMIC_DOMAINS,
    ?assertEqualLists(
        [#{host_type => ?DYNAMIC_HOST_TYPE2, subdomain_pattern => Pattern1,
           parent_domain => DynamicDomain, packet_handler => Handler,
           subdomain => mongoose_subdomain_utils:get_fqdn(Pattern1, DynamicDomain)},
         #{host_type => ?DYNAMIC_HOST_TYPE2, subdomain_pattern => Pattern2,
           parent_domain => DynamicDomain, packet_handler => Handler,
           subdomain => mongoose_subdomain_utils:get_fqdn(Pattern2, DynamicDomain)}],
        mongoose_subdomain_core:get_all_subdomains_for_domain(DynamicDomain)),
    %% register two "prefix" subdomains for dynamic host type with 0 domains.
    %% check that ETS table doesn't contain any new subdomains.
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern1, Handler)),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern2, Handler)),
    ?assertEqualLists(TableSnapshot3, get_subdomains_table()),
    %% unregister (previously registered) subdomains one by one.
    %% check that ETS table rolls back to the previously made snapshots.
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                  Pattern2)),
    ?assertEqualLists(TableSnapshot2, get_subdomains_table()),
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                  Pattern1)),
    ?assertEqualLists(TableSnapshot1, get_subdomains_table()),
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?STATIC_HOST_TYPE,
                                                                  Pattern1)),
    ?assertEqual(0, get_subdomains_table_size()),
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                  Pattern1)),
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                  Pattern2)),
    ?assertEqualLists(Subdomains1 ++ Subdomains2, get_list_of_disabled_subdomains()),
    no_collisions().

can_register_and_unregister_fqdn(_Config) ->
    Pattern1 = mongoose_subdomain_utils:make_subdomain_pattern("some.fqdn"),
    Pattern2 = mongoose_subdomain_utils:make_subdomain_pattern("another.fqdn"),
    Pattern3 = mongoose_subdomain_utils:make_subdomain_pattern("yet.another.fqdn"),
    Pattern4 = mongoose_subdomain_utils:make_subdomain_pattern("one.more.fqdn"),
    Handler = mongoose_packet_handler:new(?MODULE),
    ?assertEqual(0, get_subdomains_table_size()),
    %% register one "fqdn" subdomain for static host type.
    %% check that ETS table contains all the expected subdomains and nothing else.
    %% make a snapshot of subdomains ETS table.
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?STATIC_HOST_TYPE,
                                                                Pattern1, Handler)),
    ?assertEqualLists(get_all_subdomains(), [<<"some.fqdn">>]),
    TableSnapshot1 = get_subdomains_table(),
    %% register one "fqdn" subdomain for dynamic host type with 0 domains.
    %% make a snapshot of subdomains ETS table and check its size.
    %% check mongoose_subdomain_core:get_all_subdomains_for_domain/1 interface.
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern2, Handler)),
    TableSnapshot2 = get_subdomains_table(),
    ?assertEqual(2, get_subdomains_table_size()),
    ?assertEqualLists(
        [#{host_type => ?STATIC_HOST_TYPE, parent_domain => no_parent_domain,
           subdomain_pattern => Pattern1, packet_handler => Handler,
           subdomain => <<"some.fqdn">>},
         #{host_type => ?DYNAMIC_HOST_TYPE1, parent_domain => no_parent_domain,
           subdomain_pattern => Pattern2, packet_handler => Handler,
           subdomain => <<"another.fqdn">>}],
        mongoose_subdomain_core:get_all_subdomains_for_domain(no_parent_domain)),
    %% register one "fqdn" subdomain for dynamic host type with 2 domains.
    %% check that ETS table contains all the expected subdomains and nothing else.
    %% make a snapshot of subdomains ETS table.
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                Pattern3, Handler)),
    ?assertEqualLists(get_all_subdomains(), [<<"some.fqdn">>, <<"another.fqdn">>,
                                             <<"yet.another.fqdn">>]),
    TableSnapshot3 = get_subdomains_table(),
    %% register one more "fqdn" subdomain for dynamic host type with 2 domains.
    %% check that ETS table contains all the expected subdomains and nothing else.
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                Pattern4, Handler)),
    ?assertEqualLists(get_all_subdomains(), [<<"some.fqdn">>, <<"yet.another.fqdn">>,
                                             <<"another.fqdn">>, <<"one.more.fqdn">>]),
    %% unregister (previously registered) subdomains one by one.
    %% check that ETS table rolls back to the previously made snapshots.
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                  Pattern4)),
    ?assertEqualLists(TableSnapshot3, get_subdomains_table()),
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                  Pattern3)),
    ?assertEqualLists(TableSnapshot2, get_subdomains_table()),
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                  Pattern2)),
    ?assertEqualLists(TableSnapshot1, get_subdomains_table()),
    ?assertEqual(ok, mongoose_subdomain_core:unregister_subdomain(?STATIC_HOST_TYPE,
                                                                  Pattern1)),
    ?assertEqual(0, get_subdomains_table_size()),
    ?assertEqualLists([<<"some.fqdn">>, <<"yet.another.fqdn">>,
                       <<"another.fqdn">>, <<"one.more.fqdn">>],
                      get_list_of_disabled_subdomains()),
    no_collisions().

can_add_and_remove_domain(_Config) ->
    Pattern1 = mongoose_subdomain_utils:make_subdomain_pattern("subdomain.@HOST@"),
    Pattern2 = mongoose_subdomain_utils:make_subdomain_pattern("subdomain2.@HOST@"),
    Pattern3 = mongoose_subdomain_utils:make_subdomain_pattern("some.fqdn"),
    Handler = mongoose_packet_handler:new(?MODULE),
    Subdomains1 = [mongoose_subdomain_utils:get_fqdn(Pattern1, Domain)
                   || Domain <- ?DYNAMIC_DOMAINS],
    Subdomains2 = [mongoose_subdomain_utils:get_fqdn(Pattern2, Domain)
                   || Domain <- ?DYNAMIC_DOMAINS],
    ?assertEqual(0, get_subdomains_table_size()),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                Pattern1, Handler)),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                Pattern2, Handler)),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                Pattern3, Handler)),
    ?assertEqualLists([<<"some.fqdn">> | Subdomains1 ++ Subdomains2],
                      get_all_subdomains()),
    TableSnapshot = get_subdomains_table(),
    [DynamicDomain | _] = ?DYNAMIC_DOMAINS,
    mongoose_domain_core:delete(DynamicDomain),
    mongoose_subdomain_core:sync(),
    ?assertEqualLists([<<"some.fqdn">> | tl(Subdomains1) ++ tl(Subdomains2)],
                      get_all_subdomains()),
    mongoose_domain_core:insert(DynamicDomain, ?DYNAMIC_HOST_TYPE2, dummy_source),
    mongoose_subdomain_core:sync(),
    ?assertEqualLists(TableSnapshot, get_subdomains_table()),
    ?assertEqualLists([hd(Subdomains1), hd(Subdomains2)],
                      get_list_of_disabled_subdomains()),
    no_collisions().

can_get_host_type_and_subdomain_details(_Config) ->
    Pattern1 = mongoose_subdomain_utils:make_subdomain_pattern("subdomain.@HOST@"),
    Pattern2 = mongoose_subdomain_utils:make_subdomain_pattern("some.fqdn"),
    Handler = mongoose_packet_handler:new(?MODULE),
    Subdomain1 = mongoose_subdomain_utils:get_fqdn(Pattern1, ?STATIC_DOMAIN),
    Subdomain2 = mongoose_subdomain_utils:get_fqdn(Pattern1, hd(?DYNAMIC_DOMAINS)),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?STATIC_HOST_TYPE,
                                                                Pattern1, Handler)),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                                Pattern1, Handler)),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern2, Handler)),
    ?assertEqual({ok, ?STATIC_HOST_TYPE},
                 mongoose_subdomain_core:get_host_type(Subdomain1)),
    ?assertEqual({ok, ?DYNAMIC_HOST_TYPE1},
                 mongoose_subdomain_core:get_host_type(<<"some.fqdn">>)),
    ?assertEqual({ok, ?DYNAMIC_HOST_TYPE2},
                 mongoose_subdomain_core:get_host_type(Subdomain2)),
    ?assertEqual({error, not_found},
                 mongoose_subdomain_core:get_host_type(<<"unknown.subdomain">>)),
    ?assertEqual({ok, #{host_type => ?STATIC_HOST_TYPE, subdomain_pattern => Pattern1,
                        parent_domain => ?STATIC_DOMAIN, packet_handler => Handler,
                        subdomain => Subdomain1}},
                 mongoose_subdomain_core:get_subdomain_info(Subdomain1)),
    ?assertEqual({ok, #{host_type => ?DYNAMIC_HOST_TYPE1, subdomain_pattern => Pattern2,
                        parent_domain => no_parent_domain, packet_handler => Handler,
                        subdomain => <<"some.fqdn">>}},
                 mongoose_subdomain_core:get_subdomain_info(<<"some.fqdn">>)),
    ?assertEqual({ok, #{host_type => ?DYNAMIC_HOST_TYPE2, subdomain_pattern => Pattern1,
                        parent_domain => hd(?DYNAMIC_DOMAINS), packet_handler => Handler,
                        subdomain => Subdomain2}},
                 mongoose_subdomain_core:get_subdomain_info(Subdomain2)),
    ?assertEqual({error, not_found},
                 mongoose_subdomain_core:get_subdomain_info(<<"unknown.subdomain">>)),
    ok.

handles_domain_removal_during_subdomain_registration(_Config) ->
    %% NumOfDomains is just some big non-round number to ensure that more than 2 ets
    %% selections are done during the call to mongoose_domain_core:for_each_domain/2.
    %% currently max selection size is 100 domains.
    NumOfDomains = 1234,
    NumOfDomainsToRemove = 1234 div 4,
    NewDomains = [<<"dummy_domain_", (integer_to_binary(N))/binary, ".localhost">>
                  || N <- lists:seq(1, NumOfDomains)],
    [mongoose_domain_core:insert(Domain, ?DYNAMIC_HOST_TYPE1, dummy_src)
     || Domain <- NewDomains],
    meck:new(mongoose_domain_core, [passthrough]),
    WrapperFn = make_wrapper_fn(NumOfDomainsToRemove * 2, NumOfDomainsToRemove),
    meck:expect(mongoose_domain_core, for_each_domain,
                fun(HostType, Fn) ->
                    meck:passthrough([HostType, WrapperFn(Fn)])
                end),
    Pattern1 = mongoose_subdomain_utils:make_subdomain_pattern("subdomain.@HOST@"),
    Handler = mongoose_packet_handler:new(?MODULE),
    %% Note that mongoose_domain_core:for_each_domain/2 is used to register subdomain.
    %% some domains are removed during subdomain registration, see make_wrapper_fn/2
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern1, Handler)),
    mongoose_subdomain_core:sync(),
    ?assertEqual(NumOfDomains - NumOfDomainsToRemove, get_subdomains_table_size()),
    AllDomains = mongoose_domain_core:get_domains_by_host_type(?DYNAMIC_HOST_TYPE1),
    AllExpectedSubDomains = [mongoose_subdomain_utils:get_fqdn(Pattern1, Domain)
                             || Domain <- AllDomains],
    %% also try to add some domains second time, as this is also possible
    %% during subdomain_registration
    [RegisteredDomain1, RegisteredDomain2 | _] = AllDomains,
    mongoose_subdomain_core:add_domain(?DYNAMIC_HOST_TYPE1, RegisteredDomain1),
    mongoose_subdomain_core:add_domain(?DYNAMIC_HOST_TYPE1, RegisteredDomain2),
    mongoose_subdomain_core:sync(),
    ?assertEqualLists(AllExpectedSubDomains, get_all_subdomains()),
    ?assertEqual(NumOfDomainsToRemove,
                 meck:num_calls(mongoose_hooks, disable_subdomain, 2)),

    no_collisions(),
    meck:unload(mongoose_domain_core).

prevents_subdomain_overriding(_Config) ->
    %% There are three possible subdomain names collisions:
    %%   1) Different domain/subdomain_pattern pairs produce one and the same subdomain.
    %%   2) Attempt to register the same FQDN subdomain for 2 different host types.
    %%   3) Domain/subdomain_pattern pair produces the same subdomain name as another
    %%      FQDN subdomain.
    %%
    %% Collisions of the first type can eliminated by allowing only one level subdomains,
    %% e.g. ensuring that subdomain template corresponds to this regex "^[^.]*\.@HOST@$".
    %%
    %% Collisions of the second type are less critical as they can be detected during
    %% init phase - they result in {error, subdomain_already_exists} return code, so
    %% modules can detect it and crash at ?MODULE:start/2.
    %%
    %% Third type is hard to resolve in automatic way. One of the options is to ensure
    %% that FQDN subdomains don't start with the same "prefix" as subdomain patterns.
    %%
    %% It's good idea to create a metric for such collisions, so devops can set some
    %% alarm and react on it.
    %%
    %% The current behaviour rejects insertion of the conflicting subdomain, the original
    %% subdomain must remain unchanged
    Pattern1 = mongoose_subdomain_utils:make_subdomain_pattern("sub.@HOST@"),
    Pattern2 = mongoose_subdomain_utils:make_subdomain_pattern("sub.domain.@HOST@"),
    Pattern3 = mongoose_subdomain_utils:make_subdomain_pattern("sub.domain.fqdn"),
    Handler = mongoose_packet_handler:new(?MODULE),
    %%----------------------------------------------------------------
    %% testing type #1 subdomain names collision + double registration
    %%----------------------------------------------------------------
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern1, Handler)),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern2, Handler)),
    ?assertEqual({error, already_registered},
                 mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                            Pattern2, Handler)),
    mongoose_domain_core:insert(<<"test">>, ?DYNAMIC_HOST_TYPE1, dummy_src),
    mongoose_domain_core:insert(<<"domain.test">>, ?DYNAMIC_HOST_TYPE1, dummy_src),
    mongoose_subdomain_core:sync(),
    ?assertEqual(3, get_subdomains_table_size()),
    ExpectedSubdomainInfo =
        #{host_type => ?DYNAMIC_HOST_TYPE1, subdomain_pattern => Pattern2,
          parent_domain => <<"test">>, packet_handler => Handler,
          subdomain => <<"sub.domain.test">>},
    ?assertEqual({ok, ExpectedSubdomainInfo} ,
                 mongoose_subdomain_core:get_subdomain_info(<<"sub.domain.test">>)),
    %% check that removal of "domain.test" doesn't affect "sub.domain.test" subdomain
    mongoose_domain_core:delete("domain.test"),
    mongoose_subdomain_core:sync(),
    ?assertEqual({ok, ExpectedSubdomainInfo},
                 mongoose_subdomain_core:get_subdomain_info(<<"sub.domain.test">>)),
    %%----------------------------------------------------------------
    %% testing type #2 subdomain names collision + double registration
    %%----------------------------------------------------------------
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern3, Handler)),
    ?assertEqual({error, already_registered},
                 mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                            Pattern3, Handler)),
    ?assertEqual({error, subdomain_already_exists},
                 mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE2,
                                                            Pattern3, Handler)),

    ?assertEqual(4, get_subdomains_table_size()),
    ?assertEqual({ok,#{host_type => ?DYNAMIC_HOST_TYPE1, subdomain_pattern => Pattern3,
                       parent_domain => no_parent_domain, packet_handler => Handler,
                       subdomain => <<"sub.domain.fqdn">>}},
                 mongoose_subdomain_core:get_subdomain_info(<<"sub.domain.fqdn">>)),
    %%------------------------------------------
    %% testing type #3 subdomain names collision
    %%------------------------------------------
    mongoose_domain_core:insert(<<"fqdn">>, ?DYNAMIC_HOST_TYPE1, dummy_src),
    mongoose_subdomain_core:sync(),
    ?assertEqual(5, get_subdomains_table_size()),
    ?assertEqual({ok, #{host_type => ?DYNAMIC_HOST_TYPE1, subdomain_pattern => Pattern3,
                        parent_domain => no_parent_domain, packet_handler => Handler,
                        subdomain => <<"sub.domain.fqdn">>}},
                 mongoose_subdomain_core:get_subdomain_info(<<"sub.domain.fqdn">>)),
    %%---------------------------------------
    %% check that all collisions are detected
    %%---------------------------------------
    ?assertEqual([#{what => subdomains_collision, subdomain => <<"sub.domain.test">>},
                  #{what => subdomains_collision, subdomain => <<"sub.domain.fqdn">>},
                  #{what => subdomains_collision, subdomain => <<"sub.domain.fqdn">>}],
                 get_list_of_subdomain_collisions()),
    no_domain_collisions().

detects_domain_subdomain_collisions(_Config) ->
    %% There are two possible domain/subdomain names collisions:
    %%   1) Domain/subdomain_pattern pair produces the same subdomain name as another
    %%      existing top level domain
    %%   2) FQDN subdomain is the same as some registered top level domain
    %%
    %% The naive domain/subdomain registration rejection is probably a bad option:
    %%   * Domains and subdomains ETS tables are managed asynchronously, in addition to
    %%     that subdomains patterns registration is done async as well. This all leaves
    %%     room for various race conditions if we try to just make a verification and
    %%     prohibit domain/subdomain registration in case of any collisions.
    %%   * The only way to avoid such race conditions is to block all async. ETSs
    %%     editing during the validation process, but this can result in big delays
    %%     during the MIM initialisation phase.
    %%   * Also it's not clear how to interpret registration of the "prefix" based
    %%     subdomain patterns, should we block the registration of the whole pattern
    %%     or just only conflicting subdomains registration. Blocking of the whole
    %%     pattern requires generation and verification of all the subdomains (with
    %%     ETS blocking during that process), which depends on domains ETS size and
    %%     might take too long.
    %%   * And the last big issue with simple registration rejection approach, different
    %%     nodes in the cluster might have different registration sequence. So we may
    %%     end up in a situation when some nodes registered domain name as a subdomain,
    %%     while other nodes registered it as a top level domain.
    %%
    %% The better way is to prohibit registration of a top level domain if it is equal
    %% to any of the FQDN subdomains or if beginning of domain name matches the prefix
    %% of any subdomain template. In this case we don't need to verify subdomains at all,
    %% verification of domain names against some limited number of subdomains patterns is
    %% enough. And the only problem that we need to solve - mongooseim_domain_core must
    %% be aware of all the subdomain patterns before it registers the first dynamic
    %% domain. This would require minor configuration rework, e.g. tracking of subdomain
    %% templates preprocessing (mongoose_subdomain_utils:make_subdomain_pattern/1 calls)
    %% during TOML config parsing.
    %%
    %% It's good idea to create a metric for such collisions, so devops can set some
    %% alarm and react on it.
    %%
    %% The current behaviour just ensures detection of the domain/subdomain names
    %% collision, both (domain and subdomain) records remain unchanged in the
    %% corresponding ETS tables
    Pattern1 = mongoose_subdomain_utils:make_subdomain_pattern("subdomain.@HOST@"),
    Pattern2 = mongoose_subdomain_utils:make_subdomain_pattern("some.fqdn"),
    Pattern3 = mongoose_subdomain_utils:make_subdomain_pattern("another.fqdn"),
    Handler = mongoose_packet_handler:new(?MODULE),
    %%------------------------------------------
    %% testing type #1 subdomain names collision
    %%------------------------------------------
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern1, Handler)),
    mongoose_domain_core:insert(<<"test.net">>, ?DYNAMIC_HOST_TYPE1, dummy_src),
    %% without this sync call "subdomain.example.net" collision can be detected
    %% twice, one time by check_subdomain_name/1 function and then second time
    %% by check_domain_name/2.
    mongoose_subdomain_core:sync(),
    mongoose_domain_core:insert(<<"subdomain.test.net">>, ?DYNAMIC_HOST_TYPE2,
                                dummy_src),
    mongoose_domain_core:insert(<<"subdomain.test.org">>, ?DYNAMIC_HOST_TYPE2,
                                dummy_src),
    mongoose_domain_core:insert(<<"test.org">>, ?DYNAMIC_HOST_TYPE1, dummy_src),
    mongoose_subdomain_core:sync(),
    ?assertEqualLists([<<"subdomain.test.org">>, <<"subdomain.test.net">>],
                      get_all_subdomains()),
    ?assertEqualLists(
        [<<"subdomain.test.org">>, <<"subdomain.test.net">> | ?DYNAMIC_DOMAINS],
        mongoose_domain_core:get_domains_by_host_type(?DYNAMIC_HOST_TYPE2)),
    no_subdomain_collisions(),
    ?assertEqual(
        [#{what => check_domain_name_failed, domain => <<"subdomain.test.net">>},
         #{what => check_subdomain_name_failed, subdomain => <<"subdomain.test.org">>}],
        get_list_of_domain_collisions()),
    %% cleanup
    meck:reset(mongoose_subdomain_core),
    Domains = [<<"subdomain.test.net">>, <<"subdomain.test.org">>,
               <<"test.net">>, <<"test.org">>],
    [mongoose_domain_core:delete(Domain) || Domain <- Domains],
    %%------------------------------------------
    %% testing type #2 subdomain names collision
    %%------------------------------------------
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern2, Handler)),
    mongoose_domain_core:insert(<<"some.fqdn">>, ?DYNAMIC_HOST_TYPE2, dummy_src),
    mongoose_domain_core:insert(<<"another.fqdn">>, ?DYNAMIC_HOST_TYPE2, dummy_src),
    ?assertEqual(ok, mongoose_subdomain_core:register_subdomain(?DYNAMIC_HOST_TYPE1,
                                                                Pattern3, Handler)),
    ?assertEqualLists([<<"some.fqdn">>, <<"another.fqdn">>], get_all_subdomains()),
    ?assertEqualLists(
        [<<"some.fqdn">>, <<"another.fqdn">> | ?DYNAMIC_DOMAINS],
        mongoose_domain_core:get_domains_by_host_type(?DYNAMIC_HOST_TYPE2)),
    no_subdomain_collisions(),
    ?assertEqual(
        [#{what => check_domain_name_failed, domain => <<"some.fqdn">>},
         #{what => check_subdomain_name_failed, subdomain => <<"another.fqdn">>}],
        get_list_of_domain_collisions()).

%%-------------------------------------------------------------------
%% internal functions
%%-------------------------------------------------------------------
get_subdomains_table() ->
    ets:tab2list(mongoose_subdomain_core).

get_subdomains_table_size() ->
    ets:info(mongoose_subdomain_core, size).

get_all_subdomains() ->
    %% mongoose_subdomain_core table is indexed by subdomain name field
    KeyPos = ets:info(mongoose_subdomain_core, keypos),
    [element(KeyPos, Item) || Item <- ets:tab2list(mongoose_subdomain_core)].

make_wrapper_fn(N, M) when N > M ->
    %% the wrapper function generates a new loop processing function
    %% that pauses after after processing N domains, removes M of the
    %% already processed domains and resumes after that.
    fun(Fn) ->
        put(number_of_iterations, 0),
        fun(HostType, DomainName) ->
            NumberOfIterations = get(number_of_iterations),
            if
                NumberOfIterations =:= N -> remove_some_domains_async(M);
                true -> ok
            end,
            put(number_of_iterations, NumberOfIterations + 1),
            Fn(HostType, DomainName)
        end
    end.

remove_some_domains_async(N) ->
    {Pid, Ref} = spawn_monitor(fun() -> remove_some_domains(N) end),
    receive
        {'DOWN', Ref, process, Pid, _Info} -> ok
    end.

remove_some_domains(N) ->
    AllSubdomains = get_all_subdomains(),
    [begin
         {ok, Info} = mongoose_subdomain_core:get_subdomain_info(Subdomain),
         ParentDomain = maps:get(parent_domain, Info),
         mongoose_domain_core:delete(ParentDomain)
     end || Subdomain <- lists:sublist(AllSubdomains, N)].

no_collisions() ->
    no_domain_collisions(),
    no_subdomain_collisions().

no_domain_collisions() ->
    Hist = meck:history(mongoose_subdomain_core),
    Errors = [Call || {_P, {_M, log_error = _F, [From, _] = _A}, _R} = Call <- Hist,
                      From =:= check_subdomain_name orelse From =:= check_domain_name],
    ?assertEqual([], Errors).

get_list_of_domain_collisions() ->
    Hist = meck:history(mongoose_subdomain_core),
    [Error || {_Pid, {_Mod, log_error = _Func, [From, Error] = _Args}, _Result} <- Hist,
               From =:= check_subdomain_name orelse From =:= check_domain_name].

no_subdomain_collisions() ->
    Hist = meck:history(mongoose_subdomain_core),
    Errors = [Call || {_P, {_M, log_error = _F, [From, _] = _A}, _R} = Call <- Hist,
                      From =:= report_subdomains_collision],
    ?assertEqual([], Errors).

get_list_of_subdomain_collisions() ->
    Hist = meck:history(mongoose_subdomain_core),
    [Error || {_Pid, {_Mod, log_error = _Func, [From, Error] = _Args}, _Result} <- Hist,
               From =:= report_subdomains_collision].

get_list_of_disabled_subdomains() ->
    History = meck:history(mongoose_hooks),
    [lists:nth(2, Args) %% Subdomain is the second argument
     || {_Pid, {_Mod, disable_subdomain = _Func, Args}, _Result} <- History].
