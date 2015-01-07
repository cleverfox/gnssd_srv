%%%-------------------------------------------------------------------
%%% @author Vladimir Goncharov <devel@viruzzz.org>
%%% @copyright (C) 2015, Vladimir Goncharov
%%% @doc
%%%
%%% @end
%%% Created :  7 Jan 2015 by Vladimir Goncharov
%%%-------------------------------------------------------------------
-module(gnss_srv).
-author("Vladimir Goncharov").
-behaviour(application).

%% Application callbacks

-export([start/0, start/2, stop/1, init/1]).

-define(MAX_RESTART,    10).
-define(MAX_TIME,      60).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

start() ->
	application:ensure_all_started(gnss_srv).

start(_StartType, _StartArgs) ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

stop(_State) ->
	ok.

init([]) ->
	{RedisHost,RedisPort} = case application:get_env(gnss_srv,redis) of 
					{ok, {RHost, RPort} } ->
						{RHost,RPort};
					_ ->
						{"127.0.0.1",6379}
				end,
	{ok,
	 {_SupFlags = {one_for_one, ?MAX_RESTART, ?MAX_TIME},
	  [
	   {   pool_redis,
		   {poolboy,start_link,[
								[{name,{local,redis}},
								 {worker_module,eredis},
								 {size,3},
								 {max_overflow,20}
								],
								[ {host, RedisHost}, 
								  {port, RedisPort}
								] 
							   ]},            % StartFun = {M, F, A}
		   permanent,                         % Restart  = permanent | transient | temporary
		   5000,                              % Shutdown = brutal_kill | int() >= 0 | infinity
		   worker,                            % Type     = worker | supervisor
		   [poolboy,eredis]                % Modules  = [Module] | dynamic
	   },
	   { client_sup,
		 { supervisor,
		   start_link,
		   [ {local, client_sup},
			 ?MODULE,
			 [server_tcp_tk103]
		   ]
		 },
		 permanent, infinity, supervisor, []
	   },
	   {   server_tcp_listener,
		   {server_tcp,start_link, [ 5002, server_tcp_tk103 ] },
		   permanent, 2000, worker, []
	   }
	  ]
	 }
	};

init([Module]) ->
    {ok,
        {_SupFlags = {one_for_one, ?MAX_RESTART, ?MAX_TIME},
		 [
            %  % TCP Client
            %  {   undefined,                               % Id       = internal id
            %      {Module,start_link,[]},                  % StartFun = {M, F, A}
            %      temporary,                               % Restart  = permanent | transient | temporary
            %      2000,                                    % Shutdown = brutal_kill | int() >= 0 | infinity
            %      worker,                                  % Type     = worker | supervisor
            %      []                                       % Modules  = [Module] | dynamic
            %  }
            ]
        }
    }.


