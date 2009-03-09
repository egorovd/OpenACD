%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc The connection handler that communicates with a client UI; in this case the desktop client.
%% @clear
-module(agent_tcp_connection).

%% depends on util, agent

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

-export([start/1, start_link/1, negotiate/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
		code_change/3]).

-define(Major, 2).
-define(Minor, 0).

-include("call.hrl").
-include("agent.hrl").

% {Counter, Event, Data, now()}
-type(unacked_event() :: {pos_integer(), string(), string(), {pos_integer(), pos_integer(), pos_integer()}}).

-record(state, {
		salt :: pos_integer(),
		socket :: port(),
		agent_fsm :: pid(),
		send_queue = [] :: [string()],
		counter = 1 :: pos_integer(),
		unacked = [] :: [unacked_event()],
		resent = [] :: [unacked_event()],
		resend_counter = 0 :: non_neg_integer()
	}).

%% @doc start the conection unlinked on the given Socket.  This is usually done by agent_tcp_listener
start(Socket) ->
	gen_server:start(?MODULE, [Socket], []).

%% @doc start the conection linked on the given Socket.  This is usually done by agent_tcp_listener
start_link(Socket) ->
	gen_server:start_link(?MODULE, [Socket], []).

%% @doc negotiate the client's protocol, and version before login.
negotiate(Pid) ->
	gen_server:cast(Pid, negotiate).

init([Socket]) ->
	timer:send_interval(10000, do_tick),
	{ok, #state{socket=Socket}}.

handle_call(Request, _From, State) ->
	{reply, {unknown_call, Request}, State}.

% negotiate the client's protocol version and such
handle_cast(negotiate, State) ->
	inet:setopts(State#state.socket, [{active, false}, {packet, line}, list]),
	gen_tcp:send(State#state.socket, "Agent Server: -1\r\n"),
	{ok, Packet} = gen_tcp:recv(State#state.socket, 0), % TODO timeout
	?CONSOLE("packet: ~p.~n", [Packet]),
	case Packet of
		"Protocol: " ++ Args ->
			?CONSOLE("Got protcol version ~p.~n", [Args]),
			try lists:map(fun(X) -> list_to_integer(X) end, util:string_split(util:string_chomp(Args), ".", 2)) of
				[?Major, ?Minor] ->
					gen_tcp:send(State#state.socket, "0 OK\r\n"),
					inet:setopts(State#state.socket, [{active, once}]),
					{noreply, State};
				[?Major, _Minor] ->
					gen_tcp:send(State#state.socket, "1 Protocol version mismatch. Please consider upgrading your client\r\n"),
					inet:setopts(State#state.socket, [{active, once}]),
					{noreply, State};
				[_Major, _Minor] ->
					gen_tcp:send(State#state.socket, "2 Protocol major version mismatch. Login denied\r\n"),
					{stop, normal}
			catch
				_:_ ->
					gen_tcp:send(State#state.socket, "2 Invalid Response. Login denied\r\n"),
					{stop, normal}
			end;
		_Else ->
			gen_tcp:send(State#state.socket, "2 Invalid Response. Login denied\r\n"),
			{stop, normal}
	end;

% TODO brandid is hard coded, not good (it's the 00310003)
handle_cast({change_state, ringing, #call{} = Call}, State) ->
	?CONSOLE("change_state to ringing with call ~p", [Call]),
	Counter = State#state.counter,
	gen_tcp:send(State#state.socket, "ASTATE " ++ integer_to_list(Counter) ++ " " ++ integer_to_list(agent:state_to_integer(ringing)) ++ "\r\n"),
	gen_tcp:send(State#state.socket, "CALLINFO " ++ integer_to_list(Counter+1) ++ " 00310003 " ++ atom_to_list(Call#call.type) ++ " " ++ Call#call.callerid  ++ "\r\n"),
	{noreply, State#state{counter = Counter + 2}};

handle_cast({change_state, AgState, _Data}, State) ->
	Counter = State#state.counter,
	gen_tcp:send(State#state.socket, "ASTATE " ++ integer_to_list(Counter) ++ " " ++ integer_to_list(agent:state_to_integer(AgState)) ++ "\r\n"),
	{noreply, State#state{counter = Counter + 1}};

handle_cast({change_state, AgState}, State) ->
	Counter = State#state.counter,
	gen_tcp:send(State#state.socket, "ASTATE " ++ integer_to_list(Counter) ++ " " ++ integer_to_list(agent:state_to_integer(AgState)) ++ "\r\n"),
	{noreply, State#state{counter = Counter + 1}};

handle_cast(_Msg, State) ->
	{noreply, State}.
	
handle_info({tcp, Socket, Packet}, State) ->
	Ev = parse_event(Packet),
	case handle_event(Ev, State) of
		{Reply, State2} ->
			ok = gen_tcp:send(Socket, Reply ++ "\r\n"),
			State3 = State2#state{send_queue = flush_send_queue(lists:reverse(State2#state.send_queue), Socket)},
			% Flow control: enable forwarding of next TCP message
			ok = inet:setopts(Socket, [{active, once}]),
			{noreply, State3};
		State2 ->
			% Flow control: enable forwarding of next TCP message
			ok = inet:setopts(Socket, [{active, once}]),
			{noreply, State2}
	end;

handle_info({tcp_closed, _Socket}, State) ->
	io:format("Client disconnected~n", []),
	gen_fsm:send_all_state_event(State#state.agent_fsm, stop),
	{stop, normal, State};

handle_info(do_tick, #state{resend_counter = Resends} = State) when Resends > 2 ->
	?CONSOLE("Resend threshold exceeded, disconnecting: ~p", [Resends]),
	gen_fsm:send_all_state_event(State#state.agent_fsm, stop),
	{stop, normal, State};
handle_info(do_tick, State) ->
	ExpiredEvents = lists:filter(fun(X) -> timer:now_diff(now(), element(4,X)) >= 60000000 end, State#state.resent),
	ResendEvents = lists:filter(fun(X) -> timer:now_diff(now(), element(4,X)) >= 10000000 end, State#state.unacked),
	lists:foreach(fun({Counter, Event, Data, _Time}) ->
		?CONSOLE("Expired event ~s ~p ~s", [Event, Counter, Data])
	end, ExpiredEvents),
	State2 = State#state{unacked = lists:filter(fun(X) -> timer:now_diff(now(), element(4,X)) < 10000000 end, State#state.unacked)},
	State3 = State2#state{resent = lists:append(lists:filter(fun(X) -> timer:now_diff(now(), element(4,X)) < 60000000 end, State#state.resent), ResendEvents)},
	case length(ResendEvents) of
		0 ->
			{noreply, State3};
		_Else ->
			{noreply, resend_events(ResendEvents, State3)}
	end;

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

handle_event(["GETSALT", Counter], State) when is_integer(Counter) ->
	State2 = State#state{salt=crypto:rand_uniform(0, 4294967295)}, %bounds of number
	{ack(Counter, integer_to_list(State2#state.salt)), State2};

handle_event(["LOGIN", Counter, _Credentials], State) when is_integer(Counter), is_atom(State#state.salt) ->
	{err(Counter, "Please request a salt with GETSALT first"), State};

handle_event(["LOGIN", Counter, Credentials], State) when is_integer(Counter), is_atom(State#state.agent_fsm) ->
	case util:string_split(Credentials, ":", 2) of
		[Username, Password] ->
			case agent_auth:auth(Username, Password, integer_to_list(State#state.salt)) of
				deny -> 
					io:format("Authentication failure~n"),
					{err(Counter, "Authentication Failure"), State};
				{allow, Skills} -> 
					io:format("Authenciation success, next steps..."),
					{_Reply, Pid} = agent_manager:start_agent(#agent{login=Username, skills=Skills}),
					case agent:set_connection(Pid, self()) of
						ok ->
							State2 = State#state{agent_fsm=Pid},
							io:format("User ~p has authenticated using ~p.~n", [Username, Password]),
							{MegaSecs, Secs, _MicroSecs} = now(),
							% TODO 1 1 1 should be updated to correct info (security level, profile id, current timestamp).
							{ack(Counter, io_lib:format("1 1 ~p~p", [MegaSecs, Secs])), State2};
						error ->
							{err(Counter, Username ++ " is already logged in"), State}
					end
			end;
			_Else ->
				{err(Counter, "Authentication Failure"), State}
	end;

handle_event([_Event, Counter], State) when is_integer(Counter), is_atom(State#state.agent_fsm) ->
	{err(Counter, "This is an unauthenticated connection, the only permitted actions are GETSALT and LOGIN"), State};

handle_event(["PING", Counter], State) when is_integer(Counter) ->
	{MegaSecs, Secs, _MicroSecs} = now(),
	{ack(Counter, integer_to_list(MegaSecs) ++ integer_to_list(Secs)), State};

handle_event(["STATE", Counter, AgState, AgStateData], State) when is_integer(Counter) ->
	?CONSOLE("Trying to set state to ~p with data ~p.", [AgState, AgStateData]),
	try agent:list_to_state(AgState) of
		released ->
			try list_to_integer(AgStateData) of
				ReleaseState ->
					case agent:set_state(State#state.agent_fsm, released, {ReleaseState, 0}) of % {humanReadable, release_reason_id}
						ok ->
							{ack(Counter), State};
						queued ->
							{ack(Counter), State};
						invalid ->
							{ok, OldState} = agent:query_state(State#state.agent_fsm),
							{err(Counter, "Invalid state change from " ++ atom_to_list(OldState) ++ " to released"), State}
					end
			catch
				_:_ ->
					{err(Counter, "Invalid release option"), State}
			end;
		NewState ->
			case agent:set_state(State#state.agent_fsm, NewState, AgStateData) of
				ok ->
					{ack(Counter), State};
				invalid ->
					{ok, OldState} = agent:query_state(State#state.agent_fsm),
					{err(Counter, "Invalid state change from " ++ atom_to_list(OldState) ++ " to " ++ atom_to_list(NewState)), State}
			end
	catch
		_:_ ->
			{err(Counter, "Invalid state " ++ AgState), State}
	end;

handle_event(["STATE", Counter, AgState], State) when is_integer(Counter) ->
	?CONSOLE("Trying to set state ~p.", [AgState]),
	try agent:list_to_state(AgState) of
		NewState ->
			case agent:set_state(State#state.agent_fsm, NewState) of
				ok ->
					{ack(Counter), State};
				invalid ->
					{ok, OldState} = agent:query_state(State#state.agent_fsm),
					{err(Counter, "Invalid state change from " ++ atom_to_list(OldState) ++ " to " ++ atom_to_list(NewState)), State}
			end
	catch
		_:_ ->
			{err(Counter, "Invalid state " ++ AgState), State}
	end;

% TODO Hardcoding...
handle_event(["BRANDLIST", Counter], State) when is_integer(Counter) ->
	{ack(Counter, "(0031003|Slic.com),(00420001|WTF)"), State};

handle_event(["PROFILES", Counter], State) when is_integer(Counter) ->
	{ack(Counter, "1:Level1 2:Level2 3:Level3 4:Supervisor"), State};

handle_event(["QUEUENAMES", Counter], State) when is_integer(Counter) ->
	% queues only have one name right now...
	Queues = string:join(lists:map(fun({Name, _Pid}) -> io_lib:format("~s|~s", [Name, Name]) end,queue_manager:queues()), "),("),
	{ack(Counter, io_lib:format("(~s)", [Queues])), State};

handle_event(["RELEASEOPTIONS", Counter], State) when is_integer(Counter) ->
	{ack(Counter, "1:bathroom:0,2:smoke:-1"), State};

handle_event(["ENDWRAPUP", Counter], State) when is_integer(Counter) ->
	case agent:query_state(State#state.agent_fsm) of
		{ok, wrapup} ->
			case agent:set_state(State#state.agent_fsm, idle) of
				ok ->
					{ok, Curstate} = agent:query_state(State#state.agent_fsm),
					State2 = send("ASTATE", integer_to_list(agent:state_to_integer(Curstate)), State),
					{ack(Counter), State2};
				invalid ->
					{err(Counter, "invalid state"), State}
			end;
		_Else ->
			{err(Counter, "Agent must be in wrapup to send an ENDWRAPUP"), State}
	end;

% XXX - only for testing
handle_event(["UNACKTEST", Counter], State) when is_integer(Counter) ->
	State2 = send("NOACK", "", State),
	{ack(Counter), State2};

handle_event(["ACK" | [Counter | _Args]], State) when is_integer(Counter) ->
	State#state{unacked = lists:filter(fun(X) -> element(1, X) =/= Counter end, State#state.unacked), resend_counter=0};

handle_event(["ACK", Counter], State) when is_integer(Counter) ->
	State#state{unacked = lists:filter(fun(X) -> element(1, X) =/= Counter end, State#state.unacked), resend_counter=0};

% beware for here be errors 
handle_event(["ERR" | [Counter | _Args]], State) when is_integer(Counter) ->
	State#state{unacked = lists:filter(fun(X) -> element(1, X) =/= Counter end, State#state.unacked), resend_counter=0};

handle_event(["ERR", Counter], State) when is_integer(Counter) ->
	State#state{unacked = lists:filter(fun(X) -> element(1, X) =/= Counter end, State#state.unacked), resend_counter=0};

handle_event([Event, Counter], State) when is_integer(Counter) ->
	{err(Counter, "Unknown event " ++ Event), State};

handle_event([Event, Counter, _Args], State) when is_integer(Counter) ->
	{err(Counter, "Unknown event " ++ Event), State};

% TODO - do we need this?
%handle_event([Event | [Counter | _Args]], State) when is_integer(Counter) ->
	%{err(Counter, "invalid arguments for event " ++ Event), State};
	
handle_event(_Stuff, State) ->
	{"ERR Invalid Event, missing or invalid counter", State}.

parse_event(String) ->
	case util:string_split(string:strip(util:string_chomp(String)), " ", 3) of
		[Event] ->
			[Event];
		[Event, Counter] ->
			[Event, parse_counter(Counter)];
		[Event, Counter, Args] ->
			lists:append([Event, parse_counter(Counter)], util:string_split(Args, " "));
		[] ->
			[]
	end.

parse_counter(Counter) ->
	try list_to_integer(Counter) of
		IntCounter -> IntCounter
	catch
		_:_ -> Counter
	end.

ack(Counter, Data) ->
	"ACK " ++ integer_to_list(Counter) ++ " " ++ Data.

ack(Counter) ->
	"ACK " ++ integer_to_list(Counter).

err(Counter, Error) ->
	"ERR " ++ integer_to_list(Counter) ++ " " ++ Error.

-spec(send/3 :: (Event :: string(), Message :: string(), State :: #state{}) -> #state{}).
send(Event, Message, State) ->
	Counter = State#state.counter,
	SendQueue = [Event++" "++integer_to_list(Counter)++" "++Message | State#state.send_queue],
	UnackedEvents = [{Counter, Event, Message, now()} | State#state.unacked],
	State#state{counter=Counter + 1, send_queue=SendQueue, unacked=UnackedEvents}.

-spec(flush_send_queue/2 :: (Queue :: [string()], Socket :: port()) -> []).
flush_send_queue([], _Socket) ->
	[];
flush_send_queue([H|T], Socket) ->
	io:format("sent ~p to socket~n", [H]),
	gen_tcp:send(Socket, H ++ "\r\n"),
	flush_send_queue(T, Socket).

-spec(resend_events/2 :: (Events :: [unacked_event()], State :: #state{}) -> #state{}).
resend_events([], State) ->
	State#state{resend_counter = State#state.resend_counter + 1};
resend_events([{Counter, Event, Data, _Time}|T], State) ->
	?CONSOLE("Resending event ~s ~p ~s", [Event, Counter, Data]),
	resend_events(T, send(Event, Data, State)).

-ifdef(EUNIT).

unauthenticated_agent_test_() ->
	{
		foreach,
		fun() ->
			crypto:start(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			agent_auth:start(),
			agent_auth:cache("Username", erlang:md5("Password"), [skill1, skill2]),
			agent_manager:start([node()]),
			#state{}
		end,
		fun(_State) ->
			agent_auth:stop(),
			agent_manager:stop(),
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			ok
		end,
		[
			fun(State) ->
				{"Agent can only send GETSALT and LOGIN until they're authenticated",
				fun() ->
						{Reply, _State2} = handle_event(["PING",  1], State),
						?assertEqual("ERR 1 This is an unauthenticated connection, the only permitted actions are GETSALT and LOGIN", Reply)
				end}
			end,

			fun(State) ->
				{"Agent must get a salt with GETSALT before sending LOGIN",
				fun() ->
					{Reply, _State2} = handle_event(["LOGIN",  2, "username:password"], State),
					?assertEqual("ERR 2 Please request a salt with GETSALT first", Reply)
				end}
			end,

			fun(State) ->
				{"GETSALT returns a random number",
				fun() ->
					{Reply, _State2} = handle_event(["GETSALT",  3], State),

					[_Ack, Counter, Args] = util:string_split(string:strip(util:string_chomp(Reply)), " ", 3),
					?assertEqual(Counter, "3"),

					{Reply2, _State3} = handle_event(["GETSALT",  4], State),
					[_Ack2, Counter2, Args2] = util:string_split(string:strip(util:string_chomp(Reply2)), " ", 3),
					?assertEqual(Counter2, "4"),
					?assertNot(Args =:= Args2)
				end}
			end,

			fun(State) ->
				{"LOGIN with no password",
				fun() ->
					{_Reply, State2} = handle_event(["GETSALT",  3], State),
					{Reply, _State3} = handle_event(["LOGIN",  2, "username"], State2),
					?assertMatch(["ERR", "2", "Authentication Failure"], util:string_split(string:strip(util:string_chomp(Reply)), " ", 3))
				end}
			end,

			fun(State) ->
				{"LOGIN with blank password",
				fun() ->
					{_Reply, State2} = handle_event(["GETSALT",  3], State),
					{Reply, _State3} = handle_event(["LOGIN",  2, "username:"], State2),
					?assertMatch(["ERR", "2", "Authentication Failure"], util:string_split(string:strip(util:string_chomp(Reply)), " ", 3))
				end}
			end,

			fun(State) ->
				{"LOGIN with bad credentials",
				fun() ->
					{_Reply, State2} = handle_event(["GETSALT",  3], State),
					{Reply, _State3} = handle_event(["LOGIN",  2, "username:password"], State2),
					?assertMatch(["ERR", "2", "Authentication Failure"], util:string_split(string:strip(util:string_chomp(Reply)), " ", 3))
				end}
			end,
			fun(State) ->
				{"LOGIN with good credentials",
				fun() ->
					{Reply, State2} = handle_event(["GETSALT",  3], State),
					[_Ack, "3", Args] = util:string_split(string:strip(util:string_chomp(Reply)), " ", 3),
					Password = string:to_lower(util:bin_to_hexstr(erlang:md5(Args ++ string:to_lower(util:bin_to_hexstr(erlang:md5("Password")))))),
					{Reply2, _State3} = handle_event(["LOGIN",  4, "Username:" ++ Password], State2),
					?assertMatch(["ACK", "4", _Args], util:string_split(string:strip(util:string_chomp(Reply2)), " ", 3))
				end}
			end,
			fun(State) ->
				{"LOGIN twice fails",
				fun() ->
					{Reply, State2} = handle_event(["GETSALT",  3], State),
					[_Ack, "3", Args] = util:string_split(string:strip(util:string_chomp(Reply)), " ", 3),
					Password = string:to_lower(util:bin_to_hexstr(erlang:md5(Args ++ string:to_lower(util:bin_to_hexstr(erlang:md5("Password")))))),
					{Reply2, _State3} = handle_event(["LOGIN",  4, "Username:" ++ Password], State2),
					?assertMatch(["ACK", "4", _Args], util:string_split(string:strip(util:string_chomp(Reply2)), " ", 3)),
					{Reply3, _State4} = handle_event(["LOGIN",  5, "Username:" ++ Password], State2),
					?assertMatch(["ERR", "5", _Args], util:string_split(string:strip(util:string_chomp(Reply3)), " ", 3))
				end}
			end
		]
	}.


authenticated_agent_test_() ->
	{
		foreach,
		fun() ->
			crypto:start(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			agent_auth:start(),
			agent_auth:cache("Username", erlang:md5("Password"), [skill1, skill2]),
			agent_manager:start([node()]),
			State = #state{},
			{Reply, State2} = handle_event(["GETSALT",  3], State),
			[_Ack, "3", Args] = util:string_split(string:strip(util:string_chomp(Reply)), " ", 3),
			Password = string:to_lower(util:bin_to_hexstr(erlang:md5(Args ++ string:to_lower(util:bin_to_hexstr(erlang:md5("Password")))))),
			{_Reply2, State3} = handle_event(["LOGIN",  4, "Username:" ++ Password], State2),
			State3
		end,
		fun(_State) ->
			agent_auth:stop(),
			agent_manager:stop(),
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			ok
		end,
		[
			fun(State) ->
				{"LOGIN should be an unknown event",
				fun() ->
					{Reply, _State2} = handle_event(["LOGIN",  3, "username:password"], State),
					?assertEqual("ERR 3 Unknown event LOGIN", Reply)
				end}
			end,

			fun(State) ->
				{"PING should return the current timestamp",
				fun() ->
					{MegaSecs, Secs, _MicroSecs} = now(),
					Now = list_to_integer(integer_to_list(MegaSecs) ++ integer_to_list(Secs)),
					timer:sleep(1000),
					{Reply, _State2} = handle_event(["PING", 3], State),
					["ACK", "3", Args] = util:string_split(string:strip(util:string_chomp(Reply)), " ", 3),
					Pingtime = list_to_integer(Args),
					?assert(Now < Pingtime),
					timer:sleep(1000),
					{MegaSecs2, Secs2, _MicroSecs2} = now(),
					Now2 = list_to_integer(integer_to_list(MegaSecs2) ++ integer_to_list(Secs2)),
					?assert(Now2 > Pingtime)
				end}
			end,

			fun(State) ->
				{"ENDWRAPUP should not work while in not in wrapup",
				fun() ->
					{Reply, _State2} = handle_event(["ENDWRAPUP", 3], State),
					?assertEqual("ERR 3 Agent must be in wrapup to send an ENDWRAPUP", Reply)
				end}
			end,

			fun(State) ->
				{"ENDWRAPUP should work while in wrapup",
				fun() ->
					Call = #call{id="testcall", source=self()},
					?assertEqual(ok, agent:set_state(State#state.agent_fsm, idle)),
					?assertEqual(ok, agent:set_state(State#state.agent_fsm, ringing, Call)),
					?assertEqual(ok, agent:set_state(State#state.agent_fsm, oncall, Call)),
					?assertEqual(ok, agent:set_state(State#state.agent_fsm, wrapup, Call)),
					{Reply, _State2} = handle_event(["ENDWRAPUP", 3], State),
					?assertEqual("ACK 3", Reply)
				end
				}
			end
		]
	}.

socket_enabled_test_() ->
	{
		foreach,
		fun() ->
			crypto:start(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			agent_auth:start(),
			agent_auth:cache("Username", erlang:md5("Password"), [skill1, skill2]),
			agent_manager:start([node()]),
			{ok, Pid} = agent_tcp_listener:start(),
			{ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, 1337, [inet, list, {active, false}]),
			%timer:sleep(1000),
			%State = #state{},
			%{Reply, State2} = handle_event(["GETSALT",  3], State),
			%[_Ack, "3", Args] = util:string_split(string:strip(util:string_chomp(Reply)), " ", 3),
			%Password = string:to_lower(util:bin_to_hexstr(erlang:md5(Args ++ string:to_lower(util:bin_to_hexstr(erlang:md5("Password")))))),
			%{_Reply2, State3} = handle_event(["LOGIN",  4, "Username:" ++ Password], State2),
			%State3
			{Socket, Pid}
		end,
		fun({Socket, Pid}) ->
			agent_auth:stop(),
			agent_manager:stop(),
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			agent_tcp_listener:stop(Pid),
			gen_tcp:close(Socket),
			ok
		end,
		[
			fun({Socket, _Pid}) ->
				{"Negiotiate protocol with correct version",
				fun() ->
					?debugFmt("getting initial banner~n", []),
					{ok, Packet} = gen_tcp:recv(Socket, 0),
					?assertEqual("Agent Server: -1\r\n", Packet),
					gen_tcp:send(Socket, io_lib:format("Protocol: ~p.~p\r\n", [?Major, ?Minor])),
					{ok, Packet2} = gen_tcp:recv(Socket, 0),
					?assertEqual("0 OK\r\n", Packet2)
				end}
			end,
			fun({Socket, _Pid}) ->
				{"Negiotiate protocol with minor version mismatch",
				fun() ->
					?debugFmt("getting initial banner~n", []),
					{ok, Packet} = gen_tcp:recv(Socket, 0),
					?assertEqual("Agent Server: -1\r\n", Packet),
					gen_tcp:send(Socket, io_lib:format("Protocol: ~p.~p\r\n", [?Major, ?Minor -1])),
					{ok, Packet2} = gen_tcp:recv(Socket, 0),
					?assertEqual("1 Protocol version mismatch. Please consider upgrading your client\r\n", Packet2)
				end}
			end,
			fun({Socket, _Pid}) ->
				{"Negiotiate protocol with major version mismatch",
				fun() ->
					?debugFmt("getting initial banner~n", []),
					{ok, Packet} = gen_tcp:recv(Socket, 0),
					?assertEqual("Agent Server: -1\r\n", Packet),
					gen_tcp:send(Socket, io_lib:format("Protocol: ~p.~p\r\n", [?Major -1, ?Minor])),
					{ok, Packet2} = gen_tcp:recv(Socket, 0),
					?assertEqual("2 Protocol major version mismatch. Login denied\r\n", Packet2)
				end}
			end,
			fun({Socket, _Pid}) ->
				{"Negiotiate protocol with non-integer version",
				fun() ->
					?debugFmt("getting initial banner~n", []),
					{ok, Packet} = gen_tcp:recv(Socket, 0),
					?assertEqual("Agent Server: -1\r\n", Packet),
					gen_tcp:send(Socket, "Protocol: a.b\r\n"),
					{ok, Packet2} = gen_tcp:recv(Socket, 0),
					?assertEqual("2 Invalid Response. Login denied\r\n", Packet2)
				end}
			end,
			fun({Socket, _Pid}) ->
				{"Negiotiate protocol with gibberish",
				fun() ->
					?debugFmt("getting initial banner~n", []),
					{ok, Packet} = gen_tcp:recv(Socket, 0),
					?assertEqual("Agent Server: -1\r\n", Packet),
					gen_tcp:send(Socket, "asdfasdf\r\n"),
					{ok, Packet2} = gen_tcp:recv(Socket, 0),
					?assertEqual("2 Invalid Response. Login denied\r\n", Packet2)
				end}
			end
		]
	}.
	
-define(MYSERVERFUNC, 
	fun() -> 
		{ok, Pid} = start_link("garbage data"), 
		{Pid, fun() -> exit(Pid) end} 
	end).

-include("gen_server_test.hrl").

-endif.
