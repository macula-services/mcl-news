%%% @doc The public contract: the one fact topic, and the fact itself. Pure:
%%% no network, no mesh (the publish is integration).
-module(mcl_news_facts_tests).

-include_lib("eunit/include/eunit.hrl").

%% ONE canonical app fact owned by org mcl-news. The category, country and
%% source type are payload fields a consumer filters on, never topic segments.
the_topic_is_one_app_fact_of_this_org_test() ->
    ?assertEqual(macula_topic:app_fact(<<"io.macula">>, <<"mcl-news">>, <<"news">>, <<"wire">>,
                                       <<"news_item_reported">>, 1),
                 mcl_news_facts:topic(<<"io.macula">>)).

item() ->
    #{item_id => <<"https://example.org/a">>, source => <<"vrtnws">>,
      title => <<"Title">>, summary => <<"Summary">>, url => <<"https://example.org/a">>,
      image_url => <<"https://example.org/a.jpg">>, lang => <<"nl">>,
      topics => [<<"Politiek">>], topic_class => <<"politics">>, emoji => <<"🏛"/utf8>>,
      reporting_country => <<"be">>, reporting_country_name => <<"Belgium">>,
      subject_country => <<"ua">>, subject_country_name => <<"Ukraine">>,
      source_type => <<"broadcaster">>, published_at => 1788000000000}.

%% A bare binary goes out as a CBOR byte string, which every consumer outside
%% the BEAM renders as 0x-hex.
every_string_is_tagged_text_test() ->
    ?assertEqual([], bare_binaries(mcl_news_facts:fact(item(), 1788000001000))).

carries_the_item_and_its_enrichment_test() ->
    F = mcl_news_facts:fact(item(), 1788000001000),
    ?assertEqual({text, <<"vrtnws">>}, maps:get(source, F)),
    ?assertEqual({text, <<"politics">>}, maps:get(topic_class, F)),
    ?assertEqual({text, <<"be">>}, maps:get(reporting_country, F)),
    ?assertEqual({text, <<"broadcaster">>}, maps:get(source_type, F)),
    ?assertEqual([{text, <<"Politiek">>}], maps:get(topics, F)),
    ?assertEqual(1788000000000, maps:get(published_at, F)),
    ?assertEqual(1788000001000, maps:get(fetched_at, F)).

%% Who reported it is the publisher macula verified, not a label in the payload.
%% The fact's kind is its topic.
carries_no_self_asserted_sender_or_kind_test() ->
    F = mcl_news_facts:fact(item(), 0),
    ?assertNot(maps:is_key(from, F)),
    ?assertNot(maps:is_key(type, F)).

the_body_is_the_readable_headline_line_test() ->
    #{body := {text, Body}} = mcl_news_facts:fact(item(), 0),
    ?assertEqual(<<"[NEWS] 🏛 [politics] Title — Summary (vrtnws, about Ukraine)"/utf8>>, Body).

%% Bounded so a consumer's context is not bloated, by graphemes so multibyte
%% text is never cut mid-character.
clips_title_and_summary_test() ->
    Long = binary:copy(<<"é"/utf8>>, 1000),
    #{title := {text, T}, summary := {text, S}} =
        mcl_news_facts:fact((item())#{title => Long, summary => Long}, 0),
    ?assertEqual(301, string:length(T)),
    ?assertEqual(601, string:length(S)).

missing_fields_take_their_defaults_test() ->
    F = mcl_news_facts:fact(#{item_id => <<"x">>}, 0),
    ?assertEqual({text, <<"unknown">>}, maps:get(source, F)),
    ?assertEqual({text, <<"general">>}, maps:get(topic_class, F)),
    ?assertEqual({text, <<>>}, maps:get(image_url, F)),
    ?assertEqual(0, maps:get(published_at, F)),
    ?assertEqual([], bare_binaries(F)).

%% The topic carries the realm NAME and the pool publishes in the realm TAG.
realm_name_must_hash_to_the_realm_tag_test() ->
    Tag = crypto:hash(sha256, <<"io.macula">>),
    ?assertEqual(ok, mcl_news_facts:check_realm_name(<<"io.macula">>, Tag)),
    ?assertError({mcl_news_realm_name_mismatch, <<"x">>, Tag},
                 mcl_news_facts:check_realm_name(<<"x">>, Tag)).

%% A name that hashes right but is not a valid topic segment would pass the
%% check and then fail every report while /health stays green.
a_realm_name_that_cannot_build_the_topic_is_refused_test() ->
    Name = <<"IO Macula">>,
    ?assertError(_, mcl_news_facts:check_realm_name(Name, crypto:hash(sha256, Name))).

realm_name_is_required_test() ->
    _ = application:load(mcl_news),
    ok = application:set_env(mcl_news, realm_name, ""),
    try ?assertError({mcl_news_realm_name_unset, realm_name}, mcl_news_facts:realm_name())
    after application:unset_env(mcl_news, realm_name)
    end.

bare_binaries(Map) when is_map(Map) -> lists:append([bare_binaries(V) || V <- maps:values(Map)]);
bare_binaries(List) when is_list(List) -> lists:append([bare_binaries(V) || V <- List]);
bare_binaries({text, Bin}) when is_binary(Bin) -> [];
bare_binaries(Bin) when is_binary(Bin) -> [Bin];
bare_binaries(_Other) -> [].
