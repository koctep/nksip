%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private User Subscriptions Library Module.
-module(nksip_subscription_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_handle/1, parse_handle/1, get_meta/2, get_metas/2]).
-export([remote_meta/2, remote_metas/2]).
-export([make_id/1, find/2, state/1, remote_id/2]).

-export_type([id/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: 
    binary().



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Get the subscripion a request, response or id
-spec get_handle(nksip:subscription()|nksip:request()|nksip:response()|nksip:handle()) ->
    nksip:handle().

get_handle({user_subs, #subscription{id=SubsId}, 
               #dialog{srv_id=SrvId, id=DialogId, call_id=CallId}}) ->
    make_handle(SrvId, SubsId, DialogId, CallId);

get_handle(#sipmsg{srv_id=SrvId, dialog_id=DialogId, call_id=CallId}=SipMsg) ->
    SubsId = make_id(SipMsg),
    make_handle(SrvId, SubsId, DialogId, CallId);

get_handle(<<"U_", _/binary>>=Id) ->
    Id;

get_handle(_) ->
    error(invalid_subscription).


%% @private
-spec parse_handle(nksip:handle()) ->
    {nkserver:id(), id(), nksip_dialog_lib:id(), nksip:call_id()}.

parse_handle(<<"U_", Rest/binary>>) ->
    case catch binary_to_term(base64:decode(Rest)) of
        {SrvId, SubsId, DialogId, CallId} ->
            {SrvId, SubsId, DialogId, CallId};
        _ ->
            error(invalid_handle)
    end;

parse_handle(_) ->
    error(invalid_handle).


%% @doc
-spec get_meta(nksip_subscription:field(), nksip:subscription()) ->
    term().

get_meta(Field, {user_subs, U, D}) ->
    case Field of
        id ->
            get_handle({user_subs, U, D});
        internal_id -> 
            U#subscription.id;
        status -> 
            U#subscription.status;
        event -> 
            U#subscription.event;
        raw_event -> 
            nklib_unparse:token(U#subscription.event);
        class -> 
            U#subscription.class;
        answered -> 
            U#subscription.answered;
        expires when is_reference(U#subscription.timer_expire) ->
            round(erlang:read_timer(U#subscription.timer_expire)/1000);
        expires ->
            undefined;
       _ ->
            nksip_dialog:get_meta(Field, D)
    end.


-spec get_metas([nksip_subscription:field()], nksip:subscription()) ->
    [{nksip_subscription:field(), term()}].

get_metas(Fields, {user_subs, U, D}) when is_list(Fields) ->
    [{Field, get_meta(Field, {user_subs, U, D})} || Field <- Fields].


%% @doc Extracts remote meta
-spec remote_meta(nksip_subscription:field(), nksip:handle()) ->
    {ok, term()} | {error, term()}.

remote_meta(Field, Handle) ->
    case remote_metas([Field], Handle) of
        {ok, [{_, Value}]} ->
            {ok, Value};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Extracts remote metas
-spec remote_metas([nksip_subscription:field()], nksip:handle()) ->
    {ok, [{nksip_dialog:field(), term()}]} | {error, term()}.

remote_metas(Fields, Handle) when is_list(Fields) ->
    {SrvId, SubsId, DialogId, CallId} = parse_handle(Handle),
    Fun = fun(Dialog) ->
        case find(SubsId, Dialog) of
            #subscription{} = U -> 
                case catch get_metas(Fields, {user_subs, U, Dialog}) of
                    {'EXIT', {{invalid_field, Field}, _}} -> 
                        {error, {invalid_field, Field}};
                    Values -> 
                        {ok, Values}
                end;
            not_found -> 
                {error, invalid_subscription}
        end
    end,
    case nksip_call:apply_dialog(SrvId, CallId, DialogId, Fun) of
        {apply, {ok, Values}} -> 
            {ok, Values};
        {apply, {error, {invalid_field, Field}}} -> 
            error({invalid_field, Field});
        {error, Error} -> 
            {error, Error}
    end.



% %% @doc Gets the subscription object corresponding to a request or subscription and a call
% -spec get_subscription(nksip:request()|nksip:response()|nksip:subscription(), nksip:call()) ->
%     {ok, nksip:subscription()} | {error, term()}.

% get_subscription(#sipmsg{}=SipMsg, #call{}=Call) ->
%     case nksip_dialog:get_dialog(SipMsg, Call) of
%         {ok, Dialog} ->
%             SubsId = make_id(SipMsg),
%             case find(SubsId, Dialog) of
%                 #subscription{}=Subs ->
%                     {ok, {user_subs, Subs, Dialog}};
%                 not_found ->
%                     {error, invalid_subscription}
%             end;
%         {error, _} ->
%             {error, invalid_subscription}
%     end.



%% @private
-spec make_id(nksip:request()) ->
    id().

make_id(#sipmsg{class={req, 'REFER'}, cseq={CSeqNum, 'REFER'}}) ->
    nklib_util:hash({<<"refer">>, nklib_util:to_binary(CSeqNum)});

make_id(#sipmsg{class={resp, _, _}, cseq={CSeqNum, 'REFER'}}) ->
    nklib_util:hash({<<"refer">>, nklib_util:to_binary(CSeqNum)});

make_id(#sipmsg{event={Event, Opts}}) ->
    Id = nklib_util:get_value(<<"id">>, Opts),
    nklib_util:hash({Event, Id});

make_id(#sipmsg{event=undefined}) ->
    <<"id">>.


%% @private Finds a event.
-spec find(id()|nksip:request()|nksip:response(), nksip:dialog()) ->
    nksip:subscription() | not_found.

find(Id, #dialog{subscriptions=Subs}) when is_binary(Id) ->
    do_find(Id, Subs);

find(#sipmsg{}=Req, #dialog{subscriptions=Subs}) ->
    do_find(make_id(Req), Subs).

%% @private 
do_find(_, []) -> not_found;
do_find(Id, [#subscription{id=Id}=Subs|_]) -> Subs;
do_find(Id, [_|Rest]) -> do_find(Id, Rest).



%% @private Hack to find the UAS subscription from the UAC and the opposite way
remote_id(Handle, Srv) ->
    {_PkgId0, SubsId, _DialogId, CallId} = parse_handle(Handle),
    {ok, DialogHandle} = nksip_dialog:get_handle(Handle),
    RemoteId = nksip_dialog_lib:remote_id(DialogHandle, Srv),
    {SrvId, RemDialogId, CallId} = nksip_dialog_lib:parse_handle(RemoteId),
    make_handle(SrvId, SubsId, RemDialogId, CallId).


%%    <<$U, $_, SubsId/binary, $_, RemDialogId/binary, $_, Srv1/binary, $_, CallId/binary>>.


%% @private
-spec state(nksip:request()) ->
    nksip_subscription:subscription_state() | invalid.

state(#sipmsg{}=SipMsg) ->
    try
        {Name, Opts} = case nksip_sipmsg:header(<<"subscription-state">>, SipMsg, tokens) of
            [{Name0, Opts0}] ->
                {Name0, Opts0};
            _ ->
                throw(invalid)
        end,
        case Name of
            <<"active">> -> 
                case nklib_util:get_integer(<<"expires">>, Opts, -1) of
                    -1 ->
                        Expires = undefined;
                    Expires when is_integer(Expires), Expires>=0 ->
                        ok;
                    _ ->
                        Expires = throw(invalid)
                end,
                 {active, Expires};
            <<"pending">> -> 
                case nklib_util:get_integer(<<"expires">>, Opts, -1) of
                    -1 ->
                        Expires = undefined;
                    Expires when is_integer(Expires), Expires>=0 ->
                        ok;
                    _ ->
                        Expires = throw(invalid)
                end,
                {pending, Expires};
            <<"terminated">> ->
                Retry = case nklib_util:get_integer(<<"retry-after">>, Opts, -1) of
                    -1 ->
                        undefined;
                    Retry0 when is_integer(Retry0), Retry0>=0 ->
                        Retry0;
                    _ ->
                        throw(invalid)
                end,
                case nklib_util:get_value(<<"reason">>, Opts) of
                    undefined -> 
                        {terminated, undefined, undefined};
                    Reason0 ->
                        case catch binary_to_existing_atom(Reason0, latin1) of
                            {'EXIT', _} ->
                                {terminated, undefined, undefined};
                            probation ->
                                {terminated, probation, Retry};
                            giveup ->
                                {terminated, giveup, Retry};
                            Reason ->
                                {terminated, Reason, undefined}
                        end
                end;
            _ ->
                throw(invalid)
        end
    catch
        throw:invalid ->
            invalid
    end.



make_handle(SrvId, SubsId, DialogId, CallId) ->
    <<"U_", (base64:encode(term_to_binary({SrvId, SubsId, DialogId, CallId})))/binary>>.
