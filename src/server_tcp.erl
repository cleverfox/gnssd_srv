%%%-------------------------------------------------------------------
%%% @author Vladimir Goncharov <devel@viruzzz.org>
%%% @copyright (C) 2015, Vladimir Goncharov
%%% @doc
%%%
%%% @end
%%% Created :  7 Jan 2015 by Vladimir Goncharov
%%% Parts of code in this file by saleyn@gmail.com
%%%-------------------------------------------------------------------
-module(server_tcp).
-author("Vladimir Goncharov").
-behaviour(gen_server).

%% API functions
-export([start_link/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
		  listener,       % Listening socket
		  acceptor,       % Asynchronous acceptor's internal reference
		  module          % FSM handling module
		 }).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(P, M) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [P, M], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Port, Mod]) ->
	process_flag(trap_exit, true),
	Opts = [binary, {packet, 2}, {reuseaddr, true},
			{keepalive, true}, {backlog, 30}, {active, false}],
	case gen_tcp:listen(Port, Opts) of
		{ok, Listen_socket} ->
			{ok, Ref} = prim_inet:async_accept(Listen_socket, -1),
			{ok, #state{listener = Listen_socket,
						acceptor = Ref,
						module   = Mod}};
		{error, Reason} ->
			{stop, Reason}
	end.
%{ok, LSock} = gen_tcp:listen(5002, [binary, {packet, 0}, {active, false}]),
%	{ok, #state{ lsock = LSock }}.

handle_call(_Request, _From, State) ->
	lager:info("Call ~p",[_Request]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
	lager:info("Cast ~p",[_Msg]),
    {noreply, State}.

handle_info({inet_async, ListSock, Ref, {ok, CliSocket}},
			#state{listener=ListSock, acceptor=Ref, module=Module} = State) ->
	try
		case set_sockopt(ListSock, CliSocket) of
			ok              -> ok;
			{error, Reason} -> exit({set_sockopt, Reason})
		end,

		{ok, Pid} = start_client(Module,CliSocket),
		gen_tcp:controlling_process(CliSocket, Pid),
		%% Instruct the new FSM that it owns the socket.
		Module:assign_socket(Pid, CliSocket),

		%% Signal the network driver that we are ready to accept another connection
		NewRef = case prim_inet:async_accept(ListSock, -1) of
			{ok,    M} -> M;
			{error, ErrorRef} -> exit({async_accept, inet:format_error(ErrorRef)})
		end,

		{noreply, State#state{acceptor=NewRef}}
	catch exit:Why ->
			  error_logger:error_msg("Error in async accept: ~p.\n", [Why]),
			  {stop, Why, State}
	end;

handle_info({inet_async, ListSock, Ref, Error}, #state{listener=ListSock, acceptor=Ref} = State) ->
	error_logger:error_msg("Error in socket acceptor: ~p.\n", [Error]),
	{stop, Error, State};

handle_info(_Info, State) ->
	lager:info("INFO ~p",[_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

set_sockopt(ListSock, CliSocket) ->
	true = inet_db:register_socket(CliSocket, inet_tcp),
	case prim_inet:getopts(ListSock, [active, nodelay, keepalive, delay_send, priority, tos]) of
		{ok, Opts} ->
			case prim_inet:setopts(CliSocket, Opts) of
				ok    -> ok;
				Error -> gen_tcp:close(CliSocket), Error
			end;
		Error ->
			gen_tcp:close(CliSocket), Error
	end.

start_client(Module,P) ->
	    supervisor:start_child(client_sup, {{Module,P}, 
											{Module, start_link, []},
											 temporary, brutal_kill, worker, [Module]}
							  ).

