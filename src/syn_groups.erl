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
-module(syn_groups).
-behaviour(syn_gen_scope).

%% API
-export([start_link/1]).
-export([get_subcluster_nodes/1]).
-export([join/2, join/3, join/4]).
-export([get_members/1, get_members/2]).
-export([count/1, count/2]).

%% syn_gen_scope callbacks
-export([
    init/1,
    handle_call/3,
    handle_info/2,
    save_remote_data/2,
    get_local_data/1,
    purge_local_data_for_node/2
]).

%% includes
-include("syn.hrl").

%% ===================================================================
%% API
%% ===================================================================
-spec start_link(Scope :: atom()) ->
    {ok, Pid :: pid()} | {error, {already_started, Pid :: pid()}} | {error, Reason :: any()}.
start_link(Scope) when is_atom(Scope) ->
    syn_gen_scope:start_link(?MODULE, Scope).

-spec get_subcluster_nodes(Scope :: atom()) -> [node()].
get_subcluster_nodes(Scope) ->
    syn_gen_scope:get_subcluster_nodes(?MODULE, Scope).

-spec get_members(GroupName :: term()) -> [{Pid :: pid(), Meta :: term()}].
get_members(GroupName) ->
    get_members(default, GroupName).

-spec get_members(Scope :: atom(), GroupName :: term()) -> [{Pid :: pid(), Meta :: term()}].
get_members(Scope, GroupName) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            ets:select(TableByName, [{
                {{GroupName, '$2'}, '$3', '_', '_', '_'},
                [],
                [{{'$2', '$3'}}]
            }])
    end.

-spec join(GroupName :: term(), Pid :: pid()) -> ok.
join(GroupName, Pid) ->
    join(GroupName, Pid, undefined).

-spec join(GroupNameOrScope :: term(), PidOrGroupName :: term(), MetaOrPid :: term()) -> ok.
join(GroupName, Pid, Meta) when is_pid(Pid) ->
    join(default, GroupName, Pid, Meta);

join(Scope, GroupName, Pid) when is_pid(Pid) ->
    join(Scope, GroupName, Pid, undefined).

-spec join(Scope :: atom(), GroupName :: term(), Pid :: pid(), Meta :: term()) -> ok.
join(Scope, GroupName, Pid, Meta) ->
    Node = node(Pid),
    case syn_gen_scope:call(?MODULE, Node, Scope, {join_on_owner, node(), GroupName, Pid, Meta}) of
        {ok, {Time, TableByName, TableByPid}} when Node =/= node() ->
            %% update table on caller node immediately so that subsequent calls have an updated registry
            add_to_local_table(GroupName, Pid, Meta, Time, undefined, TableByName, TableByPid),
            %% callback
            %%syn_event_handler:do_on_process_joined(Scope, GroupName, {TablePid, TableMeta}, {Pid, Meta}),
            %% return
            ok;

        {Response, _} ->
            Response
    end.

-spec count(Scope :: atom()) -> non_neg_integer().
count(Scope) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            Entries = ets:select(TableByName, [{
                {{'$1', '_'}, '_', '_', '_', '_'},
                [],
                ['$1']
            }]),
            Set = sets:from_list(Entries),
            sets:size(Set)
    end.

-spec count(Scope :: atom(), Node :: node()) -> non_neg_integer().
count(Scope, Node) ->
    case syn_backbone:get_table_name(syn_groups_by_name, Scope) of
        undefined ->
            error({invalid_scope, Scope});

        TableByName ->
            Entries = ets:select(TableByName, [{
                {{'$1', '_'}, '_', '_', '_', Node},
                [],
                ['$1']
            }]),
            Set = sets:from_list(Entries),
            sets:size(Set)
    end.

%% ===================================================================
%% Callbacks
%% ===================================================================

%% ----------------------------------------------------------------------------------------------------------
%% Init
%% ----------------------------------------------------------------------------------------------------------
-spec init(#state{}) -> {ok, HandlerState :: term()}.
init(_State) ->
    HandlerState = #{},
    %% init
    {ok, HandlerState}.

%% ----------------------------------------------------------------------------------------------------------
%% Call messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()}, #state{}) ->
    {reply, Reply :: term(), #state{}} |
    {reply, Reply :: term(), #state{}, timeout() | hibernate | {continue, term()}} |
    {noreply, #state{}} |
    {noreply, #state{}, timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), Reply :: term(), #state{}} |
    {stop, Reason :: term(), #state{}}.
handle_call({join_on_owner, RequesterNode, GroupName, Pid, Meta}, _From, #state{
    scope = Scope,
    table_by_name = TableByName,
    table_by_pid = TableByPid
} = State) ->
    case is_process_alive(Pid) of
        true ->
            %% available
            MRef = case find_monitor_for_pid(Pid, TableByPid) of
                undefined -> erlang:monitor(process, Pid);  %% process is not monitored yet, add
                MRef0 -> MRef0
            end,
            %% add to local table
            Time = erlang:system_time(),
            add_to_local_table(GroupName, Pid, Meta, Time, MRef, TableByName, TableByPid),
            %% callback
            %%syn_event_handler:do_on_process_joined(Scope, GroupName, {undefined, undefined}, {Pid, Meta}),
            %% broadcast
            syn_gen_scope:broadcast({'3.0', sync_join, GroupName, Pid, Meta, Time}, [RequesterNode], State),
            %% return
            {reply, {ok, {Time, TableByName, TableByPid}}, State};

        false ->
            {reply, {{error, not_alive}, undefined}, State}
    end;

handle_call(Request, From, State) ->
    error_logger:warning_msg("SYN[~s] Received from ~p an unknown call message: ~p", [node(), From, Request]),
    {reply, undefined, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Info messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_info(Info :: timeout | term(), #state{}) ->
    {noreply, #state{}} |
    {noreply, #state{}, timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), #state{}}.
handle_info({'3.0', sync_join, GroupName, Pid, Meta, Time}, #state{
    table_by_name = TableByName,
    table_by_pid = TableByPid
} = State) ->
    case find_groups_entry_by_name_and_pid(GroupName, Pid, TableByName) of
        undefined ->
            %% new
            add_to_local_table(GroupName, Pid, Meta, Time, undefined, TableByName, TableByPid),
            %% callback
            %%syn_event_handler:do_on_process_joined(Scope, GroupName, {undefined, undefined}, {Pid, Meta});
            {noreply, State};

        {GroupName, Pid, _TableMeta, TableTime, _MRef, _TableNode} when Time > TableTime ->
            %% update meta
            add_to_local_table(GroupName, Pid, Meta, Time, undefined, TableByName, TableByPid),
            %% callback
            %%syn_event_handler:do_on_process_joined(Scope, GroupName, {undefined, undefined}, {Pid, Meta});
            {noreply, State};

        {GroupName, Pid, _TableMeta, _TableTime, _TableMRef, _TableNode} ->
            %% race condition: incoming data is older, ignore
            {noreply, State}
    end;

handle_info(Info, State) ->
    error_logger:warning_msg("SYN[~s] Received an unknown info message: ~p", [node(), Info]),
    {noreply, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Data
%% ----------------------------------------------------------------------------------------------------------
-spec get_local_data(State :: term()) -> {ok, Data :: any()} | undefined.
get_local_data(#state{table_by_name = TableByName}) ->
    {ok, []}.

-spec save_remote_data(RemoteData :: any(), State :: term()) -> any().
save_remote_data(RegistryTuplesOfRemoteNode, #state{scope = Scope} = State) ->
    %% insert tuples
    ok.

-spec purge_local_data_for_node(Node :: node(), State :: term()) -> any().
purge_local_data_for_node(Node, #state{
    scope = Scope,
    table_by_name = TableByName,
    table_by_pid = TableByPid
}) ->
    ok.

%% ===================================================================
%% Internal
%% ===================================================================
-spec find_monitor_for_pid(Pid :: pid(), TableByPid :: atom()) -> reference() | undefined.
find_monitor_for_pid(Pid, TableByPid) when is_pid(Pid) ->
    %% we use select instead of lookup to limit the results and thus cover the case
    %% when a process is registered with a considerable amount of names
    case ets:select(TableByPid, [{
        {{Pid, '_'}, '_', '_', '$5', '_'},
        [],
        ['$5']
    }], 1) of
        {[MRef], _} -> MRef;
        '$end_of_table' -> undefined
    end.

-spec find_groups_entry_by_name_and_pid(GroupName :: any(), Pid :: pid(), TableByName :: atom()) ->
    Entry :: syn_groups_entry() | undefined.
find_groups_entry_by_name_and_pid(GroupName, Pid, TableByName) ->
    case ets:lookup(TableByName, {GroupName, Pid}) of
        [] -> undefined;
        [Entry] -> Entry
    end.

-spec add_to_local_table(
    GroupName :: term(),
    Pid :: pid(),
    Meta :: term(),
    Time :: integer(),
    MRef :: undefined | reference(),
    TableByName :: atom(),
    TableByPid :: atom()
) -> true.
add_to_local_table(GroupName, Pid, Meta, Time, MRef, TableByName, TableByPid) ->
    %% insert
    ets:insert(TableByName, {{GroupName, Pid}, Meta, Time, MRef, node(Pid)}),
    ets:insert(TableByPid, {{Pid, GroupName}, Meta, Time, MRef, node(Pid)}).
