%%% @doc The sensor's seeding and dedupe, without network or mesh: the report
%%% step is injected, so every test sees exactly what would have been reported.
%%%
%%% An item is marked seen only once its report succeeded, so a dark mesh or a
%%% refused publish loses nothing: the item is reported on a later poll. Each
%%% source is primed on its OWN first successful fetch, so a source that was
%%% down at boot seeds when it comes back instead of flooding its backlog.
-module(sense_news_feeds_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, #{name => <<"a">>}).
-define(B, #{name => <<"b">>}).

items(Prefix, N) ->
    [#{item_id => <<Prefix/binary, (integer_to_binary(I))/binary>>} || I <- lists:seq(1, N)].

state() -> sense_news_feeds:new(#{seed => 1, max_seen => 100}).

ok_report(Log) -> fun(Item, Source) -> Log ! {reported, Source, Item}, ok end.

reported() -> reported([]).
reported(Acc) ->
    receive {reported, #{name := N}, #{item_id := Id}} -> reported([{N, Id} | Acc])
    after 0 -> lists:reverse(Acc)
    end.

%% The first fetch of a source reports its newest item and marks the rest seen.
the_first_fetch_of_a_source_seeds_and_does_not_flood_test() ->
    St = sense_news_feeds:ingest(items(<<"a">>, 5), ?A, state(), ok_report(self())),
    ?assertEqual([{<<"a">>, <<"a1">>}], reported()),
    ?assert(lists:all(fun(#{item_id := Id}) -> sense_news_feeds:seen(Id, St) end, items(<<"a">>, 5))).

%% After priming, only items not seen before are reported.
a_later_fetch_reports_only_new_items_test() ->
    St = sense_news_feeds:ingest(items(<<"a">>, 3), ?A, state(), ok_report(self())),
    _ = reported(),
    _ = sense_news_feeds:ingest(items(<<"a">>, 5), ?A, St, ok_report(self())),
    ?assertEqual([{<<"a">>, <<"a4">>}, {<<"a">>, <<"a5">>}], reported()).

%% A source down at boot is primed on its own first fetch, not flooded because
%% another source primed the sensor earlier.
a_source_down_at_boot_seeds_when_it_returns_test() ->
    St = sense_news_feeds:ingest(items(<<"a">>, 3), ?A, state(), ok_report(self())),
    _ = reported(),
    _ = sense_news_feeds:ingest(items(<<"b">>, 40), ?B, St, ok_report(self())),
    ?assertEqual([{<<"b">>, <<"b1">>}], reported()).

%% A report that fails (dark mesh, refused publish) marks nothing seen, so the
%% item is reported by a later poll, the seed included.
a_failed_report_is_retried_on_the_next_poll_test() ->
    Failing = fun(_Item, _Source) -> {error, mesh_unavailable} end,
    St = sense_news_feeds:ingest(items(<<"a">>, 3), ?A, state(), Failing),
    ?assertNot(sense_news_feeds:seen(<<"a1">>, St)),
    ?assert(sense_news_feeds:seen(<<"a2">>, St)),
    _ = sense_news_feeds:ingest(items(<<"a">>, 3), ?A, St, ok_report(self())),
    ?assertEqual([{<<"a">>, <<"a1">>}], reported()).

%% An item with no stable id cannot be deduplicated, so it is dropped rather
%% than risk reporting it on every poll.
an_item_without_an_id_is_dropped_test() ->
    St = sense_news_feeds:ingest(items(<<"a">>, 1), ?A, state(), ok_report(self())),
    _ = reported(),
    _ = sense_news_feeds:ingest([#{title => <<"no id">>}], ?A, St, ok_report(self())),
    ?assertEqual([], reported()).

%% The window holds at most max_seen ids, the newest, each once.
the_dedupe_window_is_bounded_and_holds_each_id_once_test() ->
    St0 = sense_news_feeds:new(#{seed => 5, max_seen => 3}),
    St = sense_news_feeds:ingest(items(<<"a">>, 5), ?A, St0, ok_report(self())),
    _ = reported(),
    Seen = [Id || #{item_id := Id} <- items(<<"a">>, 5), sense_news_feeds:seen(Id, St)],
    ?assertEqual(3, length(Seen)),
    ?assertEqual(3, sense_news_feeds:window_size(St)).

%% A zero poll interval is a hot loop and a zero window reports everything on
%% every poll: both fall back to the default rather than being taken.
a_zero_or_invalid_setting_falls_back_to_the_default_test() ->
    ?assertEqual(300000, sense_news_feeds:positive_int("0", 300000)),
    ?assertEqual(300000, sense_news_feeds:positive_int("-5", 300000)),
    ?assertEqual(300000, sense_news_feeds:positive_int("soon", 300000)),
    ?assertEqual(300000, sense_news_feeds:positive_int(false, 300000)),
    ?assertEqual(60000, sense_news_feeds:positive_int("60000", 300000)).
