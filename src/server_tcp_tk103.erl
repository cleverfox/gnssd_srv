-module(server_tcp_tk103).

-behaviour(gen_fsm).

%% API functions
-export([start_link/0, assign_socket/2]).

%% gen_fsm callbacks
-export([init/1,
         'WFSOCKET'/2,
         'WFDATA'/2,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-record(state, {
		  socket,
		  recvbuf,
		  re,
		  ip,
		  port
		 }).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_fsm:start_link(?MODULE, [], []).

assign_socket(Pid, Socket) when is_pid(Pid), is_port(Socket) ->
	%lager:info("Assign socket ~p",[Socket]),
	gen_fsm:send_event(Pid, {assign_socket, Socket}).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
	%lager:info("Spawn ~p",[?MODULE]),
	{ok,MP} = re:compile("\\((?<A>[01-9]{12})(BR00)(?<C1>[01-9]{2})(?<C2>[01-9]{2})(?<C3>[01-9]{2})(?<D>[AV])(?<E1>[01-9]{2})(?<E2>[01-9]{2}\.[01-9]{4})(?<E3>[NS])(?<F1>[01-9]{3})(?<F2>[01-9]{2}\.[01-9]{4})(?<F3>[EW])(?<G>...\..)(?<H1>[01-9]{2})(?<H2>[01-9]{2})(?<H3>[01-9]{2})(.+)"),
    {ok, 'WFSOCKET', #state{recvbuf=[], re=MP}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same
%% name as the current state name StateName is called to handle
%% the event. It is also called if a timeout occurs.
%%
%% @spec state_name(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
'WFSOCKET'({assign_socket, Socket}, State) when is_port(Socket) ->
     {ok, {IP, Port}} = inet:peername(Socket),
	 lager:info("Accepted client ~p:~p",[IP, Port]),
	 inet:setopts(Socket, [{active, once}, {packet, 0}, binary]),
%	 {ok, {IP, _Port}} = inet:peername(Socket),
	 {next_state, 'WFDATA', State#state{socket=Socket,ip=IP,port=Port}};

'WFSOCKET'(_Event, State) ->
 	lager:info("Ev ~p",[_Event]),
    {next_state, 'WFDATA', State}.

'WFDATA'({data, Bin}, State) ->
 	BData=State#state.recvbuf++binary_to_list(Bin),
 	lager:info("Data ~p",[BData]),
	{BD2, Arr} = parse_data(BData),
	Fun=fun(X) -> 
				case re:run(X,State#state.re,[{capture,all_names,binary}]) of 
					{match, [IMEI, Y, M, D, Valid, La1, La2, LaS, Lo1, Lo2, LoS, Spd, Hr, Min, Sec]} ->
						DT={{2000+binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)}, 
							{binary_to_integer(Hr), binary_to_integer(Min), binary_to_integer(Sec)}},
						Lat=case LaS of 
								<<"S">> -> -(binary_to_integer(La1)+binary_to_float(La2)/60);
								_ -> (binary_to_integer(La1)+binary_to_float(La2)/60)
							end,
						Lon=case LoS of 
								<<"W">> -> -(binary_to_integer(Lo1)+binary_to_float(Lo2)/60);
								_ -> (binary_to_integer(Lo1)+binary_to_float(Lo2)/60)
							end,
						Speed=binary_to_float(Spd),
						UT=case catch calendar:datetime_to_gregorian_seconds(DT) - 62167219200 of
							   Time when is_integer(Time) -> Time;
							   _ -> 0 
						   end,
						{MSec,SSec,_}=now(),		
						lager:info("Dev ~p @ ~p,~p ~p",[binary_to_list(IMEI), Lon, Lat, binary_to_list(Valid)]),
						Data={struct,[
									  {imei,IMEI},
									  {dir,0},
									  {sp,Speed},
									  {valid,case Valid of <<"A">> -> true; _ -> false end},
									  {dt,UT},
									  {st,MSec*1000000+SSec},
									  {ip_addr,list_to_binary(inet:ntoa(State#state.ip))},
									  {ip_port,State#state.port},
									  {position,{array,[Lon, Lat]}}
									 ]},
						Document=iolist_to_binary(mochijson2:encode(Data)),
						lager:debug("Send ~p",[Document]),
						Redis=fun(W) -> 
									  eredis:q(W, [ "publish", "source", Document])
							  end,
						poolboy:transaction(gs_redis,Redis),
						ok;
					_ -> ok
				end 
		end,
	lists:foreach(Fun,Arr),
	{next_state, 'WFDATA', State#state{recvbuf=BD2}};

'WFDATA'(_Event, State) ->
 	lager:info("Ev ~p",[_Event]),
    {next_state, 'WFDATA', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
 	lager:info("Ev ~p st ~p",[_Event,StateName]),
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
 	lager:info("Ev ~p fr ~p st ~p",[_Event,_From,StateName]),
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info({tcp, Socket, Bin}, StateName, #state{socket=_Socket} = StateData) ->
	lager:debug("Socket ~p data ~p, st ~p",[Socket,Bin, StateName]),
	% Flow control: enable forwarding of next TCP message
	inet:setopts(Socket, [{active, once}]),
	?MODULE:StateName({data, Bin}, StateData);

handle_info({tcp_closed, Socket}, _StateName, #state{socket=Socket} = StateData) ->
	lager:info("Client disconnected.\n", []),
	{stop, normal, StateData};
		
handle_info(_Info, StateName, State) ->
 	lager:info("Info ~p St ~p",[_Info,StateName]),
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

parse_data(Data) ->
	parse_data(Data,[]).

parse_data(BData, Lst) ->
	case string:chr(BData,$)) of
		0 -> {BData, Lst};
		N when is_integer(N) -> 
			parse_data(string:sub_string(BData,N+1), Lst ++ [string:sub_string(BData,1,N)])
	end.

