%% @doc The mcl_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.
%%
%% A SENSOR, NOT A SERVER. It polls public news sources and reports each new
%% item as a fact (mcl_news_facts). It offers no procedure, so it announces no
%% capability, and like mcl-warden it publishes under its own verified identity,
%% so it asks the realm for no extra authority. It holds no store: its only
%% memory is a bounded set of item ids already reported, rebuilt on restart.
-module(mcl_news_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{name => <<"mcl-news">>,
      version => <<"0.1.0">>,
      description => <<"Sovereign news sensor: polls public RSS/Atom sources and reports each new item as a mesh fact">>}.

%% The realm name the topic carries is checked against the realm the pool
%% publishes in before the sensor starts.
start(_Opts) ->
    ok = mcl_news_facts:check_realm_name(),
    mcl_news_sup:start_link().

stop(_State) -> ok.

%% Green once the sensor runs. A source being down is not a health failure (the
%% sensor keeps polling the rest), and neither is a dark mesh (facts are dropped
%% until it returns), both deliberately.
health() -> ok.

%% A sensor offers no procedure: it reports facts, and consumers subscribe.
capabilities() -> [].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
%%
%% The scope is claimed now because it is the namespace every later resource
%% hangs under, and a scope costs nothing while a rename costs every deployed
%% peer.
identity_spec() ->
    #{scope => <<"mcl-news">>,
      actions => [],
      resources => [],
      ttl_days => 30}.
