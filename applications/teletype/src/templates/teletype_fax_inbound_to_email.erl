%%%-------------------------------------------------------------------
%%% @copyright (C) 2014-2017, 2600Hz Inc
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(teletype_fax_inbound_to_email).

-export([init/0
        ,handle_fax_inbound/1
        ]).

-include("teletype.hrl").

-define(TEMPLATE_ID, <<"fax_inbound_to_email">>).
-define(MOD_CONFIG_CAT, <<(?NOTIFY_CONFIG_CAT)/binary, ".", (?TEMPLATE_ID)/binary>>).
-define(FAX_CONFIG_CAT, <<(?NOTIFY_CONFIG_CAT)/binary, ".fax">>).

-define(TEMPLATE_MACROS
       ,kz_json:from_list(
          ?FAX_MACROS
          ++ ?DEFAULT_CALL_MACROS
          ++ ?USER_MACROS
         )).

-define(TEMPLATE_SUBJECT, <<"New fax from {{caller_id.name}} ({{caller_id.number}})">>).
-define(TEMPLATE_CATEGORY, <<"fax">>).
-define(TEMPLATE_NAME, <<"Inbound Fax to Email">>).

-define(TEMPLATE_TO, ?CONFIGURED_EMAILS(?EMAIL_ORIGINAL)).
-define(TEMPLATE_FROM, teletype_util:default_from_address(?MOD_CONFIG_CAT)).
-define(TEMPLATE_CC, ?CONFIGURED_EMAILS(?EMAIL_SPECIFIED, [])).
-define(TEMPLATE_BCC, ?CONFIGURED_EMAILS(?EMAIL_SPECIFIED, [])).
-define(TEMPLATE_REPLY_TO, teletype_util:default_reply_to(?MOD_CONFIG_CAT)).

-spec init() -> 'ok'.
init() ->
    kz_util:put_callid(?MODULE),
    teletype_templates:init(?TEMPLATE_ID, [{'macros', ?TEMPLATE_MACROS}
                                          ,{'subject', ?TEMPLATE_SUBJECT}
                                          ,{'category', ?TEMPLATE_CATEGORY}
                                          ,{'friendly_name', ?TEMPLATE_NAME}
                                          ,{'to', ?TEMPLATE_TO}
                                          ,{'from', ?TEMPLATE_FROM}
                                          ,{'cc', ?TEMPLATE_CC}
                                          ,{'bcc', ?TEMPLATE_BCC}
                                          ,{'reply_to', ?TEMPLATE_REPLY_TO}
                                          ]),
    teletype_bindings:bind(<<"inbound_fax">>, ?MODULE, 'handle_fax_inbound').

-spec handle_fax_inbound(kz_json:object()) -> 'ok'.
handle_fax_inbound(JObj) ->
    'true' = kapi_notifications:fax_inbound_v(JObj),
    kz_util:put_callid(JObj),

    lager:debug("processing fax inbound to email"),

    %% Gather data for template
    DataJObj = kz_json:normalize(JObj),
    AccountId = kz_json:get_value(<<"account_id">>, DataJObj),

    case teletype_util:is_notice_enabled(AccountId, JObj, ?TEMPLATE_ID) of
        'false' -> lager:debug("notification handling not configured for this account");
        'true' -> process_req(teletype_fax_util:add_data(DataJObj))
    end.

-spec process_req(kz_json:object()) -> 'ok'.
process_req(DataJObj) ->
    TemplateData = build_template_data(DataJObj),
    EmailAttachements = teletype_fax_util:get_attachments(DataJObj, TemplateData),
    Macros = teletype_fax_util:maybe_add_document_data(TemplateData, EmailAttachements),

    %% Load templates
    RenderedTemplates = teletype_templates:render(?TEMPLATE_ID, Macros, DataJObj),
    lager:debug("rendered templates"),

    {'ok', TemplateMetaJObj} = teletype_templates:fetch_notification(?TEMPLATE_ID, teletype_util:find_account_id(DataJObj)),

    Subject = teletype_util:render_subject(
                kz_json:find(<<"subject">>, [DataJObj, TemplateMetaJObj], ?TEMPLATE_SUBJECT), Macros
               ),
    lager:debug("rendered subject: ~s", [Subject]),

    EmailsJObj =
        case teletype_util:is_preview(DataJObj) of
            'true' -> DataJObj;
            'false' ->
                kz_json:set_value(<<"to">>, teletype_fax_util:to_email_addresses(DataJObj, ?MOD_CONFIG_CAT), DataJObj)
        end,

    Emails = teletype_util:find_addresses(EmailsJObj
                                         ,TemplateMetaJObj
                                         ,?MOD_CONFIG_CAT
                                         ),

    case teletype_util:send_email(Emails, Subject, RenderedTemplates, EmailAttachements) of
        'ok' -> teletype_util:send_update(DataJObj, <<"completed">>);
        {'error', Reason} -> teletype_util:send_update(DataJObj, <<"failed">>, Reason)
    end.

-spec build_template_data(kz_json:object()) -> kz_proplist().
build_template_data(DataJObj) ->
    FaxBoxJObj = kz_json:get_value(<<"faxbox">>, DataJObj),
    Timezone = kz_json:get_value([<<"fax">>, <<"rx_result">>, <<"timezone">>], DataJObj, kzd_fax_box:timezone(FaxBoxJObj)),
    props:filter_undefined(
      [{<<"account">>, teletype_util:account_params(DataJObj)}
      ,{<<"fax">>, build_fax_template_data(DataJObj)}
      ,{<<"system">>, teletype_util:system_params()}
      ,{<<"user">>, teletype_util:user_params(kz_json:get_value(<<"owner">>, DataJObj))}
       | teletype_util:build_call_data(DataJObj, Timezone)
      ]).

-spec build_fax_template_data(kz_json:object()) -> kz_proplist().
build_fax_template_data(DataJObj) ->
    FaxJObj = kz_json:get_value(<<"fax">>, DataJObj),
    FaxBoxJObj = kz_json:get_value(<<"faxbox">>, DataJObj),
    props:filter_undefined(
      [{<<"id">>, kz_json:get_value(<<"fax_id">>, DataJObj)}
      ,{<<"box_id">>, kz_json:get_value(<<"faxbox_id">>, DataJObj, kz_doc:id(FaxBoxJObj))}
      ,{<<"box_name">>, kz_json:get_value(<<"name">>, FaxBoxJObj)}
      ,{<<"timestamp">>, kz_json:get_value(<<"fax_timestamp">>, DataJObj, kz_time:current_tstamp())}
       | kz_json:to_proplist(kz_json:get_value(<<"tx_result">>, FaxJObj, kz_json:new()))
      ]).
