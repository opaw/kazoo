%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, 2600Hz INC
%%% @doc
%%% Simple & efficient operations on CSV binaries.
%%% @end
%%% @contributors
%%%   Pierre Fenoll
%%%-------------------------------------------------------------------
-module(kz_csv).

%% Public API
-export([count_rows/1
        ,fold/3
        ,take_row/1, take_mapped_row/2
        ,pad_row_to/2
        ,associator/3
        ,verify_mapped_row/2
        ,row_to_iolist/1, mapped_row_to_iolist/2
        ,json_to_iolist/1
        ]).
-export([from_jobjs/1
        ,from_jobjs/2
        ]).

-include_lib("kazoo/include/kz_types.hrl").
-include_lib("kazoo_csv/include/kazoo_csv.hrl").

-type cell() :: binary() | ?ZILCH.
-type header() :: [ne_binary(),...].
-type row() :: [cell(),...].
-type mapped_row() :: #{ne_binary() => cell()}.
-type csv() :: binary().

-export_type([cell/0
             ,header/0
             ,row/0, mapped_row/0
             ,csv/0
             ,folder/1
             ,fassoc/0, verifier/0
             ,mapped_row_verifier/0
             ]).

-ifdef(TEST).
-export([take_line/1]).
-export([split_row/1]).
-endif.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Return count of rows minus the first one.
%% Returns 0 if a row is longer/smaller than the header row.
%% @end
%%--------------------------------------------------------------------
-spec count_rows(csv()) -> non_neg_integer().
count_rows(<<>>) -> 0;
count_rows(CSV) when is_binary(CSV) ->
    try fold(CSV, fun throw_bad/2, {-1,0}) of
        {_, TotalRows} -> TotalRows
    catch
        'throw':{'error', 'bad_header_row'} -> 0;
        'throw':{'error', 'bad_csv_row'} -> 0
    end.

-spec throw_bad(row(), {integer(), non_neg_integer()}) -> {integer(), non_neg_integer()}.
throw_bad(Header, {-1,0}) ->
    case lists:all(fun kz_term:is_ne_binary/1, Header) of
        %% Strip header line from total rows count
        'true' ->
            {length(Header), 0};
        'false' ->
            lager:error("bad header row: ~p", [Header]),
            throw({'error', 'bad_header_row'})
    end;
throw_bad(Row, {MaxRow,RowsCounted}) ->
    case length(Row) of
        MaxRow -> {MaxRow, RowsCounted + 1};
        _ ->
            lager:error("bad row length ~p instead of ~p in ~p", [length(Row), MaxRow, Row]),
            throw({'error', 'bad_csv_row'})
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-type folder(T) :: fun((row(), T) -> T).
-spec fold(csv(), folder(T), T) -> T.
fold(CSV, Fun, Acc)
  when is_binary(CSV), is_function(Fun, 2) ->
    case take_row(CSV) of
        'eof' -> Acc;
        {Row, CSVRest} ->
            NewAcc = Fun(Row, Acc),
            fold(CSVRest, Fun, NewAcc)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec take_row(csv()) -> {row(), csv()} | 'eof'.
take_row(CSV)
  when is_binary(CSV) ->
    case take_line(CSV) of
        eof -> eof;
        [Line] ->
            {split_row(Line), <<>>};
        [Line, CSVRest] ->
            {split_row(Line), CSVRest}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec take_mapped_row(row(), csv()) -> {mapped_row(), csv()} | 'eof'.
take_mapped_row(Header, CSV)
  when is_binary(CSV) ->
    case take_row(CSV) of
        eof -> eof;
        {Row, CSVRest} ->
            MappedRow = maps:from_list(lists:zip(Header, Row)),
            {MappedRow, CSVRest}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec pad_row_to(non_neg_integer(), row()) -> row().
pad_row_to(N, Row)
  when N > length(Row) ->
    Row ++ lists:duplicate(N - length(Row), ?ZILCH);
pad_row_to(_, Row) ->
    Row.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-type fassoc_ret() :: {'ok', mapped_row()} | {'error', ne_binary()}.
-type fassoc() :: fun((row()) -> fassoc_ret()).
-type verifier() :: fun((atom(), cell()) -> boolean()).
-spec associator(row(), row(), verifier()) -> fassoc().
associator(CSVHeader, TaskFields, Verifier) ->
    Header = complete_header(TaskFields, CSVHeader),
    Max = length(Header),
    Map = map_io_indices(Header, CSVHeader),
    fun (Row0) ->
            Row = pad_row_to(Max, Row0),
            F = fun (_, ?NE_BINARY=Field) -> Field;
                    (I, MappedRow) when is_map(MappedRow) ->
                        case verify(Verifier, Header, Row, I, Map) of
                            {Key, Cell} -> MappedRow#{Key => Cell};
                            Field -> Field
                        end
                end,
            case lists:foldl(F, #{}, lists:seq(1, Max)) of
                MappedRow when is_map(MappedRow) -> {ok, MappedRow};
                Field -> {error, Field}
            end
    end.

verify(Verifier, Header, Row, I, Map) ->
    Cell = case maps:get(I, Map, undefined) of
               undefined -> ?ZILCH;
               J -> lists:nth(J, Row)
           end,
    Field = lists:nth(I, Header),
    case Verifier(Field, Cell) of
        false -> Field;
        true -> {Field, Cell}
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Returns an unordered list of the name of columns that did not pass validation.
%% @end
%%--------------------------------------------------------------------
-type mapped_row_verifier() :: fun((ne_binary(), cell()) -> boolean()).
-spec verify_mapped_row(mapped_row_verifier(), mapped_row()) -> [] | header().
verify_mapped_row(Pred, MappedRow) when is_function(Pred, 2),
                                        is_map(MappedRow) ->
    F = fun (K, V, Acc) ->
                case Pred(K, V) of
                    true -> Acc;
                    false -> [K|Acc]
                end
        end,
    maps:fold(F, [], MappedRow).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec row_to_iolist(row()) -> iodata().
row_to_iolist([Cell]) -> cell_to_binary(Cell);
row_to_iolist(Row=[_|_]) ->
    kz_util:iolist_join($,, [cell_to_binary(Cell) || Cell <- Row]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec mapped_row_to_iolist(row(), mapped_row()) -> iodata().
mapped_row_to_iolist(HeaderRow, Map) ->
    row_to_iolist([maps:get(Header, Map, ?ZILCH) || Header <- HeaderRow]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Converts JSON-represented CSV data to binary.
%% We assume fields for first record are defined in all other records.
%% @end
%%--------------------------------------------------------------------
-spec json_to_iolist(nonempty_list(kz_json:object())) -> iodata().
json_to_iolist(Records)
  when is_list(Records) ->
    Tmp = <<"/tmp/json_", (kz_binary:rand_hex(11))/binary, ".csv">>,
    Fields = kz_json:get_keys(hd(Records)),
    'ok' = file:write_file(Tmp, [kz_util:iolist_join($,, Fields), $\n]),
    lists:foreach(fun (Record) ->
                          Row = [kz_json:get_ne_binary_value(Field, Record, ?ZILCH) || Field <- Fields],
                          _ = file:write_file(Tmp, [row_to_iolist(Row),$\n], ['append'])
                  end
                 ,Records
                 ),
    {'ok', IOData} = file:read_file(Tmp),
    kz_util:delete_file(Tmp),
    IOData.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec from_jobjs(kz_json:objects()) -> iolist().
from_jobjs(JObjs) ->
    from_jobjs(JObjs, []).

-spec from_jobjs(kz_json:objects(), kz_proplist()) -> iolist().
from_jobjs(JObjs, Options) ->
    Routines = [fun maybe_transform/2
               ,fun check_integrity/2
               ,fun json_objs_to_csv/2
               ],
    lists:foldl(fun(F, J) -> F(J, Options) end, JObjs, Routines).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec take_line(csv()) -> [csv(),...] | eof.
take_line(CSV) ->
    case binary:split(CSV, [<<"\r\n">>, <<"\n\r">>, <<"\r\r">>, <<$\n>>, <<$\r>>]) of
        [<<>>|_] -> eof;
        Split -> Split
    end.

-spec split_row(ne_binary()) -> row().
split_row(Line) ->
    Splitted = binary:split(Line, <<$,>>, [global]),
    {Acc,io,<<>>} = lists:foldl(fun consume/2, {[],io,<<>>}, Splitted),
    lists:reverse(Acc).

-type acc() :: {row(), io | 34 | 39, binary()}.  %% $" | $'
-spec consume(binary(), acc()) -> acc().
consume(<<>>, {Acc,io,<<>>}) ->
    {[?ZILCH|Acc], io, <<>>};
consume(<<Sep:8,Bin/binary>>, {Acc,io,<<>>}) when Sep =:= $";
                                                  Sep =:= $' ->
    case binary:split(Bin, <<Sep:8>>) of
        [BinRest, <<>>] ->
            {[BinRest|Acc], io, <<>>};
        [LHS, <<Sep:8,RHS0/binary>>] ->  %% For "escaped" quotes
            AllButLast = byte_size(RHS0) - 1,
            <<RHS1:AllButLast/binary, Sep:8>> = RHS0,
            RHS = binary:replace(RHS1, <<Sep:8,Sep:8>>, <<Sep:8>>),
            Cell = <<LHS/binary, Sep:8, RHS/binary>>,
            {[Cell|Acc], io, <<>>};
        _ ->
            {Acc, Sep, Bin}
    end;
consume(Bin, {Acc,io,<<>>}) ->
    {[Bin|Acc], io, <<>>};
consume(Bin, {Acc,Sep,AccBin}) ->
    case binary:split(Bin, <<Sep:8>>) of
        [<<>>|_] ->
            {[AccBin|Acc], io, <<>>};
        [LastPart, <<>>] ->
            Cell = <<AccBin/binary, $,, LastPart/binary>>,
            {[Cell|Acc], io, <<>>};
        [Part] ->
            NewAccBin = <<AccBin/binary, $,, Part/binary>>,
            {Acc, Sep, NewAccBin}
    end.

%% @private
-spec find_position(ne_binary(), ne_binaries()) -> pos_integer().
-spec find_position(ne_binary(), ne_binaries(), pos_integer()) -> pos_integer().
find_position(Item, Items) ->
    find_position(Item, Items, 1).
find_position(Item, [Item|_], Pos) -> Pos;
find_position(Item, [_|Items], N) ->
    find_position(Item, Items, N+1).

complete_header(Fields, CSVHeader) ->
    Diff = CSVHeader -- Fields,
    Fields ++ Diff.

%% @private
map_io_indices(Header, CSVHeader) ->
    MapF = fun ({I, Head}, M) ->
                   M#{find_position(Head, Header) => I}
           end,
    IndexToCSVHeader = lists:zip(lists:seq(1, length(CSVHeader)), CSVHeader),
    lists:foldl(MapF, #{}, IndexToCSVHeader).

%% @private
-spec cell_to_binary(cell()) -> binary().
cell_to_binary(?ZILCH) -> <<>>;
cell_to_binary(<<>>) -> <<>>;
cell_to_binary(Cell=?NE_BINARY) ->
    binary:replace(Cell, <<$,>>, <<$;>>, ['global']);
cell_to_binary(Cell) ->
    kz_term:to_binary(Cell).

-spec maybe_transform(kz_json:objects(), kz_proplist()) -> kz_json:objects().
maybe_transform(JObjs, Options) ->
    case props:get_value('transform_fun', Options) of
        'undefined' -> JObjs;
        Fun -> [kz_json:map(Fun, JObj) || JObj <- JObjs]
    end.

-spec check_integrity(list(), kz_proplist()) -> kz_json:objects().
check_integrity(JObjs, _Options) ->
    Headers = get_headers(JObjs),
    check_integrity(JObjs, Headers, []).

-spec check_integrity(kz_json:objects(), ne_binaries(), kz_json:objects()) ->
                             kz_json:objects().
check_integrity([], _, Acc) ->
    lists:reverse(Acc);
check_integrity([JObj|JObjs], Headers, Acc) ->
    NJObj = lists:foldl(fun check_integrity_fold/2, JObj, Headers),
    NJObj1 = kz_json:from_list(lists:keysort(1, kz_json:to_proplist(NJObj))),
    check_integrity(JObjs, Headers, [NJObj1|Acc]).

-spec check_integrity_fold(kz_json:path(), kz_json:object()) ->
                                  kz_json:json_term().
check_integrity_fold(Header, JObj) ->
    case kz_json:get_value(Header, JObj) of
        'undefined' ->
            kz_json:set_value(Header, <<>>, JObj);
        _ -> JObj
    end.

-spec get_headers(kz_json:objects()) -> ne_binaries().
get_headers(JObjs) ->
    lists:foldl(fun fold_over_objects/2, [], JObjs).

-spec fold_over_objects(kz_json:object(), ne_binaries()) -> ne_binaries().
fold_over_objects(JObj, Headers) ->
    lists:foldl(fun fold_over_keys/2, Headers, kz_json:get_keys(JObj)).

-spec fold_over_keys(ne_binary(), ne_binaries()) -> ne_binaries().
fold_over_keys(Key, Hs) ->
    case lists:member(Key, Hs) of
        'false' -> [Key|Hs];
        'true' -> Hs
    end.

-spec create_csv_header(kz_json:objects(), kz_proplist()) -> iolist().
create_csv_header(JObjs, Options) ->
    Headers = case props:get_value('header_map', Options) of
                  'undefined' -> get_headers(JObjs);
                  HeaderMap ->
                      lists:map(fun(Header) -> header_map(Header, HeaderMap) end
                               ,get_headers(JObjs)
                               )
              end,
    csv_ize(lists:reverse(Headers)).

-spec header_map(ne_binary(), kz_proplist()) -> ne_binary().
header_map(Header, HeaderMap) ->
    case props:get_value(Header, HeaderMap) of
        'undefined' -> Header;
        FriendlyHeader -> FriendlyHeader
    end.

-spec json_objs_to_csv(kz_json:objects(), kz_proplist()) -> iolist().
json_objs_to_csv([], _) -> [];
json_objs_to_csv(JObjs, Options) ->
    [create_csv_header(JObjs, Options), [json_to_csv(JObj) || JObj <- JObjs]].

-spec csv_ize(kz_json:path()) -> iolist().
csv_ize([F|Rest]) ->
    [<<"\"">>, kz_term:to_binary(F), <<"\"">>
    ,[[<<",\"">>, try_to_binary(V), <<"\"">>] || V <- Rest]
    ,<<"\n">>
    ].

-spec try_to_binary(any()) -> binary().
try_to_binary(Value) ->
    try kz_term:to_binary(Value)
    catch
        _E:_R -> <<>>
    end.

-spec json_to_csv(kz_json:object()) -> iolist().
json_to_csv(JObj) ->
    csv_ize(kz_json:values(JObj)).
