%%% @doc The news sensor: poll sovereign sources, dedupe, publish to the feed.
%%%
%%% On a heartbeat it fetches each configured RSS/Atom source over HTTPS (certs
%%% verified against the system CA store with pure OTP — inets + ssl, no Big-Tech
%%% SDK), parses it (parse_feed), and for every item it has not seen before it
%%% reports a `news_item_reported' fact (mcl_news_facts). It holds no store: the
%%% only memory is a BOUNDED in-process set of item ids already announced, so a
%%% poll never re-announces old news. That set is disposable and rebuilt on
%%% restart.
%%%
%%% First poll primes, it does not flood: the whole current backlog is marked
%%% seen (only the newest few per source are published as a seed), so a fresh
%%% boot does not report hundreds of old articles at once. Only genuinely
%%% new items — those appearing after boot — are reported. This is the same
%%% choice the warden's auth-log sensor makes by starting at end-of-file.
%%%
%%% A source being down never stops the others: each fetch is isolated, and a
%%% failure is logged and skipped.
-module(sense_news_feeds).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_POLL_MS, 300000).   %% 5 minutes
-define(DEFAULT_SEED, 1).           %% newest-N per source published on first poll
-define(DEFAULT_MAX_SEEN, 4000).    %% bounded dedupe window
-define(FETCH_TIMEOUT, 15000).
-define(CONNECT_TIMEOUT, 10000).
-define(READY_RETRY_MS, 5000).   %% re-check mesh readiness before the first poll
-define(UA, "mcl-news/0.1 (+https://github.com/macula-services/mcl-news)").

-record(st, {sources  = []      :: [map()],
             poll_ms            :: pos_integer(),
             max_seen           :: pos_integer(),
             seen     = #{}      :: #{binary() => true},
             order    = []       :: [binary()],   %% newest-first, for eviction
             first    = true     :: boolean()}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Sources = [S || S <- sources(), maps:get(url, S, <<>>) =/= <<>>],
    logger:info("[news] sensor up: ~b source(s), poll ~bs",
                [length(Sources), poll_ms() div 1000]),
    self() ! poll,
    {ok, #st{sources = Sources, poll_ms = poll_ms(), max_seen = max_seen()}}.

handle_call(_Req, _From, St) -> {reply, {error, unknown_call}, St}.
handle_cast(_Msg, St)        -> {noreply, St}.

%% The FIRST poll waits for the mesh to be ready. mcl_om connects the macula
%% client asynchronously, so a poll fired at boot would publish into a dark mesh
%% (a no-op) AND mark those items seen — losing the whole seed until the next
%% cycle. Retry every few seconds until the client + realm are up, THEN seed.
handle_info(poll, #st{first = true} = St) ->
    first_poll(mesh_ready(), St);
handle_info(poll, St) ->
    St2 = poll_sources(St),
    erlang:send_after(St#st.poll_ms, self(), poll),
    {noreply, St2#st{first = false}};
handle_info(_Info, St) ->
    {noreply, St}.

first_poll(false, St) ->
    erlang:send_after(?READY_RETRY_MS, self(), poll),
    {noreply, St};
first_poll(true, St) ->
    St2 = poll_sources(St),
    erlang:send_after(St#st.poll_ms, self(), poll),
    {noreply, St2#st{first = false}}.

%% The mesh is ready to carry a publish once the macula client pool and the realm
%% are both up.
mesh_ready() ->
    ready(mcl_om:mesh_handles()).

ready({ok, _Pool, _Realm}) -> true;
ready({error, _NotYet}) -> false.

terminate(_Reason, _St) -> ok.

%% --- polling ---

poll_sources(St) ->
    lists:foldl(fun poll_source/2, St, St#st.sources).

poll_source(Source, St) ->
    handle_body(catch fetch(maps:get(url, Source)), Source, St).

handle_body({ok, Body}, Source, St) ->
    ingest(parse_feed:parse(Body), Source, St);
handle_body(_Err, Source, St) ->
    logger:notice("[news] source ~ts unreachable", [maps:get(name, Source, <<"?">>)]),
    St.

%% First pass primes the dedupe window (mark everything seen) and publishes only
%% the newest seed-count per source, so a fresh boot does not flood consumers.
ingest(Items, Source, #st{first = true} = St) ->
    {Seed, _Rest} = take(seed_count(), Items),
    St2 = lists:foldl(fun(I, A) -> publish_if_new(I, Source, A) end, St, Seed),
    lists:foldl(fun(I, A) -> mark_seen(id(I), A) end, St2, Items);
ingest(Items, Source, St) ->
    lists:foldl(fun(I, A) -> publish_if_new(I, Source, A) end, St, Items).

publish_if_new(Item, Source, St) ->
    Id = id(Item),
    do_publish(Id, seen(Id, St), Item, Source, St).

%% No stable id -> we cannot dedupe it, so we drop it rather than risk repeating.
do_publish(<<>>, _Seen, _Item, _Source, St) ->
    St;
do_publish(_Id, true, _Item, _Source, St) ->
    St;
do_publish(Id, false, Item, Source, St) ->
    %% og_image:fill/1 goes here and not in `enrich_item', which is documented
    %% pure and total and must stay that way: this is the one step that talks
    %% to the network. It runs only for an item the feed gave no picture for,
    %% only once per item (we are past the dedupe), and returns the item
    %% unchanged on any failure at all.
    ok = mcl_news_facts:report(enrich_item:enrich(og_image:fill(Item), Source)),
    logger:info("[news] ~ts: ~ts",
                [maps:get(name, Source, <<"?">>), maps:get(title, Item, <<>>)]),
    mark_seen(Id, St).

id(Item) -> maps:get(item_id, Item, <<>>).

%% --- bounded dedupe window ---

seen(Id, #st{seen = Seen}) -> maps:is_key(Id, Seen).

mark_seen(<<>>, St) ->
    St;
mark_seen(Id, #st{seen = Seen, order = Order} = St) ->
    evict(St#st{seen = Seen#{Id => true}, order = [Id | Order]}).

evict(#st{order = Order, max_seen = Max} = St) when length(Order) =< Max ->
    St;
evict(#st{seen = Seen, order = Order, max_seen = Max} = St) ->
    {Keep, Drop} = lists:split(Max, Order),
    St#st{seen = lists:foldl(fun maps:remove/2, Seen, Drop), order = Keep}.

take(N, List) when N =< 0 -> {[], List};
take(N, List) when length(List) =< N -> {List, []};
take(N, List) -> lists:split(N, List).

%% --- HTTP ---

fetch(Url) ->
    Request = {binary_to_list(Url), [{"User-Agent", ?UA}]},
    HTTPOpts = [{timeout, ?FETCH_TIMEOUT},
                {connect_timeout, ?CONNECT_TIMEOUT},
                {ssl, ssl_opts()}],
    reply(httpc:request(get, Request, HTTPOpts, [{body_format, binary}])).

reply({ok, {{_V, 200, _R}, _H, Body}}) -> {ok, Body};
reply({ok, {{_V, Code, _R}, _H, _B}})  -> {error, {http, Code}};
reply({error, Reason})                 -> {error, Reason}.

%% Verify the source's TLS cert against the system trust store — pure OTP, no
%% Big-Tech SDK. The runtime image ships ca-certificates; on a dev box this reads
%% the host CA bundle. httpc sets SNI from the URL; the hostname match_fun
%% handles wildcard certs. A source with a bad chain simply fails its fetch (and
%% the poll skips it), which is the correct outcome for a compromised feed.
ssl_opts() ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {depth, 5},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

%% --- config ---

sources() ->
    from_env(os:getenv("MCL_NEWS_FEEDS")).

from_env(S) when is_list(S), S =/= "" ->
    [to_source(string:split(Spec, "|", all))
     || Spec <- string:split(S, ",", all), Spec =/= ""];
from_env(_Unset) ->
    application:get_env(mcl_news, sources, []).

%% Spec: "name|url|lang|country|type" — country (ISO-2) and type (broadcaster /
%% wire / private) are optional; lang defaults en, and the derived enrichment
%% fills the rest. Fewer fields degrade gracefully.
to_source([Name, Url]) ->
    #{name => bin(Name), url => bin(Url), lang => <<"en">>};
to_source([Name, Url, Lang]) ->
    #{name => bin(Name), url => bin(Url), lang => bin(Lang)};
to_source([Name, Url, Lang, Cc]) ->
    #{name => bin(Name), url => bin(Url), lang => bin(Lang), country => bin(Cc)};
to_source([Name, Url, Lang, Cc, Type | _]) ->
    #{name => bin(Name), url => bin(Url), lang => bin(Lang),
      country => bin(Cc), type => bin(Type)};
to_source(_Bad) ->
    #{name => <<"?">>, url => <<>>, lang => <<"en">>}.

bin(S) -> unicode:characters_to_binary(string:trim(S)).

poll_ms()    -> env_int("MCL_NEWS_POLL_MS", mcl_news, poll_ms, ?DEFAULT_POLL_MS).
seed_count() -> env_int("MCL_NEWS_SEED_COUNT", mcl_news, seed_count, ?DEFAULT_SEED).
max_seen()   -> env_int("MCL_NEWS_MAX_SEEN", mcl_news, max_seen, ?DEFAULT_MAX_SEEN).

env_int(EnvVar, App, Key, Default) ->
    parse_int(os:getenv(EnvVar), application:get_env(App, Key, Default)).

parse_int(false, Fallback) ->
    Fallback;
parse_int("", Fallback) ->
    Fallback;
parse_int(S, Fallback) ->
    to_int(string:to_integer(S), Fallback).

to_int({I, _Rest}, _Fallback) when is_integer(I), I >= 0 -> I;
to_int(_NotInt, Fallback)                                -> Fallback.
