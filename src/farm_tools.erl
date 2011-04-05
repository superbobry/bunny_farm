-module(farm_tools).
-include("bunny_farm.hrl").
-export([decode_properties/1, 
  decode_payload/1, decode_payload/2,
  encode_payload/1, encode_payload/2]).
-export([to_list/1, atomize/1, atomize/2, listify/1, listify/2]).
-export([binarize/1]).
-export([to_queue_declare/1, to_amqp_props/1, to_basic_consume/1,
  is_rpc/1, reply_to/2]).

%% Properties is a 'P_basic' record. We convert it back to a tuple
%% list
decode_properties(#amqp_msg{props=Properties}) ->
  [_Name|Vs] = tuple_to_list(Properties),
  Ks = record_info(fields,'P_basic'),
  lists:zip(Ks,Vs).

decode_payload(#amqp_msg{payload=Payload}) ->
  decode_payload(Payload);
  
decode_payload(Payload) -> decode_payload(bson, Payload).
decode_payload(erlang, Payload) -> binary_to_term(Payload);
decode_payload(bson, Payload) ->
  try
    {Doc,_Bin} = bson_binary:get_document(Payload),
    bson:reflate(Doc)
  catch
    error:{badmatch,_} -> decode_payload(erlang, Payload);
    error:function_clause -> decode_payload(erlang, Payload)
  end.

encode_payload(Payload) -> encode_payload(bson, Payload).
encode_payload(erlang, Payload) -> term_to_binary(Payload);
encode_payload(bson, Payload) ->
  bson_binary:put_document(bson:document(Payload)).

%% Convert types to strings
to_list(Float) when is_float(Float) -> float_to_list(Float);
to_list(Integer) when is_integer(Integer) -> integer_to_list(Integer);
to_list(Atom) when is_atom(Atom) -> atom_to_list(Atom);
to_list(List) when is_list(List) -> List.

%% Convert strings to atoms
atomize(List) when is_list(List) ->
  list_to_atom(lists:foldl(fun(X,Y) -> Y ++ to_list(X) end, [], List)).

atomize(List, Sep) when is_list(List) ->
  list_to_atom(listify(List, Sep)).

%% Convert a list of elements into a single string
listify(List) when is_list(List) ->
  listify(List, " ").

listify(List, Sep) when is_list(List) ->
  [H|T] = List,
  lists:foldl(fun(X,Y) -> Y ++ Sep ++ to_list(X) end, to_list(H), T).
  
%% Convenience function to convert values to binary strings. Useful for
%% creating binary names for exchanges or routing keys. Not recommended 
%% for payloads.
binarize(Binary) when is_binary(Binary) -> Binary;

%% Example
%%   farm_tools:binarize([my, "-", 2]) => <<"my-2">>
binarize(List) when is_list(List) ->
  [H|T] = List,
  O = lists:foldl(fun(X,Y) -> Y ++ to_list(X) end, to_list(H), T),
  list_to_binary(O);

binarize(Other) -> list_to_binary(to_list(Other)).

%% Converts a tuple list of values to a queue.declare record
-spec to_queue_declare([{atom(), term()}]) -> #'queue.declare'{}.
to_queue_declare(Props) ->
  Defaults = [ {ticket,0}, {arguments,[]} ],
  Fn = fun(X, Acc) -> 
    case proplists:is_defined(X, Acc) of
      false -> Acc ++ [ {K,V} || {K,V} <- Defaults, K = X ];
      _ -> Acc
    end
  end,
  Enriched = lists:foldl(Fn, Props, [K || {K,_} <- Defaults]),
  list_to_tuple(['queue.declare'|[proplists:get_value(X,Enriched,false) || 
    X <- record_info(fields,'queue.declare')]]).

%% Converts a tuple list to a basic.consume record
-spec to_basic_consume([{atom(), term()}]) -> #'basic.consume'{}.
to_basic_consume(Props) ->
  Defaults = [ {ticket,0}, {arguments,[]}, {consumer_tag,<<"">>} ],
  Fn = fun(X, Acc) -> 
    case proplists:is_defined(X, Acc) of
      false -> Acc ++ [ {K,V} || {K,V} <- Defaults, K == X ];
      _ -> Acc
    end
  end,
  Enriched = lists:foldl(Fn, Props, [K || {K,_} <- Defaults]),
  list_to_tuple(['basic.consume'|[proplists:get_value(X,Enriched,false) || 
    X <- record_info(fields,'basic.consume')]]).

%% Converts a tuple list of values to amqp_msg properties (P_basic)
-spec to_amqp_props([{atom(), term()}]) -> #'P_basic'{}.
to_amqp_props(Props) ->
  list_to_tuple(['P_basic'|[proplists:get_value(X,Props) || 
    X <- record_info(fields,'P_basic')]]).

is_rpc(#amqp_msg{props=Props}) ->
  case Props#'P_basic'.reply_to of
    undefined -> false;
    _ -> true
  end.

%% Convenience function to get the reply_to property
%% This will split the reply_to value into an Exchange and Route if a
%% colon (:) is found as a separator. Otherwise, the existing exchange
%% will be used.
-spec reply_to(#amqp_msg{}, binary()) -> binary().
reply_to(Content, SourceX) ->
  Props = farm_tools:decode_properties(Content),
  Parts = binary:split(proplists:get_value(reply_to, Props), <<":">>),
  case Parts of
    [X,K] -> {X,K};
    [K] -> {SourceX,K}
  end.

