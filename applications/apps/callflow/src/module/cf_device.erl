%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, Karl Anderson
%%% @doc
%%%
%%% @end
%%% Created : 22 Feb 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cf_device).

-include("../callflow.hrl").

-export([handle/2]).

-import(cf_call_command, [b_bridge/3, wait_for_bridge/1, wait_for_unbridge/0]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Entry point for this module, attempts to call an endpoint as defined
%% in the Data payload.  Returns continue if fails to connect or 
%% stop when successfull.
%% @end
%%--------------------------------------------------------------------
-spec(handle/2 :: (Data :: json_object(), Call :: #cf_call{}) -> tuple(stop | continue)).
handle(Data, #cf_call{cf_pid=CFPid}=Call) ->    
    {ok, Endpoint} = get_endpoint(Data, Call#cf_call.account_db),
    Timeout = whapps_json:get_value(<<"timeout">>, Data, ?DEFAULT_TIMEOUT),
    case b_bridge([Endpoint], Timeout, Call) of
        {ok, _} ->
            _ = wait_for_unbridge(),
            CFPid ! { stop };
        {error, _} ->
            CFPid ! { continue }
    end.   

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Fetches a endpoint defintion from the database and returns the
%% whistle_api endpoint json
%% @end
%%--------------------------------------------------------------------
-spec(get_endpoint/2 :: (JObj :: json_object(), Db :: binary()) -> tuple(ok, json_object()) | tuple(error, atom())).
get_endpoint({struct, _}=EP, Db) ->
    Id = whapps_json:get_value(<<"id">>, EP),
    case couch_mgr:open_doc(Db, Id) of
        {ok, JObj} ->
            Endpoint = [
                         {<<"Invite-Format">>, whapps_json:get_value([<<"sip">>, <<"invite-format">>], JObj)}
                        ,{<<"To-User">>, whapps_json:get_value([<<"sip">>, <<"username">>], JObj)}
                        ,{<<"To-Realm">>, whapps_json:get_value([<<"sip">>, <<"realm">>], JObj)}
                        ,{<<"To-DID">>, whapps_json:get_value([<<"sip">>, <<"number">>], JObj)}
                        ,{<<"Route">>, whapps_json:get_value([<<"sip">>, <<"route">>], JObj)}
                        ,{<<"Ignore-Early-Media">>, whapps_json:get_value([<<"media">>, <<"ignore-early-media">>], JObj)}
                        ,{<<"Bypass-Media">>, whapps_json:get_value([<<"media">>, <<"bypass-media">>], JObj)}
                        ,{<<"Endpoint-Progress-Timeout">>, whapps_json:get_value([<<"media">>, <<"progress-timeout">>], EP, <<"6">>)}
                        ,{<<"Codecs">>, whapps_json:get_value([<<"media">>, <<"codecs">>], JObj)}
                    ],
            {ok, {struct, [ KV || {_, V}=KV <- Endpoint, V =/= undefined ]} };
        {error, _}=E ->
            logger:format_log(error, "CF_DEVICES(~p): Could not locate endpoint ~p in ~p (~p)~n", [self(), Id, Db, E]),
           E
    end.
