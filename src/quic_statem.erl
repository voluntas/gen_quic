%%%-------------------------------------------------------------------
%%% @author alex <alex@alex-Lenovo>
%%% @copyright (C) 2018, alex
%%% @doc
%%%
%%% @end
%%% Created : 13 Oct 2018 by alex <alex@alex-Lenovo>
%%%-------------------------------------------------------------------
-module(quic_statem).

-behaviour(gen_statem).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([handle_event/4]).

-include("quic_headers.hrl").

%%%===================================================================
%%% API
%%%===================================================================



%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> handle_event_function.


-spec init([Args]) -> Result when
    Args :: Data | Options,
    Data :: quic_data(),
    Options :: map(),
    Result :: {ok, {initial, Type}, Data},
    Type :: client | server.

init([#{type := Type} = Data0, Quic_Opts]) ->
  io:format("Initializing Crypto.~n"),
  {ok, Data1} = quic_crypto:default_params(Data0, Quic_Opts),
  Staging_Priority = maps:get(packing_priority, Quic_Opts, none),
  %% Dialyzer says the maps:get call will fail, when it should not fail.
  {ok, Data2} = quic_staging:init(Data1, Staging_Priority),
  io:format("Staging Initialized.~n"),
  case Type of
    server ->
      {ok, {initial, Type}, Data2};
    client ->
      {ok, Data3} = quic_crypto:crypto_init(Data2),
      {ok, Data4} = quic_crypto:rekey(Data3),
      {ok, {initial, Type}, Data4}
  end.


handle_event({call, From}, {connect, Address, Port, Timeout}, {initial, client},
             #{conn := #{socket := Socket} = Conn0
              } = Data0) ->
  %% Only the client can call connect.  
  ok = inet:setopts(Socket, [{active, true}]),

  gen_statem:cast(self(), {send_handshake, client_hello}),
  Data = Data0#{conn := Conn0#{address => Address,
                               port => Port,
                               owner => From}},
  {keep_state, Data, [{{timeout, handshake}, Timeout, {error, timeout}}]};

handle_event({call, From}, {accept, LSocket, Timeout}, {initial, server}, 
             #{conn := Conn0} = Data0) ->
  %% Only the server can call accept.
  gen_statem:cast(self(), {accept, LSocket}),
  Data = Data0#{conn := Conn0#{owner => From}},

  {keep_state, Data, {{timeout, handshake}, Timeout, {error, timeout}}};

handle_event(cast, connect, {initial, client}, Data0) ->
  Data = send_and_form_packet(client_hello, Data0),
  {keep_state, Data};

handle_event(cast, {accept, LSocket}, {initial, server},
             #{conn := Conn0} = Data0) ->

  case prim_inet:recvfrom(LSocket, 0, 50) of
    {error, timeout} ->
      %% Nothing received so repeat state and event.
      gen_statem:cast(self(), {accept, LSocket}),
      keep_state_and_data;

    {ok, {IP, Port, Packet}} ->
      %% Received a packet. Parse the header to get the initial crypto info.
      Conn = Conn0#{address => IP,
                    port => Port
                   },

      case decrypt_and_parse_packet(Data0#{conn := Conn}, Packet, 0) of
        {error, invalid_initial} ->
          %% Send a retry packet back.
          %% TODO: Figure out how to do that.
          gen_statem:cast(self(), {accept, LSocket}),
          keep_state_and_data;

        {ok, Data} ->
          %% The accept will be ignored if the initial packet validates and
          %% the statem trasitions to the handshake state.
          gen_statem:cast(self(), {accept, LSocket}),
          {keep_state, Data};

        {error, _Reason} ->
          %% Ignore everything else.
          gen_statem:cast(self(), {accept, LSocket}),
          keep_state_and_data
      end
  end;

handle_event(cast, {accept, _LSocket}, {_Not_Initial, server}, _Data) ->
  %% Needed to flush the {accept, LSocket} message sent if the packet does not validate.
  keep_state_and_data;

handle_event(internal, continue_handshake, {initial, server}, Data) ->
  %% The server must send encrypted_exts, certificate, cert_verify, and finished in the
  %% handshake state.
  gen_statem:cast(self(), {send_handshake, encrypted_exts}),
  gen_statem:cast(self(), {send_handshake, certificate}),
  gen_statem:cast(self(), {send_handshake, cert_verify}),
  gen_statem:cast(self(), {send_handshake, finished}),
  {next_state, {handshake, server}, Data};

handle_event(internal, continue_handshake, {initial, client}, Data) ->
  %% Client does not send anything else in the initial state.
  {next_state, {handshake, client}, Data};

handle_event(internal, continue_handshake, {handshake, client}, Data) ->
  %% The client does send a finished packet in the handshake state.
  %% TODO: Expand to include other TLS messages like certificate and cert_verify.
  gen_statem:cast(self(), {send_handshake, finished}),
  {next_state, {connected, client}, Data};

handle_event(internal, continue_handshake, {handshake, server}, Data) ->
  %% The server does not send anything else in the handshake state.
  {next_state, {connected, server}, Data};

handle_event(cast, {send_handshake, Pkt_Type}, _State, Data0) ->
  %% Should be common across all states.
  Data = send_and_form_packet(Pkt_Type, Data0),
  {keep_state, Data};

handle_event(cast, {handle_crypto, initial, <<>>, TLS_Info}, {initial, client},
             Data) ->
  %% Token is empty on the server's initial reply.
  validate_and_reply(initial, TLS_Info, Data);

handle_event(cast, {handle_crypto, initial, Token, TLS_Info}, {initial, server},
             #{retry_token := Token} = Data) ->
  %% The Tokens match so perform a crypto step.
  validate_and_reply(initial, TLS_Info, Data);

handle_event(cast, {handle_crypto, initial, _Wrong_Token, TLS_Info}, {initial, server},
             Data) ->
  %% The Token from the client does not match the token on the server side.
  %% TODO: Send a stateless reset.
  %% Handle as normal for now.
  validate_and_reply(initial, TLS_Info, Data);

handle_event(cast, {handle_crypto, Packet_Level, TLS_Info}, _State, Data) ->
  %% Handling the remaining crypto packets should be common across all states.
  validate_and_reply(Packet_Level, TLS_Info, Data);

handle_event(cast, {handle_encrypted, Packet, Attempt}, _State, Data0) ->
  %% decrypt_and_parse_packet self-casts successes as handle, handle_crypto, and handle_acks.
  case decrypt_and_parse_packet(Data0, Packet, Attempt) of
    {ok, Data} ->
      {keep_state, Data};

    {error, Reason} ->
      %% There is a parsing error outside the decryption.
      {keep_state_and_data, {next_event, internal, {protocol_violation, Reason}}}
  end;

handle_event(cast, {handle, Frames}, _State, Data0) ->
  %% Should be common across all states.
  case handle_frames(Data0, Frames) of
    {ok, Data} ->
      {keep_state, Data};

    {error, Reason} ->
      {keep_state_and_data, {next_event, internal, {protocol_violation, Reason}}}
  end;

handle_event(cast, {handle_acks, Crypto_Range, Ack_Frames}, {State, Type}, Data0) ->
  %% This function should be the same across all states
  case quic_cc:handle_acks(State, Data0, Crypto_Range, Ack_Frames) of
    %% {ok, Data} ->
    %%   {keep_state, Data};

    %% {error, Reason} ->
    %%   {keep_state_and_data, {next_event, internal, {protocol_violation, Reason}}};

    {New_State, Data} ->
      %% Transitions from slow_start to avoidance.
      {next_state, {New_State, Type}, Data};

    {recovery, Data, Event} ->
      {next_state, {recovery, Type}, Data, {next_event, internal, {congestion_event, Event}}}
  end;

handle_event(cast, {send, Frame}, {_State, _Type}, Data0) ->
  {ok, Data1} = quic_staging:enstage(Data0, Frame),
  {keep_state, Data1};

handle_event(internal, {congestion_event, {packets_lost, Pkt_Nums}}, {recovery, _Type}, Data0) ->
  {ok, Data1, Frames} = quic_cc:packet_lost(Data0, Pkt_Nums),
  {ok, Data2} = quic_staging:restage(Data1, Frames),
  Largest = lists:max(Pkt_Nums),
  {keep_state, Data2, {next_event, internal, {reduce_window, Largest}}};

handle_event(internal, {congestion_event, {ecn_event, Largest}}, {recovery, _Type}, _Data) ->
  %% Currently this does nothing, but that may change eventually, probably to send a notification to the application owner.
  {keep_state_and_data, {next_event, internal, {reduce_window, Largest}}};

handle_event(internal, {reduce_window, Largest}, {recovery, _Type}, Data0) ->
  {ok, Data} = quic_cc:congestion_event(Data0, Largest),
  {keep_state, Data};

handle_event(internal, rekey, {connected, _Type}, Data0) ->
  %% Almost common across all states.
  %% This one is called at the end of the crypto handshake.
  %% The success event replies to the socket owner.
  {ok, Data} = quic_crypto:rekey(Data0),
  {keep_state, Data, {next_event, internal, success}};

handle_event(internal, rekey, _State, Data0) ->
  {ok, Data} = quic_crypto:rekey(Data0),
  {keep_state, Data};

handle_event(internal, success, {_State, Type},
             #{conn := #{owner := Owner,
                         socket := Socket}} = Data) when is_pid(Owner) ->
  %% Cancel the timer for the handshake (set it to infinity).
  %% Reply to the owner with {ok, Socket} to indicate the connection is successful.
  {next_state, {slow_start, Type}, Data, [{{timeout, handshake}, infinity, none}, 
                                          {reply, Owner, {ok, Socket}}]};

handle_event(info, {udp, Socket, Address, Port, Packet}, {initial, client},
             #{conn := #{socket := Socket,
                         address := _Old_Address,
                         port := _Old_Port
                        } = Conn0
              } = Data0) ->
  %% The ip address and port could change as the server opens an accept socket.
  Data1 = Data0#{conn := Conn0#{address := Address,
                                port := Port}},

  case decrypt_and_parse_packet(Data1, Packet, 0) of
    {ok, Data} ->
      {keep_state, Data};

    {error, _Reason} ->
      %% This could be a stray UDP packet at this point.
      keep_state_and_data
  end;

handle_event(info, {udp, Socket, Address, Port, Packet}, _State,
             #{conn := #{socket := Socket,
                         address := Address,
                         port := Port}
              } = Data0) ->
  case decrypt_and_parse_packet(Data0, Packet, 0) of
    {ok, Data} ->
      {keep_state, Data};

    {error, Reason} ->
      {keep_state_and_data, {next_event, internal, {protocol_violation, Reason}}}
  end;

handle_event(internal, {protocol_violation, Reason}, _State, 
             #{conn := #{owner := Owner}} = Data) ->
  %% This function is the same across all states
  %% The connection is severed when there is a protocol violation and the owner is
  %% notified.
  {stop_and_reply, normal, {reply, Owner, {protocol_violation, Reason}}, Data}.


-spec terminate(Reason :: term(), State :: term(), Data :: term()) ->
                   any().
terminate(_Reason, _State, _Data) ->
  void.


-spec code_change(
        OldVsn :: term() | {down,term()},
        State :: term(), Data :: term(), Extra :: term()) ->
                     {ok, NewState :: term(), NewData :: term()} |
                     (Reason :: term()).
code_change(_OldVsn, State, Data, _Extra) ->
  {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Called when a crypto frame is received in order to validate it and act appropriately.
validate_and_reply(Packet_Level, TLS_Info, Data0) ->
  case quic_crypto:validate_tls(Data0, TLS_Info) of
    {invalid, Reason} ->
      {keep_state_and_data, {next_event, internal, {protocol_violation, Reason}}};

    {valid, Data1} ->
      %% Send back an ack in the correct packet range.
      Data2 = send_and_form_packet(Packet_Level, Data1),

      {keep_state, Data2, [{next_event, internal, rekey}, 
                           {next_event, internal, continue_handshake}]};

    {incomplete, Data1} ->
      %% When all the information to proceed to the next state is not received yet.
      {keep_state, Data1};

    out_of_order ->
      %% Re-cast it to itself in order to handle it in order.
      gen_statem:cast(self(), {handle_crypto, Packet_Level, TLS_Info}),
      keep_state_and_data
  end.


send_and_form_packet(Pkt_Type, Data) ->
  quic_conn:send_and_form_packet(Pkt_Type, Data).

decrypt_and_parse_packet(Data, Packet, Attempt) ->
  quic_conn:decrypt_and_parse_packet(Data, Packet, Attempt).

handle_frames(Data0, Frames) when is_list(Frames) ->
  lists:foldl(fun(Acc, Frame) -> quic_conn:handle_frame(Acc, Frame) end, 
              Data0, Frames).

