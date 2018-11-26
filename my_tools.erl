-module(my_tools).
-export([source/1
        ,generate_code/0
        ,generate_code/1
        ,generate_beam/0
        ,generate_beam/1
        ,back_old_beam/1
        ,sync_beam/1
        ,sync_beam/2
        ,etop_cpu/0
        ,etop_mem/0
        ,etop_stop/0
        ,running_info/0
        ,gc/0
        ,gc/1
        ,timestamp/0
        ,timestamp/1
        ,timestamp_to_time/1
        ,trace_messages/1
        ,trace_messages/3
        ,trace_pid/1
        ,trace_pid_file/2
        ,trace_pids/1
        ,get_state/1
        ,remote_load/1
        ,remote_load/2
        ,port_info/1
        ,rpc_call/1
        ,rpc_call/2
        ,rpc_call/3
        ,string_to_term/1
        ,eval_str/1
        ,eval_str/2
        ,node_list/1
        ,watch/2
        ,stop_watch/0
        ,watch_tee/2
        ,watch_tee/3
        ,stop_watch_tee/0
        ,unload/0
        ,count/1
        ,count/2
        ,partition_suffix/1
        ,check_code/0
        ,check_code/1
        ,encode_base64n/1
        ,encode_base64n/2
        ,scheduler_wall_time/0
        ,scheduler_wall_time/1
        ,proc_path/1
        ,safe_do/2
        ]).

-export([sync_beam_internal/3
        ,map_pal/2
        ,foreach_pal/2
        ,code_diff/2]).

-include_lib("kernel/include/file.hrl").
-define(INFO_MSG(Format, Args), begin io:format("~s:~p: "++Format++"~n",[?MODULE, ?LINE]++Args),
                                      error_logger:info_msg("~s:~p: "++Format++"~n",[?MODULE, ?LINE]++Args)end).

%%decompile module
source(Module) ->
    Path = code:which(Module),
    try
        case beam_lib:chunks(Path, [abstract_code]) of
            {ok, {_, [{abstract_code, {_, AC}}]}} ->
                io:format("~ts~n",[erl_prettypr:format(erl_syntax:form_list(AC))]);
            _ ->
                Attrs = Module:module_info(compile),
                Binary = proplists:get_value(object_code, Attrs),
                case Binary of
                    undefined ->
                        io:format("fail to source module ~n");
                    _ ->
                        %% maybe return {ok,{test,[{abstract_code,no_abstract_code}]}}
                        {ok,{_,[{abstract_code,{_,AC}}]}} =
                            beam_lib:chunks(Binary,[abstract_code]),
                        io:format("~ts~n",
                                  [erl_prettypr:format(erl_syntax:form_list(AC))])
                end
        end
    catch _:_ ->
            io:format("fail to source module ~n")
    end.

%%generate code
generate_code() ->
    generate_code(?MODULE).

generate_code(Module) ->
    {Module, Binary, FileName} = code:get_object_code(Module),
    NewBinary = fill_chunks_compile_info(Binary, [{object_code, Binary}]),
    Data = io_lib:format("{module,~p} = code:load_binary(~p,\"load_from_object_code:~s\",
                         zlib:uncompress(base64:decode(\"~s\"))).~n",
                         [Module, Module, FileName, base64:encode(zlib:compress(NewBinary))]),
    file:write_file(lists:concat(["./",Module,".code"]), Data).

fill_chunks_compile_info(Binary, Attrs) ->
    {ok, _Module, Chunks} = beam_lib:all_chunks(Binary),
    OldAttrs = binary_to_term(proplists:get_value("CInf",Chunks)),
    NewChunks = lists:keyreplace("CInf", 1, Chunks, {"CInf", term_to_binary(OldAttrs++Attrs)}),
    {ok, NewBinary} = beam_lib:build_module(NewChunks),
    NewBinary.

%%generate beam 
generate_beam() ->
    generate_beam(?MODULE).
generate_beam(Module) ->
    {_, _, Path} = code:get_object_code(Module),
    {ok, FileBin} = file:read_file(Path),
    Base64Bin = base64:encode(FileBin),
    [NewBeamVsn] = element(2, lists:nth(1, Module:module_info(attributes))),
    Data = io_lib:format("{_, _, OldBeamPath} = code:get_object_code(~p),
                         OldBeamBak = OldBeamPath ++ \"-\" ++ integer_to_list(~p),
                         os:cmd(\"mv \"++ OldBeamPath ++ \" \" ++ OldBeamBak),
                         file:write_file(OldBeamPath, 
                         base64:decode(\"~s\")),
                         l(~p).~n",
                         [Module, NewBeamVsn, Base64Bin, Module]),
    file:write_file(lists:concat(["./", Module, ".data"]), Data).

%%back to old beam
back_old_beam(Module) ->
    [CurVsn] = element(2, lists:nth(1, Module:module_info(attributes))),
    {_, _, CurBeamPath} = code:get_object_code(Module),
    OldBeamPath = CurBeamPath ++ "-" ++ integer_to_list(CurVsn),
    case filelib:is_regular(OldBeamPath) of
        true ->
            os:cmd("mv " ++ OldBeamPath ++ " " ++ CurBeamPath),
            c:l(Module);
        false ->
            io:format("no old beam file~n", [])
    end,
    ok.

%%sync beam
sync_beam(Module) ->
    sync_beam(Module, nodes()).
sync_beam(Module, NodeLists) ->
    {_, _, Path} = code:get_object_code(Module),
    {ok, FileBin} = file:read_file(Path),
    [NewBeamVsn] = element(2, lists:nth(1, Module:module_info(attributes))),
    map_pal(
        fun(Node) ->
            rpc:call(Node, ?MODULE, sync_beam_internal, [Module, NewBeamVsn, FileBin])
        end, NodeLists, 1000).

sync_beam_internal(Module, NewBeamVsn, FileBin) ->
    case element(2, lists:nth(1, Module:module_info(attributes))) of
        [NewBeamVsn] ->
            io:format("same module vsn~n", []);
        _ ->
            {_, _, OldBeamPath} = code:get_object_code(Module),
            OldBeamBak = OldBeamPath ++ "-" ++ integer_to_list(NewBeamVsn),
            os:cmd("mv "++ OldBeamPath ++ " " ++ OldBeamBak),
            file:write_file(OldBeamPath, FileBin),
            c:l(Module)
    end.

%%top cpu <10w+
etop_cpu() ->
    spawn(fun() ->
        etop:start([{output, text}, {interval, 3}, {lines, 20}, {sort, reductions}]) end).
%%top_cpu <10w+
etop_mem() ->  
    spawn(fun() ->
        etop:start([{output, text}, {interval, 3}, {lines, 20}, {sort, memory}]) end).
%%stop_monitor <10w+
etop_stop() ->
    etop:stop().

%%current running info
running_info() ->
    SchedId      = erlang:system_info(scheduler_id), 
    SchedNum     = erlang:system_info(schedulers), 
    ProcCount    = erlang:system_info(process_count), 
    ProcLimit    = erlang:system_info(process_limit), 
    ProcMemUsed  = erlang:memory(processes_used), 
    ProcMemAlloc = erlang:memory(processes), 
    MemTot       = erlang:memory(total), 
    io:format("abormal termination: " 
          "~n   Scheduler id:                         ~p" 
          "~n   Num scheduler:                        ~p" 
          "~n   Process count:                        ~p" 
          "~n   Process limit:                        ~p" 
          "~n   Memory used by erlang processes:      ~p" 
          "~n   Memory allocated by erlang processes: ~p" 
          "~n   The total amount of memory allocated: ~p" 
          "~n ",  
          [SchedId, SchedNum, ProcCount, ProcLimit,  
           ProcMemUsed, ProcMemAlloc, MemTot ]),   
    ok.
   
%%garbage process
gc() ->
    [erlang:garbage_collect(Pid) || Pid <- processes()].

gc(Pid) ->
    erlang:garbage_colletc(Pid).

%%timestamp
timestamp() ->
    erlang:system_time().

%%seconds/milli_seconds/micro_seconds
timestamp(Unit) ->
    erlang:system_time(Unit).

timestamp_to_time(Timestamp) ->
    TimeStamp = case length(integer_to_list(Timestamp)) of
                    10 ->
                        Timestamp;
                    13 ->
                        Timestamp div 1000;
                    16 ->
                        Timestamp div 1000000
                end,
    Time = calendar:gregorian_seconds_to_datetime(TimeStamp + 
               calendar:datetime_to_gregorian_seconds({{1970,1,1}, {0,0,0}})),
    calendar:universal_time_to_local_time(Time).

%%trace pid message
trace_messages(Pid) ->
    trace_messages(Pid, 5, 1000).

trace_messages(Pid, N, Timeout) when not is_pid(Pid) ->
    trace_messages(ensure_pid(Pid), N, Timeout);
trace_messages(Pid, N, Timeout) when is_pid(Pid), node(Pid) == node() ->
    case is_process_alive(Pid) of
        true ->
            Flags = [send, 'receive', call, return_to],
            erlang:trace(Pid, true, Flags),
            Messages = flush_messages(N, Timeout),
            catch erlang:trace(Pid, false, Flags),
            Messages;
        false ->
            process_not_alive
    end;
trace_messages(Pid, N, Timeout) when is_pid(Pid) ->
    rpc_call(node(Pid),
             fun() ->
                ?MODULE:trace_messages(Pid, N, Timeout)
             end).

flush_messages(N, Timeout) ->
    flush_messages(N, Timeout, []).
flush_messages(N, Timeout, Acc) when N > 0 ->
    receive
        Msg ->
            flush_messages(N-1, Timeout, [Msg|Acc])
    after Timeout ->
            lists:reverse(Acc)
    end;
flush_messages(_, _, Acc) ->
    lists:reverse(Acc).

%%trace pid
trace_pid(Pid) ->
    trace_pids([ensure_pid(Pid)]).

%%trace pid and write to file
trace_pid_file(Pid, FileName) ->
    trace_pids([ensure_pid(Pid)], [{file, ensure_list(FileName)}]).

trace_pids(Pids) ->
    trace_pids(Pids, []).
trace_pids(Pids, Opts) ->
    OptsNew = maybe_file_pid(Opts),
    Master =
        proc_lib:spawn_link(
          fun() ->
                  trace_user_loop(queue:new(),OptsNew)
          end),
    [proc_lib:spawn_link(node(Pid),
      fun() ->
              erlang:trace(Pid, true, [send, 'receive', call,
                                      return_to, procs, set_on_spawn]),
              trace_user_redirect(Master)
      end)||Pid<-Pids].

trace_user_redirect(Master) ->
    receive
        Msg ->
            Now = erlang:system_time(milli_seconds),
            case trace_redirect_filter(Msg, Now) of
                true ->
                    Master ! {self(), Now, Msg};
                false ->
                    skip
            end
    end,
    trace_user_redirect(Master).

trace_user_loop(Q, Opts) ->
    Timeout =
        case queue:is_empty(Q) of
            true ->
                infinity;
            false ->
                0
        end,
    receive
        {From, Time, Msg} = E->
            Q1 = queue:in(E, Q),
            ?MODULE:trace_user_loop(Q1, Opts)
    after Timeout ->
            {{value, {From, Time, Msg}}, Q1} = queue:out(Q),
            Msg1 = trace_format_msg(Msg),
            trace_show_msg(From, Time, Msg1, Opts),
            ?MODULE:trace_user_loop(Q1, Opts)
    end.

maybe_file_pid(Opts) ->
    case proplists:get_value(file, Opts) of
        FileName when is_list(FileName) ->
            Pid = proc_lib:spawn_link(
                    fun() ->
                            trace_dump_file(FileName)
                    end),
            [{dump_pid, Pid}|Opts];
        _ ->
            Opts
    end.

%%just print 1/s
trace_redirect_filter({trace, _Pid1, _Action, {system,{_Pid2, Ref}, SysAction}, _Pid3}, Now)
  when SysAction == suspend; SysAction == resume ->
    case get(last_action) of
        {_, Time} when Now - Time < 1000 ->
            put(last_ref, Ref),
            false;
        _ ->
            put(last_action, {Ref, Now}),
            true
    end;
%%just print 1/s
trace_redirect_filter({trace, _Pid1, _Action, {system,{_Pid2, Ref},
                      {change_code,_Module,_VSN,_Extra}}, _Pid3}, Now) ->
    case get(last_action) of
        {_, Time} when Now - Time < 1000 ->
            put(last_ref, Ref),
            false;
        _ ->
            put(last_action, {Ref, Now}),
            true
    end;
trace_redirect_filter({trace, _Pid, 'receive', {Ref, ok}}, _Now) ->
    case get(last_ref) of
        Ref ->
            false;
        _ ->
            true
    end;
%%just print 1/s
trace_redirect_filter({trace, _Pid1, 'receive', 
                      {check_process_code, {Ref1, _Pid2, _Bool1}, _Bool2}}, Now) ->
    case get(last_check_process_code) of
        {_, Time} when Now - Time < 1000 ->
            false;
        _ ->
            put(last_check_process_code, {Ref1, Now}),
            true
    end;
trace_redirect_filter(_Msg, _Now) ->
    true.

trace_format_msg(Msg) ->
    try
        io_lib:print(Msg, 1,80,100)
    catch
        C:E ->
            io:format("Msg:~p~nC:~p,E:~p:S:~p~n",[Msg, C,E,erlang:get_stacktrace()])
    end.

trace_show_msg(From, Time, Msg, Opts) ->
    Str = io_lib:format("~s: from:~p ========~n~s~n",[to_datetimemsstr(Time),
                        From,Msg]),
    case proplists:get_value(dump_pid,Opts) of
        Pid when is_pid(Pid) ->
            Pid ! {dump, Str};
        _ ->
            io:format("~s",[Str])
    end.

trace_dump_file(FileName) ->
    {ok, Fd} = file:open(FileName, [write, append]),
    trace_dump_file1(Fd).
trace_dump_file1(Fd) ->
    receive
        {dump, Str} ->
            ok = file:write(Fd, Str)
    end,
    trace_dump_file1(Fd).

%% get state of pid
get_state(Pid) -> get_state(ensure_pid(Pid), 5000).
get_state(Pid, Timeout) ->
    try
        sys:get_state(Pid, Timeout)
    catch
        error:undef ->
            case sys:get_status(Pid, Timeout) of
                {status,_Pid,{module,gen_server},Data} ->
                    {data, Props} = lists:last(lists:nth(5, Data)),
                    proplists:get_value("State", Props);
                {status,_Pod,{module,gen_fsm},Data} ->
                    {data, Props} = lists:last(lists:nth(5, Data)),
                    proplists:get_value("StateData", Props)
            end
    end.

%% sync local mod to remote nodes
remote_load(Mod) -> remote_load(nodes(), Mod).
remote_load(Nodes=[_|_], Mod) when is_atom(Mod) ->
    {Mod, Bin, _File} = code:get_object_code(Mod),
    rpc:multicall(Nodes, code, load_binary, 
                 [Mod, lists:concat(["load_from_remote_load:",Mod,node()]), Bin]);
remote_load(Nodes=[_|_], Modules) when is_list(Modules) ->
    [remote_load(Nodes, Mod) || Mod <- Modules];
remote_load(Node, Mod) ->
    remote_load([Node], Mod).

%%info of port
port_info(Port) ->
    [port_info(ensure_port(Port), Type) || 
    Type <- [meta, signals, io, memory_used, specific]].

port_info(Port, meta) ->
    {meta, List} = port_info_type(ensure_port(Port), meta, [id, name, os_pid]),
    case port_info(ensure_port(Port), registered_name) of
        [] -> {meta, List};
        Name -> {meta, [Name | List]}
    end;
port_info(Port, signals) ->
    port_info_type(ensure_port(Port), signals, [connected, links, monitors]);
port_info(Port, io) ->
    port_info_type(ensure_port(Port), io, [input, output]);
port_info(Port, memory_used) ->
    port_info_type(ensure_port(Port), memory_used, [memory, queue_size]);
port_info(Port, specific) ->
    Props = case erlang:port_info(ensure_port(Port), name) of
                {_,Type} when Type =:= "udp_inet";
                              Type =:= "tcp_inet";
                              Type =:= "sctp_inet" ->
                    case inet:getstat(ensure_port(Port)) of
                        {ok, Stats} -> [{statistics, Stats}];
                        _ -> []
                    end ++
                    case inet:peername(ensure_port(Port)) of
                        {ok, Peer} -> [{peername, Peer}];
                        {error, _} ->  []
                    end ++
                    case inet:sockname(ensure_port(Port)) of
                        {ok, Local} -> [{sockname, Local}];
                        {error, _} -> []
                    end ++
                    case inet:getopts(ensure_port(Port),
                                     [active, broadcast, buffer, delay_send,
                                      dontroute, exit_on_close, header,
                                      high_watermark, ipv6_v6only, keepalive,
                                      linger, low_watermark, mode, nodelay,
                                      packet, packet_size, priority,
                                      read_packets, recbuf, reuseaddr,
                                      send_timeout, sndbuf]) of
                        {ok, Opts} -> [{options, Opts}];
                        {error, _} -> []
                    end;
                {_,"efile"} ->
                    [];
                _ ->
                    []
            end,
    {type, Props};
port_info(Port, Keys) when is_list(Keys) ->
    [erlang:port_info(ensure_port(Port),Key) || Key <- Keys];
port_info(Port, Key) when is_atom(Key) ->
    erlang:port_info(ensure_port(Port), Key).


port_info_type(Port, Type, Keys) ->
    {Type, [erlang:port_info(Port,Key) || Key <- Keys]}.

%%nodes rpc
rpc_call(Fun) ->
    rpc_call([node()|nodes()], Fun).
rpc_call(Nodes, Fun) ->
    rpc_call(Nodes, Fun, infinity).
rpc_call(Nodes, Fun, Timeout) when is_function(Fun,0), is_list(Nodes) ->
    rpc:multicall(Nodes, erlang, apply, [fun() -> {node(),Fun()} end,[]], Timeout);
rpc_call(Node, Fun, Timeout) when is_atom(Node) ->
    rpc_call([Node], Fun, Timeout).

%%strint to erlang term
string_to_term(String) ->
    case erl_scan:string(String++".") of
        {ok, Tokens, _} ->
            case erl_parse:parse_term(Tokens) of
                {ok, Term} -> Term;
                _Err -> undefined
            end;
        _Error ->
            undefined
    end.

%%exec string
%%ex:
%%eval_str("erlang:node()").
eval_str(Str) ->
    eval_str(Str, []).
eval_str({exprs,Exprs}, Bindings) ->
    {value,Value,_} = erl_eval:exprs(Exprs, Bindings),
    Value;
eval_str(Str, Bindings) ->
    Exprs = make_exprs(Str),
    {value,Value,_} = erl_eval:exprs(Exprs, Bindings),
    Value.

make_exprs(Str) ->
    {ok, Tokens, _} = erl_scan:string(binary_to_list(iolist_to_binary(Str))++"."),
    {ok, Exprs} = erl_parse:parse_exprs(Tokens),
    Exprs.

%%uninstall my_tools
unload() ->
    Exprs = io_lib:format("code:purge(~p),code:delete(~p)",
                           [?MODULE, ?MODULE]),
    [{N,rpc:call(N,?MODULE,eval_str,[Exprs,[]])}||N<-nodes()++[node()]].

%%exec lists:map mulit threads
map_pal(Function, List) ->
    map_pal(Function, List, 1000).
map_pal(Function, List, Pal) ->
    map_pal(Function, List, Pal, 1, dict:new(), []).

map_pal(Function, [I|L], Pal, Idx, Dict, Values) when Pal > 0 ->
    {_,Ref} = spawn_monitor(
                 fun() ->
                         exit({map_pal_res, Function(I)})
                 end),
    Dict1 = dict:store(Ref, Idx, Dict),
    map_pal(Function, L, Pal-1, Idx+1, Dict1, Values);
map_pal(Function, List, Pal, Idx, Dict, Values) ->
    case dict:is_empty(Dict) of
        true ->
            [Value||{_,Value}<-lists:sort(Values)];
        false ->
            receive
                {'DOWN', Ref, process, _Pid, {map_pal_res, Res}} ->
                    case dict:find(Ref, Dict) of
                        error ->
                            map_pal(Function, List, Pal, Idx, Dict, Values);
                        {ok, TIdx} ->
                            Dict1 = dict:erase(Ref, Dict),
                            map_pal(Function, List, Pal+1, Idx, Dict1,
                                   [{TIdx,Res}|Values])
                    end;
                {'DOWN', _Ref, process, _Pid, Error} ->
                    erlang:error(Error)
            end
    end.

foreach_pal(Function, List) ->
    foreach_pal(Function, List, 1000).
foreach_pal(Function, List, Pal) ->
    foreach_pal(Function, List, Pal, 0).

foreach_pal(Function, [I|L], Pal, Wait) when Pal > 0 ->
    {_,_Ref} = spawn_monitor(
                 fun() ->
                         exit({pal_res, Function(I)})
                 end),
    foreach_pal(Function, L, Pal-1, Wait+1);
foreach_pal(Function, List, Pal, Wait)  when Wait > 0 ->
    receive
        {'DOWN', _Ref, process, _Pid, {pal_res, _Res}} ->
            foreach_pal(Function, List, Pal+1, Wait-1);
        {'DOWN', _Ref, process, _Pid, Error} ->
            erlang:error(Error)
    end;
foreach_pal(_Function, _L, _Pal, _Wait) ->
    ok.

%%re nodes
node_list(NodeFilter) ->
    [N || N <- [node()|nodes()],
    re:run(atom_to_binary(N,utf8),
    to_binary(NodeFilter))/= nomatch].

%%exec functions with interval time
watch(F, Sleep) ->
    Pid = spawn(fun() -> watch_internal(F,Sleep) end),
    put(watch_pid, Pid),
    Pid.

watch_internal(F, Sleep) ->
    io:format("~n==============~s====================~n~p~n",
              [to_datetimestr(erlang:localtime()),catch F()]),
    timer:sleep(Sleep),
    watch_internal(F, Sleep).

stop_watch() ->
    case get(watch_pid) of
        undefined ->
            skip;
        Pid ->
            exit(Pid, kill),
            erase(watch_pid)
    end.

%%exec functions with interval time and write log to file
watch_tee(F, Sleep) ->
    watch_tee(F, Sleep, watch_tee).
watch_tee(F, Sleep, Tag) when is_atom(Tag) ->
    FileName = lists:concat([Tag, ".watch"]),
    watch_tee(F, Sleep, FileName);
watch_tee(F, Sleep, FileName) ->
    Pid = spawn(fun() -> watch_tee_internal(F,Sleep,FileName) end),
    put(tee_pid, Pid),
    Pid.

watch_tee_internal(F, Sleep, FileName) ->
    Value = (catch F()),
    Now = erlang:localtime(),
    NowTime = to_datetimestr(Now),
    Msg = io_lib:format("~n==============~s====================~n~p~n",
                        [NowTime,Value]),
    io:format("~s~n",[Msg]),
    FileNameReal = lists:concat([FileName,".",binary_to_list(to_datestr(Now))]),
    file:write_file(FileNameReal, Msg, [append]),
    timer:sleep(Sleep),
    watch_tee_internal(F, Sleep, FileName).

stop_watch_tee() ->
    case get(tee_pid) of
        undefined ->
            skip;
        Pid ->
            exit(Pid, kill),
            erase(tee_pid)
    end.

%%count member of list
count(List) ->
    count(List, fun(Value) -> Value end).
count(List, Fun) when is_function(Fun) ->
    Dict =
        lists:foldl(
          fun(Elem, Dict) ->
              Key = Fun(Elem),
              case dict:find(Key, Dict) of
                  {ok, Value} ->
                      dict:store(Key, Value+1, Dict);
                  error ->
                      dict:store(Key, 1, Dict)
              end
          end, dict:new(), List),
    lists:reverse(lists:keysort(2,dict:to_list(Dict))).

%%partition_suffix("abcd1234efg.txt").
%%{"abcd",1234}
partition_suffix(Str) ->
    L1 = lists:dropwhile(fun(N) -> N < $0 orelse N > $9 end, lists:reverse(Str)),
    L = lists:takewhile(fun(N) -> N >= $0 andalso N =< $9 end,L1),
    case L of
        "" -> {Str,0};
        _ -> {lists:sublist(Str, length(L1) - length(L)),
              list_to_integer(lists:reverse(L))}
    end.

%%check vsn of modules
check_code() ->
    check_code(nodes()).
check_code(Nodes) ->
    MyVsns = code_vsns(),
    rpc_call(Nodes, fun() -> NodeVsns = ?MODULE:code_vsns(), ?MODULE:code_diff(MyVsns, NodeVsns) end).

code_vsns() ->
    lists:map(fun({Module,_}) ->
                      Attrs = Module:module_info(attributes),
                      {Module, proplists:get_value(vsn,Attrs)}
              end, lists:sort(code:all_loaded())).
code_diff(VsnList1, VsnList2) ->
    code_diff(VsnList1, VsnList2, []).
code_diff([{Module,V}|L1], [{Module,V}|L2], Acc) ->
    code_diff(L1, L2, Acc);
code_diff([{Module,V1}|L1],[{Module,V2}|L2], Acc) ->
    code_diff(L1, L2, [{Module, V1, V2}|Acc]);
code_diff([{Module1, V1}|L1],[{Module2, V2}|L2], Acc) when Module1 < Module2 ->
    code_diff(L1, [{Module2,V2}|L2], [{Module1, V1, novsn}|Acc]);
code_diff([{Module1, V1}|L1],[{Module2,V2}|L2], Acc) ->
    code_diff([{Module1,V1}|L1], L2, [{Module2, novsn, V2}|Acc]);
code_diff([], [], Acc) ->
    lists:reverse(Acc).

%%encode str base64 n times
encode_base64n(Msg) ->
    encode_base64n(Msg, 1).
encode_base64n(Msg, N) ->
    lists:foldl(fun(_,Acc)->base64:encode(Acc) end,unicode:characters_to_binary(Msg),lists:seq(1,N)).

%%get walltime of schedulers
scheduler_wall_time() ->
    scheduler_wall_time(1).
scheduler_wall_time(Second) ->
    OldTrap = erlang:process_flag(trap_exit,true),
    OldFlag = erlang:system_flag(scheduler_wall_time, true),
    try
        Ts0 = lists:sort(erlang:statistics(scheduler_wall_time)),
        timer:sleep(1000 * Second),
        Ts1 = lists:sort(erlang:statistics(scheduler_wall_time)),
        lists:map(fun({{I, A0, T0}, {I, A1, T1}}) ->
                          {I, (A1 - A0)/(T1 - T0)} end, lists:zip(Ts0,Ts1))
    after
        erlang:system_flag(scheduler_wall_time, OldFlag),
        erlang:process_flag(trap_exit, OldTrap)
    end.

%%get process path
proc_path(Pid) when node(Pid) == node() ->
    case erlang:process_info(Pid, [dictionary, registered_name]) of
        undefined ->
            [dead, Pid];
        [{dictionary, D},{registered_name,RegisteredName}] ->
            Ancestors = proplists:get_value('$ancestors',D,[]),
            Name = case is_atom(RegisteredName) of
                       true -> {RegisteredName,Pid};
                       false -> Pid
                   end,
            case application:get_application(Pid) of
                undefined ->
                    App = noapp;
                {ok,App} ->
                    ok
            end,
            [App] ++ lists:reverse([Name|Ancestors])
    end;
proc_path(Pid) ->
    rpc:call(node(Pid), ?MODULE, proc_path, [Pid]).

safe_do(Fun, Timeout) ->
    {Pid, Ref} =
        spawn_monitor(
          fun()->
                  exit({safe_do_res,Fun()})
          end),
    receive
        {'DOWN', Ref, process, Pid, {safe_do_res, Res}} ->
            Res;
        {'DOWN', Ref, process, Pid, Error} ->
            {error, Error}
    after Timeout ->
            exit(Pid,kill),
            receive
                {'DOWN', Ref, process, Pid, _} ->
                    ok
            end,
            {error, timeout}
    end.
%%============================
%%   internal function
%%============================

ensure_integer(Int) when is_integer(Int) ->
    Int;
ensure_integer(Atom) when is_atom(Atom) ->
    list_to_integer(atom_to_list(Atom));
ensure_integer(Bin) when is_binary(Bin) ->
    binary_to_integer(Bin);
ensure_integer(List) when is_list(List) ->
    list_to_integer(List).

ensure_binary(Int) when is_integer(Int) ->
    integer_to_binary(Int);
ensure_binary(Atom) when is_atom(Atom) ->
    list_to_binary(atom_to_list(Atom));
ensure_binary(Bin) when is_binary(Bin) ->
    Bin;
ensure_binary(List) when is_list(List) ->
    list_to_binary(List);
ensure_binary(Pid) when is_pid(Pid) ->
    list_to_binary(pid_to_list(Pid)).

ensure_list(L) ->
    binary_to_list(ensure_binary(L)).

ensure_atom(Int) when is_integer(Int) ->
    list_to_atom(integer_to_list(Int));
ensure_atom(Atom) when is_atom(Atom) ->
    Atom;
ensure_atom(Bin) when is_binary(Bin) ->
    list_to_atom(binary_to_list(Bin));
ensure_atom(List) when is_list(List) ->
    list_to_atom(List).

ensure_pid(List) when is_list(List) ->
    list_to_pid(List);
ensure_pid(Pid) when is_pid(Pid) ->
    Pid;
ensure_pid(Bin) when is_binary(Bin) ->
    ensure_pid(binary_to_list(Bin)).

ensure_port(List) when is_list(List) ->
    ["#Port", NodeId, PortId] = string:tokens(List,"<>."),
    PidBin = term_to_binary(c:pid(list_to_integer(NodeId),0,0)),
    PortBin = <<131,102,(binary:part(PidBin,2,byte_size(PidBin) - 11))/binary
                ,(list_to_integer(PortId)):32,(binary:last(PidBin)):8>>,
    binary_to_term(PortBin);
ensure_port(Bin) when is_binary(Bin) ->
    ensure_port(binary_to_list(Bin));
ensure_port(Port) when is_port(Port) ->
    Port.

ensure_node(Node) ->
    NodeReal = ensure_atom(Node),
    true = lists:member(NodeReal, [node()|nodes()]),
    NodeReal.

to_datetime(Timestamp) ->
    TS = to_timestamp(Timestamp),
    GS = TS + calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
    UDateTime = calendar:gregorian_seconds_to_datetime(GS),
    calendar:universal_time_to_local_time(UDateTime).

to_datetimestr(Timestamp) ->
    {{Year,Month,Day},{Hour,Minute,Second}} = to_datetime(Timestamp),
    iolist_to_binary(io_lib:format("~p-~2.2.0w-~2.2.0w ~2.2.0w:~2.2.0w:~2.2.0w",
                                   [Year,Month,Day,Hour,Minute,Second])).
to_datetimemsstr(TimeStampMs) ->
    DateTimeStr = to_datetimestr(TimeStampMs div 1000),
    Ms = TimeStampMs rem 1000,
    MsStr = iolist_to_binary(io_lib:format(".~3.3.0w",[Ms])),
    <<DateTimeStr/binary,MsStr/binary>>.

to_datestr(Timestamp) ->
    {{Year,Month,Day},_} = to_datetime(Timestamp),
    iolist_to_binary(io_lib:format("~p-~2.2.0w-~2.2.0w",
                                   [Year,Month,Day])).

to_timestamp(Integer)  when is_integer(Integer), Integer > 2000000000 ->
    Integer div 1000;
to_timestamp(Integer) when Integer < 365 * 86400 ->
    erlang:system_time(seconds) + Integer;
to_timestamp(Integer)  when is_integer(Integer) ->
    Integer;
to_timestamp(Bin)  when is_binary(Bin) ->
    to_timestamp(binary_to_list(Bin));
to_timestamp(List) when is_list(List) ->
    case catch list_to_integer(List) of
        Integer when is_integer(Integer) ->
            to_timestamp(Integer);
        {'EXIT',_} ->
            case string:tokens(List, ":- /.") of
                [Year, Month, Day, Hour,Minute,Second|_] ->
                    to_timestamp({{to_integer(Year),to_integer(Month),to_integer(Day)},
                                  {to_integer(Hour), to_integer(Minute),to_integer(Second)}});
                [Year, Month, Day] ->
                    to_timestamp({{to_integer(Year),to_integer(Month),to_integer(Day)},
                                  {0,0,0}});
                _ ->
                    throw({bad_time, List})
            end
    end;
to_timestamp({_,_,_}=Date) ->
    to_timestamp(Date);
to_timestamp({{_,_,_},{_,_,_}}=LocalTime) ->
    [DateTime] = calendar:local_time_to_universal_time_dst(LocalTime),
    calendar:datetime_to_gregorian_seconds(DateTime)
        - calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}).

to_binary(List) when is_list(List) ->
    try unicode:characters_to_binary(List) of
        V -> V
    catch
        _:_ ->
            list_to_binary(List)
    end;
to_binary(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8);
to_binary(Binary) when is_binary(Binary) ->
    Binary.

to_integer(X) ->
    binary_to_integer(to_binary(X)).