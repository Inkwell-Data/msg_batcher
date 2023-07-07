%% This module implements a msg queue using an ordered_set ets table.
%% The table is flushed periodically, or when the number of msgs in the table
%% reaches a threshold.
%%         (msgs)         (flush)
%% clients ========> ETS =========> callback([msgs]).
-module(msg_batcher_proc).

-behaviour(gen_server).

%% API
-export([start_link/5]).
%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         format_status/2,
         handle_continue/2
        ]).

-export([enqueue/2]).

-define(C_INDEX, 1).
-define(DROP_FACTOR, 10).
-define(FREQUENT_INTERVAL, 1000).
-define(FORCE_FLUSH, '$force_flush').
-define(TIMER_FLUSH, '$timer_flush').

-define(IF_EXPORTED(MOD, FUN, ARITY, EXPR_TURE, EXPR_FALSE),
    case erlang:function_exported(Mod, FUN, ARITY) of
        true -> EXPR_TURE;
        _ -> EXPR_FALSE
    end).

start_link(Id, BhvMod, InitArgs, GenOpts, Opts) ->
    gen_server:start_link({local, Id}, ?MODULE, {Id, BhvMod, InitArgs, Opts}, GenOpts).

enqueue(Id, Msg) ->
    #{batcher_id := Id, batch_size := BatchSize, counter_ref := CRef,
      drop_factor := DropFactor, sender_punish_time := PunishTime} = msg_batcher_object:get(Id),
    ensure_msg_queued(Id, Msg),
    incr_queue_size(CRef),
    maybe_notify_batcher_to_flush(Id, BatchSize, CRef, DropFactor, PunishTime).

init({Id, BhvMod, InitArgs, #{
            batch_size := BatchSize,
            batch_time := BatchTime
       } = Opts}) ->
    _ = erlang:process_flag(trap_exit, true),
    _ = ets:new(Id, [named_table, ordered_set, public, {write_concurrency, true}]),
    CRef = counters:new(1, [write_concurrency]),
    TRef = send_flush_after(BatchTime),
    DropFactor = maps:get(drop_factor, Opts, ?DROP_FACTOR),
    PunishTime = maps:get(sender_punish_time, Opts, donot_punish),
    msg_batcher_object:put(Id, #{batcher_id => Id, batch_time => BatchTime,
                                 batch_size => BatchSize, counter_ref => CRef,
                                 drop_factor => DropFactor, sender_punish_time => PunishTime}),
    Data = #{batcher_id => Id, behaviour_module => BhvMod,
             counter_ref => CRef, timer_ref => TRef},
    case BhvMod of
        undefined ->
            {ok, Data#{batch_callback => maps:get(batch_callback, Opts),
                       batch_callback_state => maps:get(batch_callback_state, Opts, no_state)}};
        _ ->
            handle_return(BhvMod:init(InitArgs),
                Data#{batch_callback => {BhvMod, handle_batch, []}})
    end.

handle_call(_Request, _From, #{behaviour_module := undefined} = Data) ->
    logger:error("[ets-batcher] Unknown call: ~p", [_Request]),
    {reply, ok, Data};
handle_call(Request, From, #{behaviour_module := Mod, batch_callback_state := CallbackState} = Data) ->
    ?IF_EXPORTED(Mod, handle_call, 3,
        handle_return(Mod:handle_call(Request, From, CallbackState), Data), {reply, ok, Data}).

handle_cast(_Msg, #{behaviour_module := undefined} = Data) ->
    logger:error("[ets-batcher] Unknown cast: ~p", [_Msg]),
    {noreply, Data};
handle_cast(_Msg, #{behaviour_module := Mod, batch_callback_state := CallbackState} = Data) ->
    ?IF_EXPORTED(Mod, handle_cast, 2,
        handle_return(Mod:handle_cast(_Msg, CallbackState), Data), {noreply, Data}).

handle_info(?FORCE_FLUSH, #{batcher_id := Id, batch_callback := Callback,
                            batch_callback_state := CallbackState,
                            counter_ref := CRef, timer_ref := TRef} = Data) ->
    case erlang:cancel_timer(TRef) of
        false ->
            %% try to clean the ?TIMER_FLUSH message as the timer was fired off
            %% right before we cancel the timer
            clean_mailbox(?TIMER_FLUSH);
        _ ->
            ok
    end,
    #{batch_size := BatchSize, batch_time := BatchTime,
      drop_factor := DropFactor} = msg_batcher_object:get(Id),
    clean_mailbox(?FORCE_FLUSH, BatchSize * DropFactor),
    {Cnt, NState} = do_flush(Id, BatchSize, Callback, CallbackState, CRef, DropFactor),
    {noreply, Data#{timer_ref => send_flush_after(BatchTime),
                    batch_callback_state => NState,
                    last_n_flush_cnt => record_last_flush_cnt(Data, Cnt)}};
handle_info(?TIMER_FLUSH, #{batcher_id := Id, batch_callback := Callback,
                            batch_callback_state := CallbackState,
                            counter_ref := CRef} = Data) ->
    #{batch_size := BatchSize, batch_time := BatchTime,
      drop_factor := DropFactor} = msg_batcher_object:get(Id),
    {Cnt, NState} = do_flush(Id, BatchSize, Callback, CallbackState, CRef, DropFactor),
    CheckTime = suitable_periodical_check_time(Data, BatchTime, Cnt),
    {noreply, Data#{timer_ref => send_flush_after(CheckTime),
                    batch_callback_state => NState,
                    last_n_flush_cnt => record_last_flush_cnt(Data, Cnt)}};

handle_info(Info, #{behaviour_module := undefined} = Data) ->
    logger:error("[ets-batcher] Unknown message: ~p", [Info]),
    {noreply, Data};

handle_info(Info, #{behaviour_module := Mod, batch_callback_state := CallbackState} = Data) ->
    ?IF_EXPORTED(Mod, handle_info, 2,
        handle_return(Mod:handle_info(Info, CallbackState), Data), {noreply, Data}).

terminate(Reason, #{batcher_id := Id, behaviour_module := Mod, batch_callback_state := CallbackState} = Data) ->
    msg_batcher_object:delete(Id),
    ?IF_EXPORTED(Mod, terminate, 2,
        handle_return(Mod:terminate(Reason, CallbackState), Data), ok).

code_change(OldVsn, #{behaviour_module := Mod, batch_callback_state := CallbackState} = Data, Extra) ->
    ?IF_EXPORTED(Mod, code_change, 3,
        handle_return(Mod:code_change(OldVsn, CallbackState, Extra), Data), {ok, Data}).

handle_continue(_Info, #{behaviour_module := undefined} = Data) ->
    {noreply, Data};
handle_continue(Info, #{behaviour_module := Mod, batch_callback_state := CallbackState} = Data) ->
    ?IF_EXPORTED(Mod, handle_continue, 2,
        handle_return(Mod:handle_continue(Info, CallbackState), Data), {noreply, Data}).

format_status(Opt, [_PDict, #{behaviour_module := undefined} = Data]) ->
    case Opt of
        terminate -> Data;
        _ -> [{data, [{"State", Data}]}]
    end;
format_status(Opt, [PDict, #{behaviour_module := Mod, batch_callback_state := CallbackState} = Data]) ->
    DefStatus = case Opt of
            terminate -> Data;
            _ -> [{data, [{"State", Data}]}]
        end,
    ?IF_EXPORTED(Mod, format_status, 2,
            case catch Mod:format_status(Opt, [PDict, CallbackState]) of
                {'EXIT', _} -> DefStatus;
                Else -> Else
            end, DefStatus).

%% =============================================================================
%% Call the behavior implementation module
%% =============================================================================
handle_return(ignore, _Data) ->
    ignore;
handle_return({ok, NState}, Data) ->
    {ok, Data#{batch_callback_state => NState}};
handle_return({ok, NState, Any}, Data) ->
    {ok, Data#{batch_callback_state => NState}, Any};
handle_return({reply, Reply, NState}, Data) ->
    {reply, Reply, Data#{batch_callback_state => NState}};
handle_return({reply, Reply, NState, Any}, Data) ->
    {reply, Reply, Data#{batch_callback_state => NState}, Any};
handle_return({noreply, NState}, Data) ->
    {noreply, Data#{batch_callback_state => NState}};
handle_return({noreply, NState, Any}, Data) ->
    {noreply, Data#{batch_callback_state => NState}, Any};
handle_return({stop, Reason, Reply, NState}, Data) ->
    {stop, Reason, Reply, Data#{batch_callback_state => NState}};
handle_return({stop, Reason, NState}, Data) ->
    {stop, Reason, Data#{batch_callback_state => NState}};
handle_return({continue, NState}, Data) ->
    {continue, Data#{batch_callback_state => NState}};
handle_return({error, Reason}, _Data) ->
    {error, Reason}.

%% =============================================================================
%% Internal functions
%% =============================================================================

ensure_msg_queued(Id, Msg) ->
    case ets:insert_new(Id, {msg_ts(), Msg}) of
        true -> ok;
        false ->
            %% the msg_ts() does not garantee an unique timestamp if called in parallel
            ensure_msg_queued(Id, Msg)
    end.

clean_mailbox(Msg) ->
    clean_mailbox(Msg, 10_000_000_000).

clean_mailbox(_Msg, 0) ->
    ok;
clean_mailbox(Msg, MaxCnt) ->
    receive Msg -> clean_mailbox(Msg, MaxCnt - 1)
    after 0 -> ok
    end.

send_flush_after(BatchTime) ->
    erlang:send_after(BatchTime, self(), ?TIMER_FLUSH).

maybe_notify_batcher_to_flush(Id, BatchSize, CRef, DropFactor, PunishTime) ->
    case get_queue_size(CRef) of
        Size when Size < BatchSize ->
            ok;
        Size when Size >= BatchSize, Size < BatchSize * DropFactor ->
            Id ! ?FORCE_FLUSH,
            ok;
        Size ->
            Id ! ?FORCE_FLUSH,
            maybe_punish_sender(PunishTime, Size)
    end.

maybe_punish_sender(donot_punish, _) ->
    ok;
maybe_punish_sender(PunishTime, Size) ->
    %% now the batcher got overloaded, we punish the caller by sleeping for a while
    logger:warning("[ets-batcher] overloaded, current queue length: ~p, the sender process is punished to sleep ~p ms", [Size, PunishTime]),
    timer:sleep(PunishTime).

do_flush(Tab, BatchSize, Callback, CallbackState, CRef, DropFactor) ->
    do_flush(Tab, BatchSize, Callback, CallbackState, CRef, DropFactor, 0).

do_flush(Tab, BatchSize, Callback, CallbackState, CRef, DropFactor, CntAcc) ->
    case ets:first(Tab) of
        '$end_of_table' ->
            {CntAcc, CallbackState};
        FirstKey ->
            BatchMsgs = take_first_n_msg(Tab, FirstKey, BatchSize - 1, [fetch_msg(Tab, FirstKey)]),
            Cnt = length(BatchMsgs),
            decr_queue_size(CRef, Cnt),
            case get_queue_size(CRef) of
                0 ->
                    {Cnt, call_handle_batch(Callback, CallbackState, BatchMsgs)};
                Size when Size < BatchSize * DropFactor ->
                    NState = call_handle_batch(Callback, CallbackState, BatchMsgs),
                    %% we still have some msgs, flush again until the table is empty
                    do_flush(Tab, BatchSize, Callback, NState, CRef, DropFactor, CntAcc + Cnt);
                Size when Size >= BatchSize * DropFactor ->
                    %% the batcher got overloaded so the ETS table cannot be flushed in time.
                    %% we now simply drop msgs taken from the table
                    logger:warning("[ets-batcher] overloaded, current queue length: ~p, dropped ~p msgs", [Size, Cnt]),
                    do_flush(Tab, BatchSize, Callback, CallbackState, CRef, DropFactor, CntAcc + Cnt)
            end
    end.

take_first_n_msg(_Tab, _Key, N, MsgAcc) when N =< 0 ->
    lists:reverse(MsgAcc);
take_first_n_msg(Tab, Key, N, MsgAcc) ->
    case ets:next(Tab, Key) of
        '$end_of_table' -> MsgAcc;
        NextKey ->
            take_first_n_msg(Tab, NextKey, N - 1, [fetch_msg(Tab, NextKey) | MsgAcc])
    end.

fetch_msg(Tab, Key) ->
    %% read value of Key from ets table, and then delete it
    case ets:take(Tab, Key) of
        [] -> throw({key_not_found, Key});
        [{_, Msg}] -> Msg
    end.

call_handle_batch({M, F, A}, no_state, BatchMsgs) ->
    _ = safe_apply(M, F, A ++ [BatchMsgs]),
    no_state;
call_handle_batch({M, F, A}, CallbackState, BatchMsgs) ->
    case safe_apply(M, F, A ++ [BatchMsgs, CallbackState]) of
        ok -> CallbackState;
        {ok, NewState} -> NewState
    end.

safe_apply(M, F, A) ->
    try erlang:apply(M, F, A)
    catch
        Err:Reason:ST ->
            logger:error("[ets-batcher] Error when calling ~p:~p/~p: ~p:~p, stacktrace:~p",
                [M, F, length(A), Err, Reason, ST])
    end.

msg_ts() ->
    erlang:monotonic_time(nanosecond).

incr_queue_size(CRef) ->
    counters:add(CRef, ?C_INDEX, 1).

get_queue_size(CRef) ->
    counters:get(CRef, ?C_INDEX).

decr_queue_size(CRef, Count) ->
    counters:sub(CRef, ?C_INDEX, Count).

suitable_periodical_check_time(Data, BatchTime, _Cnt = 0) when BatchTime < ?FREQUENT_INTERVAL ->
    %% avoid too frequent flush if the batcher is relatively free
    case is_last_n_flush_empty(Data) of
        true -> ?FREQUENT_INTERVAL;
        false -> BatchTime
    end;
suitable_periodical_check_time(_, BatchTime, _Cnt) ->
    BatchTime.

record_last_flush_cnt(#{last_n_flush_cnt := #{1 := Last1Cnt}}, Cnt) ->
    #{1 => Cnt, 2 => Last1Cnt};
record_last_flush_cnt(_, Cnt) ->
    #{1 => Cnt}.

is_last_n_flush_empty(#{last_n_flush_cnt := #{1 := 0, 2 := 0}}) ->
    true;
is_last_n_flush_empty(_) ->
    false.