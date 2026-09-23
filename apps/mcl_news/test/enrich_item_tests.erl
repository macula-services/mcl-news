%%% @doc Tests for deterministic item enrichment: topic classification, subject
%%% country, reporting metadata, and safe defaults. Pure — no network, no mesh.
-module(enrich_item_tests).

-include_lib("eunit/include/eunit.hrl").

src() ->
    #{name => <<"france24">>, lang => <<"en">>, country => <<"fr">>,
      type => <<"broadcaster">>}.

item(Title, Summary) ->
    #{item_id => <<"x">>, title => Title, summary => Summary, url => <<"http://x">>,
      topics => [], published_at => 0}.

reporting_metadata_from_source_test() ->
    E = enrich_item:enrich(item(<<"Hello">>, <<"world">>), src()),
    ?assertEqual(<<"france24">>, maps:get(source, E)),
    ?assertEqual(<<"fr">>, maps:get(reporting_country, E)),
    ?assertEqual(<<"France">>, maps:get(reporting_country_name, E)),
    ?assertEqual(<<"broadcaster">>, maps:get(source_type, E)),
    ?assertEqual(<<"en">>, maps:get(lang, E)).

classifies_conflict_test() ->
    E = enrich_item:enrich(item(<<"Missile strike hits city">>, <<"military offensive">>), src()),
    ?assertEqual(<<"conflict">>, maps:get(topic_class, E)),
    ?assert(maps:get(emoji, E) =/= <<"📰"/utf8>>).

classifies_economy_test() ->
    E = enrich_item:enrich(item(<<"Inflation rises">>, <<"the central bank responds">>), src()),
    ?assertEqual(<<"economy">>, maps:get(topic_class, E)).

conflict_beats_politics_test() ->
    %% Priority order: a war story mentioning a minister is conflict, not politics.
    E = enrich_item:enrich(item(<<"Minister announces new offensive in the war">>, <<>>), src()),
    ?assertEqual(<<"conflict">>, maps:get(topic_class, E)).

unclassified_is_general_test() ->
    E = enrich_item:enrich(item(<<"A quiet afternoon">>, <<"nothing happened">>), src()),
    ?assertEqual(<<"general">>, maps:get(topic_class, E)),
    ?assertEqual(<<"📰"/utf8>>, maps:get(emoji, E)).

subject_country_from_text_test() ->
    E = enrich_item:enrich(item(<<"Kyiv under pressure">>, <<"forces near the capital">>), src()),
    ?assertEqual(<<"ua">>, maps:get(subject_country, E)),
    ?assertEqual(<<"Ukraine">>, maps:get(subject_country_name, E)).

subject_country_absent_is_blank_test() ->
    E = enrich_item:enrich(item(<<"Local market reopens">>, <<"shoppers return">>), src()),
    ?assertEqual(<<>>, maps:get(subject_country, E)),
    ?assertEqual(<<>>, maps:get(subject_country_name, E)).

missing_source_config_defaults_test() ->
    E = enrich_item:enrich(item(<<"Hi">>, <<"there">>), #{name => <<"x">>}),
    ?assertEqual(<<"en">>, maps:get(lang, E)),
    ?assertEqual(<<>>, maps:get(reporting_country, E)),
    ?assertEqual(<<"broadcaster">>, maps:get(source_type, E)).

reporting_name_unknown_is_blank_test() ->
    ?assertEqual(<<>>, enrich_item:reporting_name(<<"zz">>)),
    ?assertEqual(<<"Germany">>, enrich_item:reporting_name(<<"de">>)).
