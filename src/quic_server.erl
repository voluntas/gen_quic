%%%-------------------------------------------------------------------
%%% @author alex <alex@alex-Lenovo>
%%% @copyright (C) 2018, alex
%%% @doc
%%%
%%% @end
%%% Created : 30 May 2018 by alex <alex@alex-Lenovo>
%%%-------------------------------------------------------------------
-module(quic_server).

-behaviour(gen_server).

-export([listen/2, accept/2, close/1, controlling_process/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).


-spec listen(Port, Opts) -> Result when
    Port :: inet:port_number(),
    Opts :: [Opt],
    Opt :: gen_quic:option(),
    Result :: {ok, LSocket} | {error, Reason},
    LSocket :: gen_quic:socket(),
    Reason :: gen_quic:errors().

listen(Port, Opts) ->
  ?DBG("Opening Socket for listening on~n", []),
  {ok, Socket} = inet_udp:open(Port, Opts),

  {ok, Pid} = gen_server:start_link(via(Socket), ?MODULE, 
                                    [self()], []),
  inet_udp:controlling_process(Socket, Pid),
  ?DBG("Gen Server Started~n", []),
  {ok, Socket}.


-spec accept(LSocket, Timeout) -> Result when
    LSocket :: inet:socket(),
    Timeout :: non_neg_integer(),
    Result :: {ok, Socket} | {error, Reason},
    Socket :: inet:socket(),
    Reason :: gen_quic:errors().

accept(LSocket, Timeout) ->
  case gen_server:call(via(LSocket), {accept, LSocket, Timeout}) of
    {ok, Conn, Initial_Data} ->
      quic_prim:accept(Conn, Initial_Data);

    {error, timeout} ->
      {error, timeout};

    Other ->
      ?DBG("Accept failed: ~p~n", [Other]),
      Other
  end.


-spec close(Socket) -> ok when
    Socket :: inet:socket().

close(LSocket) ->
  gen_server:stop(via(LSocket), {shutdown, LSocket}, infinity).

-spec controlling_process(Socket, Pid) -> Result when
    Socket :: inet:socket(),
    Pid :: pid(),
    Result :: ok | {error, Reason},
    Reason :: inet:posix() | not_owner.

controlling_process(Socket, Pid) ->
  gen_server:call(via(Socket), {new_owner, Pid}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init([Owner]) -> {ok, State} when
    Owner :: pid(),
    State :: {Requests, Requests},
    Requests :: [Request],
    Request :: term().

init([Owner]) ->
  process_flag(trap_exit, true),
  {ok, {Owner, {[], []}}}.


-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
                     {reply, Reply :: term(), NewState :: term()} |
                     {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
                     {reply, Reply :: term(), NewState :: term(), hibernate} |
                     {noreply, NewState :: term()} |
                     {noreply, NewState :: term(), Timeout :: timeout()} |
                     {noreply, NewState :: term(), hibernate} |
                     {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
                     {stop, Reason :: term(), NewState :: term()}.

handle_call({accept, LSocket, Timeout}, From, {From, {[], []}}) ->
  immediate_accept(LSocket, Timeout);

handle_call(Request, From, {From, {[], Reversed}}) ->
  handle_call(Request, From, {From, {lists:reverse(Reversed), []}});

handle_call({accept, _LSocket, _Timeout}, 
            From, 
            {From, {[Next | Rest], Reversed}}) ->
  ?DBG("Returning next request~n", []),
  {reply, Next, {From, {Rest, Reversed}}};

handle_call({accept, _LSocket, _Timeout},
            From,
            {Owner, {Next, Rest}}) ->
  %% Someone other than the owning process requested an accept.
  {reply, {error, not_owner}, {Owner, {Next, Rest}}};

handle_call({new_owner, Pid}, From, {From, {Next, Rest}}) ->
  {reply, ok, {Pid, {Next, Request}}};


handle_call({new_owner, Pid}, From, {Owner, {Next, Rest}}) ->
  %% Someone other than the owning process requested ownership change.
  {reply, {error, not_owner}, {Owner, {Next, Request}}};


handle_call(Other, _From, State) ->
  ?DBG("Weird Request: ~p~n", [Other]),
  {reply, ok, State}.


-spec handle_cast(Request :: term(), State :: term()) ->
                     {noreply, NewState :: term()} |
                     {noreply, NewState :: term(), Timeout :: timeout()} |
                     {noreply, NewState :: term(), hibernate} |
                     {stop, Reason :: term(), NewState :: term()}.

handle_cast(Request, State) ->
  {noreply, State}.


-spec handle_info(Info :: timeout() | term(), State :: term()) ->
                     {noreply, NewState :: term()} |
                     {noreply, NewState :: term(), Timeout :: timeout()} |
                     {noreply, NewState :: term(), hibernate} |
                     {stop, Reason :: normal | term(), NewState :: term()}.

handle_info({udp, LSocket, IP, Port, Packet}, 
            {Owner, {Ordered, Reversed}}=State) ->

  ?DBG("Packet received in listening server from: ~p:~p. Parsing.~n", 
       [IP, Port]),
  Conn0 = #quic_conn{ip_addr=IP, port=Port},

  case quic_packet:parse_packet(Packet, Conn0) of
    {ok, Conn, Frames} ->
      {noreply, {Owner, {Ordered, [{ok, Conn, Frames} | Reversed]}}};

    {error, Reason} ->
      ?DBG("Invalid packet received from IP: ~p, Port: ~p~n", 
           [IP, Port]),
      {noreply, State}
  end;

handle_info(Request, State) ->
  %% ignore everything else.
  {noreply, State}.


-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().

terminate({shutdown, LSocket}, State) ->
  %% Close the socket and ignore any unaccepted connections
  inet_udp:close(LSocket).


-spec code_change(OldVsn :: term() | {down, term()},
                  State :: term(),
                  Extra :: term()) -> {ok, NewState :: term()} |
                                      {error, Reason :: term()}.

code_change(_Old, State, _Extra) ->
  {ok, State}.


-spec format_status(Opt, Status) -> Status when
    Opt :: normal | terminate,
    Status :: list().

format_status(_Opts, Status) ->
  Status.

%%% ================================================================
%%% Internal Functions
%%% ================================================================

%% A simple function to shorten code for the gen_server calls, casts, etc.
via(Socket) ->
  {via, quic_registry, Socket).


-spec immediate_accept(LSocket, Timer) -> Reply when
    LSocket :: inet:socket(),
    Timer :: {timer, reference()} | non_neg_integer(),
    Reply :: {ok, Record, Record} | {error, Reason},
    Record :: term(),
    Reason :: inet:posix() | timeout.

immediate_accept(LSocket, {timer, Timer_Ref}) ->
  receive
    {udp, LSocket, IP, Port, Init_Packet} ->
      ?DBG("Packet received in listening server from: ~p:~p. Parsing.~n", 
           [IP, Port]),
      Conn0 = #quic_conn{ip_addr=IP, port=Port},

      case quic_packet:parse_packet(Init_Packet, Conn0) of
        {ok, Conn, Frames} ->
          %% Cancel the timer after a successful packet is received.;
          erlang:cancel_timer(Timer_Ref),
          {reply, {ok, Conn, Frames}, State};

        {error, Reason} ->
          ?DBG("Invalid packet received from IP: ~p, Port: ~p~n", 
               [IP, Port]),
          immediate_accept(LSocket, {timer, Timer_Ref})
      end;

    {timeout, Timer_Ref, accept} ->
      {reply, {error, timeout}, State};

    {timeout, Other_timer, accept} ->
      %% Ignore other timers that do not match. A timer message could
      %% be sent when parsing the packet and not be canceled in time.
      immediate_accept({timer, Timer_Ref})
  end;

immediate_accept(LSocket, infinity) ->
  %% Don't start a timer and just enter the receive loop.
  immediate_accept(LSocket, {timer, none});

immediate_accept(LSocket, Timeout) ->
  %% start timer and enter receive loop for a new connection attempt.
  Timer_Ref = erlang:start_timer(Timeout, self(), accept, []),
  immediate_accept(LSocket, {timer, Timer_Ref}).

