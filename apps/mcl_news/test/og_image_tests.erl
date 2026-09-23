%%% @doc Reading the publisher's own choice of picture off their own page.
%%%
%%% All pure: every shape forty-seven newsrooms can write, without a network.
-module(og_image_tests).
-include_lib("eunit/include/eunit.hrl").

page(Meta) ->
    <<"<!doctype html><html><head><title>x</title>", Meta/binary,
      "</head><body>...</body></html>">>.

%% --- the ordinary case ---

reads_og_image_test() ->
    ?assertEqual(<<"https://img.zeit.de/x.jpg">>,
                 og_image:of_html(page(<<"<meta property=\"og:image\" content=\"https://img.zeit.de/x.jpg\">">>))).

%% Hand-written HTML from forty-seven newsrooms: attribute order and quoting
%% vary, and none of it is a reason to lose a picture.
reads_it_whichever_way_round_it_is_written_test() ->
    [?assertEqual(<<"https://e/x.jpg">>, og_image:of_html(page(M)))
     || M <- [<<"<meta property=\"og:image\" content=\"https://e/x.jpg\">">>,
              <<"<meta content=\"https://e/x.jpg\" property=\"og:image\">">>,
              <<"<meta property='og:image' content='https://e/x.jpg'>">>,
              <<"<meta  PROPERTY = \"OG:IMAGE\"  CONTENT = \"https://e/x.jpg\" />">>,
              <<"<meta name=\"og:image\" content=\"https://e/x.jpg\">">>]].

%% The same offer under other names, in the order a publisher means them.
falls_back_to_twitter_image_test() ->
    ?assertEqual(<<"https://e/t.jpg">>,
                 og_image:of_html(page(<<"<meta name=\"twitter:image\" content=\"https://e/t.jpg\">">>))).

prefers_the_secure_url_when_offered_test() ->
    Meta = <<"<meta property=\"og:image\" content=\"http://e/plain.jpg\">",
             "<meta property=\"og:image:secure_url\" content=\"https://e/secure.jpg\">">>,
    ?assertEqual(<<"https://e/secure.jpg">>, og_image:of_html(page(Meta))).

%% og:image:width sits right next to og:image and must not be mistaken for it.
does_not_confuse_a_sibling_property_test() ->
    Meta = <<"<meta property=\"og:image:width\" content=\"1200\">",
             "<meta property=\"og:image\" content=\"https://e/x.jpg\">">>,
    ?assertEqual(<<"https://e/x.jpg">>, og_image:of_html(page(Meta))).

unescapes_an_ampersand_test() ->
    ?assertEqual(<<"https://e/x.jpg?w=1&h=2">>,
                 og_image:of_html(page(<<"<meta property=\"og:image\" content=\"https://e/x.jpg?w=1&amp;h=2\">">>))).

%% --- nothing to find ---

a_page_without_one_yields_nothing_test() ->
    ?assertEqual(<<>>, og_image:of_html(page(<<"<meta name=\"description\" content=\"x\">">>))),
    ?assertEqual(<<>>, og_image:of_html(<<"not html at all">>)),
    ?assertEqual(<<>>, og_image:of_html(<<>>)).

%% A fetch that failed is not a page. This is the path every TLS error, every
%% timeout and every 404 takes, and it must be quiet.
an_unfetched_page_yields_nothing_test() ->
    ?assertEqual(<<>>, og_image:of_html({error, no_page})),
    ?assertEqual(<<>>, og_image:of_html(undefined)).

%% --- relative URLs ---

%% A relative URL in an <img src> on somebody else's site is a broken image.
resolves_a_root_relative_url_test() ->
    ?assertEqual(<<"https://www.rte.ie/img/x.jpg">>,
                 og_image:absolute(<<"/img/x.jpg">>, <<"https://www.rte.ie/news/2026/story">>)).

resolves_a_protocol_relative_url_test() ->
    ?assertEqual(<<"https://cdn.e/x.jpg">>,
                 og_image:absolute(<<"//cdn.e/x.jpg">>, <<"https://www.e/news">>)),
    ?assertEqual(<<"http://cdn.e/x.jpg">>,
                 og_image:absolute(<<"//cdn.e/x.jpg">>, <<"http://www.e/news">>)).

leaves_an_absolute_url_alone_test() ->
    ?assertEqual(<<"https://e/x.jpg">>, og_image:absolute(<<"https://e/x.jpg">>, <<"https://p/a">>)).

%% Anything it cannot resolve is dropped rather than shipped broken -- and a
%% data: or javascript: URL must never reach an <img src> on a public page.
drops_what_it_cannot_resolve_test() ->
    [?assertEqual(<<>>, og_image:absolute(U, <<"https://p/a">>))
     || U <- [<<"img/x.jpg">>, <<"data:image/png;base64,AAAA">>,
              <<"javascript:alert(1)">>, <<>>]].

%% --- fill/1 ---

%% The feed already gave us the publisher's picture. Never second-guess it,
%% and never spend a fetch on it.
an_item_that_has_a_picture_is_untouched_test() ->
    Item = #{url => <<"https://e/a">>, image_url => <<"https://e/feed.jpg">>},
    ?assertEqual(Item, og_image:fill(Item)).

an_item_with_no_url_is_untouched_test() ->
    ?assertEqual(#{title => <<"x">>}, og_image:fill(#{title => <<"x">>})),
    ?assertEqual(#{url => <<>>}, og_image:fill(#{url => <<>>})).

junk_in_is_junk_out_not_a_crash_test() ->
    ?assertEqual(not_a_map, og_image:fill(not_a_map)).

%% The page head is cut at a byte limit. Cut mid-character, the unicode regex
%% raised inside the catch and the picture was lost; the cut now lands on a
%% character boundary and the meta tag before it is still found.
a_head_cut_mid_character_still_yields_the_picture_test() ->
    Meta = <<"<meta property=\"og:image\" content=\"https://e/x.jpg\">">>,
    Pad = binary:copy(<<"a">>, 65536 - byte_size(Meta) - 1),
    Page = <<Meta/binary, Pad/binary, 16#C3, 16#A9, "tail">>,
    Head = og_image:clip(Page),
    ?assert(is_binary(unicode:characters_to_binary(Head))),
    ?assertEqual(<<"https://e/x.jpg">>, og_image:of_html(Head)).
