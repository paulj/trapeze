-module(trapeze_web).

-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([start_link/0]).
-export([handle_request/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
         
-record(state, {channel, outstanding, next_id, queue}).

-define(Exchange, <<"trapeze">>).
-define(UpstreamTimeoutMS, 10000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

handle_request(Req) ->
    case catch gen_server:call(?MODULE, {handle_request, Req}) of
        Resp ->  Resp
    end.
    
%% Callback Methods

init([]) ->
    Connection = amqp_connection:start_direct(),
    Ch = amqp_connection:open_channel(Connection),
    amqp_channel:register_return_handler(Ch, self()),
    #'queue.declare_ok'{queue = Queue}
        = amqp_channel:call(Ch, #'queue.declare'{exclusive = true, auto_delete = true}),
    amqp_channel:subscribe(Ch, #'basic.consume'{queue = Queue, no_ack = true}, self()),
    
    amqp_channel:call(Ch, #'exchange.declare'{exchange = ?Exchange,
                                              type = <<"topic">>,
                                              durable = true}),
    
    {ok, #state{channel = Ch, outstanding = ets:new(trapeze_outstanding, []),
                next_id = 0, queue = Queue}}.

handle_call({handle_request, Req}, _From, 
            State = #state{channel = Ch, outstanding = Outstanding,
                           next_id = NextId, queue = ReplyQueue}) ->
    %% Transform the request into an appropriate body to send across the wire
    Body = format_req(Req, Req:recv_body()),
    
    %% Build a routing key
    Method = string:to_lower(atom_to_list(Req:get(method))),
    Host = case Req:get_header_value(host) of
        undefined -> throw({error, 400, "Missing Host HTTP header"});
        MixedCaseHost -> string:to_lower(MixedCaseHost)
    end,
    "/" ++ Path = Req:get(raw_path),
    [Hostname, Port] = string:tokens(Host, ":"),
    RoutingKey = string:join([Method, Hostname, Port, "/"] ++ string:tokens(Path, "/"), "."),
    %% io:format("Using Routing Key: ~s~n", [RoutingKey]),

    %% Generate a message id
    MessageId = list_to_binary(integer_to_list(NextId)),
    
    %% Dispatch a message
    BasicPublish = #'basic.publish'{exchange = ?Exchange,
                                    routing_key = list_to_binary(RoutingKey),
                                    mandatory = true},
    Properties = #'P_basic'{ delivery_mode = 1, message_id = MessageId, 
                             reply_to = ReplyQueue },
    Content = #amqp_msg{props = Properties, payload = list_to_binary(Body)},
    
    case amqp_channel:call(Ch, BasicPublish, Content) of
        ok -> 
            %% Store the request for later response
            MessageHandler = spawn(
                fun () -> 
                    manage_request(Req, 
                                   fun() -> 
                                       gen_server:cast(?MODULE, {completed_request, MessageId})
                                   end)
                end),
            ets:insert(Outstanding, {MessageId, MessageHandler}),
            ok;
        Res -> 
            error(Req, 500, [], "Failed to send message", io_lib:format("~p", [Res]))
    end,
                
    {reply, ok, State#state{next_id = NextId + 1}};
handle_call(Req, _From, State) ->
    io:format("Request was ~p~n", [Req]),
    {reply, unknown_request, State}.
    
handle_cast({completed_request, MessageId}, State = #state{outstanding = Outstanding}) ->
    ets:delete(Outstanding, MessageId),
    {noreply, State};
handle_cast(C, State) -> 
    io:format("Got unknown cast: ~p~n", [C]), 
    {noreply, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};
handle_info({#'basic.return'{}, #amqp_msg{props = Properties}}, 
             State = #state{outstanding = Outstanding}) ->
    #'P_basic'{message_id = MessageId} = Properties,
    
    case ets:lookup(Outstanding, MessageId) of
        [{_, Handler}] ->
            Handler ! return;
        [] ->
            ok
    end,
    {noreply, State};
handle_info({#'basic.deliver'{}, #amqp_msg{props = Properties, 
                                           payload = Payload}},
            State = #state{outstanding = Outstanding}) ->
    #'P_basic'{correlation_id = MessageId} = Properties,
    case ets:lookup(Outstanding, MessageId) of
        [{_, Handler}] ->
            Handler ! {response, Payload};
        [] ->
            ok
    end,
    {noreply, State};
                                              
handle_info(I, State) -> 
    io:format("Got unknown info: ~p~n", [I]),
    {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.


%% Request Handlers
manage_request(Req, CancelFun) ->
    case catch receive_response(Req) of 
        completed       -> %% Request completed normally
            case catch CancelFun() of
                ok          -> ok;
                {'EXIT', Why} ->
                    io:format("Failed to Cancel! ~p~n", [Why])
            end;
        {'EXIT', _}     -> %% Failed sending the response
            CancelFun();
        B       -> 
            io:format("Handler error: ~p ~p~n", [B, erlang:get_stacktrace()]), 
            manage_request(Req, CancelFun)
    end.
receive_response(Req) ->
    receive
        {response, Body} ->
            case check_response(Body) of
                {error, Reason} ->
                    error(Req, 502, [], "Bad response from downstream", Reason);
                {ok, MochiResponse} ->
                    Req:respond(MochiResponse)
            end,
            completed;
        return ->
            Req:not_found(),
            completed;
        Unknown ->
            Unknown
    after ?UpstreamTimeoutMS ->
        error(Req, 504, [], "Timed out awaiting response"),
        completed
    end.
    

%% Helpers

make_io(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
make_io(Integer) when is_integer(Integer) ->
    integer_to_list(Integer);
make_io(Io) when is_list(Io); is_binary(Io) ->
    Io.

%% Format a request into a normal HTTP body
format_req(Req, Body) ->
    F = fun ({K, V}, Acc) -> [make_io(K), <<": ">>, V, <<"\r\n">> | Acc] end,
    Headers = lists:foldl(F, [<<"\r\n">>], mochiweb_headers:to_list(Req:get(headers))),
    MethodLine = mochifmt:format("{0} {1} HTTP/{2.0}.{2.1}\r\n",
                                 [Req:get(method), Req:get(raw_path), Req:get(version)]),
    case Body of
        undefined ->
            [MethodLine, Headers];
        _ ->
            [MethodLine, Headers, Body]
    end.
    
check_response(Bytes) ->
    case httpc_response:parse([Bytes, nolimit, true]) of
        {ok, {_HttpVersion, StatusCode, StatusText, Headers, Body}} ->
            {ok, {[integer_to_list(StatusCode), " ", StatusText],
                  http_response:header_list(Headers),
                  Body}};
        Other ->
            {error, Other}
    end.
    
error(Req, StatusCode, Headers, ExplanatoryBodyText) when is_list(Headers) ->
    Req:respond({StatusCode, Headers, integer_to_list(StatusCode) ++ " " ++ ExplanatoryBodyText}).
error(Req, StatusCode, Headers, ExplanatoryBodyText, Reason) ->
    error(Req, StatusCode, Headers, ExplanatoryBodyText ++ ": " ++ Reason).