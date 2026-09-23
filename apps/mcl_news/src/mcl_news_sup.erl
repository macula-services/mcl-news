%% @doc Supervises the feed sensor, which owns its poll loop, its dedupe window
%% and its publishing. One child.
-module(mcl_news_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => sense_news_feeds,
             start => {sense_news_feeds, start_link, []}}]}}.
