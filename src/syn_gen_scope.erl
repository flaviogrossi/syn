%% ==========================================================================================================
%% Syn - A global Process Registry and Process Group manager.
%%
%% The MIT License (MIT)
%%
%% Copyright (c) 2015-2021 Roberto Ostinelli <roberto@ostinelli.net> and Neato Robotics, Inc.
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THxE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% ==========================================================================================================
-module(syn_gen_scope).
-behaviour(gen_server).

%% API
-export([
    start_link/3,
    get_subcluster_nodes/2,
    call/3, call/4
]).
-export([
    broadcast/2, broadcast/3,
    broadcast_all_cluster/2,
    send_to_node/3
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3
]).

%% callbacks
-callback init(Args :: term()) ->
    {ok, State :: term()}.
-callback handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: term()) ->
    {reply, Reply :: term(), NewState :: term()} |
    {reply, Reply :: term(), NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}.
-callback handle_info(Info :: timeout | term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: term()}.
-callback save_remote_data(RemoteData :: any(), State :: term()) -> any().
-callback get_local_data(State :: term()) -> {ok, Data :: any()} | undefined.
-callback purge_local_data_for_node(Node :: node(), State :: term()) -> any().

%% includes
-include("syn.hrl").

%% ===================================================================
%% API
%% ===================================================================
-spec start_link(Handler :: module(), Scope :: atom(), Args :: [any()]) ->
    {ok, Pid :: pid()} | {error, {already_started, Pid :: pid()}} | {error, Reason :: any()}.
start_link(Handler, Scope, Args) when is_atom(Scope) ->
    ProcessName = get_process_name_for_scope(Handler, Scope),
    gen_server:start_link({local, ProcessName}, ?MODULE, [Handler, Scope, ProcessName, Args], []).

-spec get_subcluster_nodes(Handler :: module(), Scope :: atom()) -> [node()].
get_subcluster_nodes(Handler, Scope) ->
    ProcessName = get_process_name_for_scope(Handler, Scope),
    gen_server:call(ProcessName, get_subcluster_nodes).

-spec call(Handler :: module(), Scope :: atom(), Message :: any()) -> Response :: any().
call(Handler, Scope, Message) ->
    call(Handler, node(), Scope, Message).

-spec call(Handler :: module(), Node :: atom(), Scope :: atom(), Message :: any()) -> Response :: any().
call(Handler, Node, Scope, Message) ->
    ProcessName = get_process_name_for_scope(Handler, Scope),
    gen_server:call({ProcessName, Node}, Message).

%% ===================================================================
%% In-Process API
%% ===================================================================
-spec broadcast(Message :: any(), #state{}) -> any().
broadcast(Message, State) ->
    broadcast(Message, [], State).

-spec broadcast(Message :: any(), ExcludedNodes :: [node()], #state{}) -> any().
broadcast(Message, ExcludedNodes, #state{process_name = ProcessName, nodes = Nodes}) ->
    lists:foreach(fun(RemoteNode) ->
        erlang:send({ProcessName, RemoteNode}, Message, [noconnect])
    end, maps:keys(Nodes) -- ExcludedNodes).

-spec broadcast_all_cluster(Message :: any(), #state{}) -> any().
broadcast_all_cluster(Message, #state{process_name = ProcessName}) ->
    lists:foreach(fun(RemoteNode) ->
        erlang:send({ProcessName, RemoteNode}, Message, [noconnect])
    end, nodes()).

-spec send_to_node(RemoteNode :: node(), Message :: any(), #state{}) -> any().
send_to_node(RemoteNode, Message, #state{process_name = ProcessName}) ->
    erlang:send({ProcessName, RemoteNode}, Message, [noconnect]).

%% ===================================================================
%% Callbacks
%% ===================================================================

%% ----------------------------------------------------------------------------------------------------------
%% Init
%% ----------------------------------------------------------------------------------------------------------
-spec init([term()]) ->
    {ok, #state{}} |
    {ok, #state{}, Timeout :: non_neg_integer()} |
    ignore |
    {stop, Reason :: any()} |
    {continue, any()}.
init([Handler, Scope, ProcessName, Args]) ->
    %% call init
    {ok, HandlerState} = Handler:init(Args),
    %% monitor nodes
    ok = net_kernel:monitor_nodes(true),
    %% build state
    State = #state{
        handler = Handler,
        handler_state = HandlerState,
        scope = Scope,
        process_name = ProcessName
    },
    {ok, State, {continue, after_init}}.

%% ----------------------------------------------------------------------------------------------------------
%% Call messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: term()) ->
    {reply, Reply :: term(), NewState :: term()} |
    {reply, Reply :: term(), NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}.
handle_call(get_subcluster_nodes, _From, #state{
    nodes = Nodes
} = State) ->
    {reply, Nodes, State};

handle_call(Request, From, #state{handler = Handler} = State) ->
    Handler:handle_call(Request, From, State).

%% ----------------------------------------------------------------------------------------------------------
%% Cast messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: term()}.
handle_cast(Msg, #state{handler = Handler} = State) ->
    Handler:handle_cast(Msg, State).

%% ----------------------------------------------------------------------------------------------------------
%% Info messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_info(Info :: timeout | term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: term()}.
handle_info({'3.0', discover, RemoteScopePid}, #state{
    handler = Handler,
    scope = Scope,
    nodes = Nodes
} = State) ->
    RemoteScopeNode = node(RemoteScopePid),
    error_logger:info_msg("SYN[~s] Received DISCOVER request from node '~s' and scope '~s'",
        [node(), RemoteScopeNode, Scope]
    ),
    %% send local data to remote
    {ok, LocalData} = Handler:get_local_data(State),
    send_to_node(RemoteScopeNode, {'3.0', ack_sync, self(), LocalData}, State),
    %% is this a new node?
    case maps:is_key(RemoteScopeNode, Nodes) of
        true ->
            %% already known, ignore
            {noreply, State};

        false ->
            %% monitor
            _MRef = monitor(process, RemoteScopePid),
            {noreply, State#state{nodes = Nodes#{RemoteScopeNode => RemoteScopePid}}}
    end;

handle_info({'3.0', ack_sync, RemoteScopePid, Data}, #state{
    handler = Handler,
    nodes = Nodes,
    scope = Scope
} = State) ->
    RemoteScopeNode = node(RemoteScopePid),
    error_logger:info_msg("SYN[~s] Received ACK SYNC from node '~s' and scope '~s'",
        [node(), RemoteScopeNode, Scope]
    ),
    %% save remote data
    Handler:save_remote_data(Data, State),
    %% is this a new node?
    case maps:is_key(RemoteScopeNode, Nodes) of
        true ->
            %% already known
            {noreply, State};

        false ->
            %% monitor
            _MRef = monitor(process, RemoteScopePid),
            %% send local to remote
            {ok, LocalData} = Handler:get_local_data(State),
            send_to_node(RemoteScopeNode, {'3.0', ack_sync, self(), LocalData}, State),
            %% return
            {noreply, State#state{nodes = Nodes#{RemoteScopeNode => RemoteScopePid}}}
    end;

handle_info({'DOWN', MRef, process, Pid, Reason}, #state{
    handler = Handler,
    scope = Scope,
    nodes = Nodes
} = State) when node(Pid) =/= node() ->
    %% scope process down
    RemoteNode = node(Pid),
    case maps:take(RemoteNode, Nodes) of
        {Pid, Nodes1} ->
            error_logger:info_msg("SYN[~s] Scope Process '~s' is DOWN on node '~s': ~p",
                [node(), Scope, RemoteNode, Reason]
            ),
            Handler:purge_local_data_for_node(RemoteNode, State),
            {noreply, State#state{nodes = Nodes1}};

        error ->
            %% relay to handler
            Handler:handle_info({'DOWN', MRef, process, Pid, Reason}, State)
    end;

handle_info({nodedown, _Node}, State) ->
    %% ignore & wait for monitor DOWN message
    {noreply, State};

handle_info({nodeup, RemoteNode}, #state{scope = Scope} = State) ->
    error_logger:info_msg("SYN[~s] Node '~s' has joined the cluster, sending discover message for scope '~s'",
        [node(), RemoteNode, Scope]
    ),
    send_to_node(RemoteNode, {'3.0', discover, self()}, State),
    {noreply, State};

handle_info(Info, #state{handler = Handler} = State) ->
    Handler:handle_info(Info, State).

%% ----------------------------------------------------------------------------------------------------------
%% Continue messages
%% ----------------------------------------------------------------------------------------------------------
handle_continue(after_init, #state{scope = Scope} = State) ->
    error_logger:info_msg("SYN[~s] Discovering the cluster with scope '~s'", [node(), Scope]),
    broadcast_all_cluster({'3.0', discover, self()}, State),
    {noreply, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Terminate
%% ----------------------------------------------------------------------------------------------------------
-spec terminate(Reason :: any(), #state{}) -> terminated.
terminate(Reason, _State) ->
    error_logger:info_msg("SYN[~s] Terminating with reason: ~p", [node(), Reason]),
    terminated.

%% ----------------------------------------------------------------------------------------------------------
%% Convert process state when code is changed.
%% ----------------------------------------------------------------------------------------------------------
-spec code_change(OldVsn :: any(), #state{}, Extra :: any()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal
%% ===================================================================
-spec get_process_name_for_scope(Handler :: module(), Scope :: atom()) -> atom().
get_process_name_for_scope(Handler, Scope) ->
    ModuleBin = atom_to_binary(Handler),
    ScopeBin = atom_to_binary(Scope),
    binary_to_atom(<<ModuleBin/binary, "_", ScopeBin/binary>>).