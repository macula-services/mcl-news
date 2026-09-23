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
%%% A source's first fetch primes, it does not flood: its current backlog is
%%% marked seen and only its newest few items are reported as a seed, whether
%%% that fetch happens at boot or when a source that was down comes back. After
%%% that, only items not seen before are reported. An item is marked seen only
%%% once its report succeeded, so a dark mesh delays a report and loses none.
%%%
%%% A source being down never stops the others: each fetch is isolated, and a
%%% failure is logged and skipped.
-module(sense_news_feeds).
-behaviour(gen_server).

-export([start_link/0, new/1, ingest/4, seen/2, window_size/1, positive_int/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_POLL_MS, 300000).   %% 5 minutes
-define(DEFAULT_SEED, 1).           %% newest-N per source reported on its first fetch
-define(DEFAULT_MAX_SEEN, 4000).    %% bounded dedupe window
-define(FETCH_TIMEOUT, 15000).
-define(CONNECT_TIMEOUT, 10000).
-define(UA, "mcl-news/0.1 (+https://github.com/macula-services/mcl-news)").

-type state() :: #{seed := non_neg_integer(), max_seen := pos_integer(),
                   seen := #{binary() => true}, order := [binary()],
                   primed := #{binary() => true}}.
-type report() :: fun((map(), map()) -> ok | {error, term()}).

-export_type([state/0]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc An empty dedupe state: nothing seen, no source primed.
-spec new(#{seed := non_neg_integer(), max_seen := pos_integer()}) -> state().
new(#{seed := Seed, max_seen := Max}) ->
    #{seed => Seed, max_seen => Max, seen => #{}, order => [], primed => #{}}.

init([]) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Sources = [S || S <- sources(), maps:get(url, S, <<>>) =/= <<>>],
    PollMs = poll_ms(),
    logger:info("[news] sensor up: ~b source(s), poll ~bs", [length(Sources), PollMs div 1000]),
    self() ! poll,
    {ok, #{sources => Sources, poll_ms => PollMs,
           dedupe => new(#{seed => seed_count(), max_seen => max_seen()})}}.

handle_call(_Req, _From, St) -> {reply, {error, unknown_call}, St}.
handle_cast(_Msg, St)        -> {noreply, St}.

%% No wait for the mesh before the first poll: an item is marked seen only
%% once its report succeeded, so a poll into a dark mesh loses nothing and the
%% next poll reports it.
handle_info(poll, #{sources := Sources, poll_ms := PollMs, dedupe := D} = St) ->
    D2 = lists:foldl(fun poll_source/2, D, Sources),
    erlang:send_after(PollMs, self(), poll),
    {noreply, St#{dedupe := D2}};
handle_info(_Info, St) ->
    {noreply, St}.

terminate(_Reason, _St) -> ok.

%% --- polling ---

poll_source(Source, D) ->
    handle_body(catch fetch(maps:get(url, Source)), Source, D).

handle_body({ok, Body}, Source, D) ->
    parsed(parse_feed:parse(Body), Source, D);
handle_body(_Err, Source, D) ->
    logger:notice("[news] source ~ts unreachable", [name(Source)]),
    D.

%% A feed that answered but parsed to nothing (an unknown encoding, a broken
%% document) is said, not silently skipped.
parsed([], Source, D) ->
    logger:notice("[news] source ~ts answered but yielded no items", [name(Source)]),
    D;
parsed(Items, Source, D) ->
    ingest(Items, Source, D, fun report/2).

%% og_image:fill/1 runs here and not in `enrich_item', which is pure and total
%% and must stay that way: this is the one step that talks to the network. It
%% runs only for an item not yet reported, and returns the item unchanged on
%% any failure.
report(Item, Source) ->
    logged(mcl_news_facts:report(enrich_item:enrich(og_image:fill(Item), Source)), Item, Source).

logged(ok, Item, Source) ->
    logger:info("[news] ~ts: ~ts", [name(Source), maps:get(title, Item, <<>>)]),
    ok;
logged({error, _} = Error, _Item, _Source) ->
    Error.

%% @doc Report the items of one fetch of `Source' through `Report'.
%%
%% A source's FIRST successful fetch primes it: only its newest `seed' items
%% are reported and the rest of its backlog is marked seen, so neither a boot
%% nor a source that was down at boot floods consumers with old news. After
%% that, every item not seen before is reported. An item is marked seen only
%% when its report succeeded; one that failed is tried again next poll.
-spec ingest([map()], map(), state(), report()) -> state().
ingest(Items, Source, #{primed := Primed} = D, Report) ->
    primed(maps:is_key(name(Source), Primed), Items, Source, D, Report).

primed(true, Items, Source, D, Report) ->
    lists:foldl(fun(I, A) -> report_if_new(I, Source, A, Report) end, D, Items);
primed(false, Items, Source, #{seed := Seed, primed := Primed} = D, Report) ->
    {Fresh, Backlog} = take(Seed, Items),
    D2 = lists:foldl(fun(I, A) -> report_if_new(I, Source, A, Report) end, D, Fresh),
    D3 = lists:foldl(fun(I, A) -> mark_seen(id(I), A) end, D2, Backlog),
    D3#{primed := Primed#{name(Source) => true}}.

report_if_new(Item, Source, D, Report) ->
    Id = id(Item),
    reported(Id, seen(Id, D), Item, Source, D, Report).

%% No stable id: it cannot be deduplicated, so it is dropped rather than risk
%% reporting it on every poll.
reported(<<>>, _Seen, _Item, _Source, D, _Report) ->
    D;
reported(_Id, true, _Item, _Source, D, _Report) ->
    D;
reported(Id, false, Item, Source, D, Report) ->
    marked(Report(Item, Source), Id, D).

marked(ok, Id, D) -> mark_seen(Id, D);
marked({error, _Reason}, _Id, D) -> D.

id(Item) -> maps:get(item_id, Item, <<>>).

name(Source) -> maps:get(name, Source, <<"?">>).

%% --- bounded dedupe window ---

-spec seen(binary(), state()) -> boolean().
seen(Id, #{seen := Seen}) -> maps:is_key(Id, Seen).

-spec window_size(state()) -> non_neg_integer().
window_size(#{order := Order}) -> length(Order).

%% Each id enters the window once, newest first; the oldest leave past max_seen.
mark_seen(<<>>, D) ->
    D;
mark_seen(Id, #{seen := Seen} = D) when is_map_key(Id, Seen) ->
    D;
mark_seen(Id, #{seen := Seen, order := Order} = D) ->
    evict(D#{seen := Seen#{Id => true}, order := [Id | Order]}).

evict(#{order := Order, max_seen := Max} = D) when length(Order) =< Max ->
    D;
evict(#{seen := Seen, order := Order, max_seen := Max} = D) ->
    {Keep, Drop} = lists:split(Max, Order),
    D#{seen := lists:foldl(fun maps:remove/2, Seen, Drop), order := Keep}.

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

poll_ms()    -> setting("MCL_NEWS_POLL_MS", poll_ms, ?DEFAULT_POLL_MS).
seed_count() -> setting("MCL_NEWS_SEED_COUNT", seed_count, ?DEFAULT_SEED).
max_seen()   -> setting("MCL_NEWS_MAX_SEEN", max_seen, ?DEFAULT_MAX_SEEN).

setting(EnvVar, Key, Default) ->
    positive_int(os:getenv(EnvVar), application:get_env(mcl_news, Key, Default)).

%% @doc The integer in `Value', or `Fallback' when it is unset, not an integer,
%% or not positive: a zero poll interval is a hot loop, and a zero window
%% reports everything on every poll.
-spec positive_int(string() | false, pos_integer()) -> pos_integer().
positive_int(false, Fallback) ->
    Fallback;
positive_int(Value, Fallback) ->
    positive(string:to_integer(Value), Fallback).

positive({I, _Rest}, _Fallback) when is_integer(I), I > 0 -> I;
positive(_NotPositive, Fallback) -> Fallback.
