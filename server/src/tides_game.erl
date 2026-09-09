-module(tides_game).

-include("tides_game.hrl").

-export([new_game/2]).
-export([submit/5, auto_submit/2, all_submitted/1, reveal/1, resolve/1]).
-export([is_over/1, scores/1, players/1, phase/1, set_auto_pilot/3, current_scores/1]).
-export([public_state/1, public_state/2, private_state/2]).

-define(MASK, 16#FFFFFFFFFFFFFFFF).
-define(GOODS, [<<"salt">>, <<"lamp">>, <<"silk">>]).

%%--------------------------------------------------------------------
%% setup
%%--------------------------------------------------------------------

new_game(Infos, Seed) when is_list(Infos), length(Infos) >= 2 ->
    tides_data:ensure_loaded(),
    Cfg = tides_data:config(),
    Cards = [card_from_map(M) || M <- tides_data:cards()],
    Contracts = [contract_from_map(M) || M <- tides_data:contracts()],
    HiddenPool = [C || C <- Contracts, C#r_contract.hidden =:= true],
    PublicPool = [C || C <- Contracts, C#r_contract.hidden =/= true],
    R0 = rng_seed(Seed),
    {R1, Deck0} = shuffle(Cards, R0),
    {R2, HiddenSh} = shuffle(HiddenPool, R1),
    {R3, PublicSh} = shuffle(PublicPool, R2),
    NPub = cfg_int(Cfg, <<"public_contracts">>, 3),
    HandSize = cfg_int(Cfg, <<"hand_size">>, 5),
    Coins = cfg_int(Cfg, <<"start_coins">>, 3),
    NHid = cfg_int(Cfg, <<"hidden_contracts_per_player">>, 1),
    Home = cfg_val(Cfg, <<"home_port">>, <<"east">>),
    StartTide = cfg_val(Cfg, <<"start_tide">>, <<"rising">>),
    {Public, ContractDeck} = split_take(PublicSh, NPub),
    Ids = [element(1, Info) || Info <- Infos],
    Ports0 = [port_from_map(M) || M <- tides_data:ports()],
    Ports = [case P#r_port.id of
                 Home -> P#r_port{ships = Ids};
                 _ -> P
             end || P <- Ports0],
    {Players, Deck1, _} = deal(Infos, 1, HandSize, NHid, Coins, Home, Deck0, HiddenSh, []),
    {R4, EventPiles} = build_event_piles(tides_data:events(), R3),
    #r_game{cfg = Cfg,
            players = Players,
            deck = Deck1,
            market = cfg_val(Cfg, <<"market_start">>, #{}),
            tide = StartTide,
            ports = Ports,
            public = Public,
            contract_deck = ContractDeck,
            event_piles = EventPiles,
             rng = R4}.

build_event_piles(Events, Rng) ->
    Tides = lists:usort([g(<<"tide">>, E, <<>>) || E <- Events]),
    lists:foldl(
        fun(T, {R, Acc}) ->
            Pile = [E || E <- Events, g(<<"tide">>, E, <<>>) =:= T],
            {R2, Sh} = shuffle(Pile, R),
            {R2, maps:put(T, Sh, Acc)}
        end,
        {Rng, #{}}, Tides).

deal([], _Seat, _HS, _NH, _Coins, _Home, Deck, Hidden, Acc) ->
    {lists:reverse(Acc), Deck, Hidden};
deal([Info | Rest], Seat, HS, NH, Coins, Home, Deck, Hidden, Acc) ->
    {Id, Name, IsBot, Diff} = case Info of
                                  {I, Nm} -> {I, Nm, false, undefined};
                                  {I, Nm, B} -> {I, Nm, B, undefined};
                                  {I, Nm, B, Df} -> {I, Nm, B, Df}
                              end,
    {Hand, Deck2} = split_take(Deck, HS),
    {Hid, Hidden2} = split_take(Hidden, NH),
    P = #r_player{id = Id, name = Name, seat = Seat, port = Home,
                  hand = Hand, coins = Coins, hidden = Hid, is_bot = IsBot,
                  difficulty = Diff},
    deal(Rest, Seat + 1, HS, NH, Coins, Home, Deck2, Hidden2, [P | Acc]).

card_from_map(M) ->
    #r_card{uid = g(<<"uid">>, M, <<>>),
            name = g(<<"name">>, M, <<>>),
            action = g(<<"action">>, M, <<>>),
            cargo = g(<<"cargo">>, M, <<>>),
            tide = g(<<"tide">>, M, 0)}.

contract_from_map(M) ->
    #r_contract{id = g(<<"id">>, M, <<>>),
                name = g(<<"name">>, M, <<>>),
                requires = g(<<"requires">>, M, []),
                port = g(<<"port">>, M, <<"any">>),
                reward_vp = g(<<"reward_vp">>, M, 0),
                reward_coins = g(<<"reward_coins">>, M, 0),
                hidden = g(<<"hidden">>, M, false)}.

port_from_map(M) ->
    #r_port{id = g(<<"id">>, M, <<>>),
            name = g(<<"name">>, M, <<>>),
            adj = g(<<"adj">>, M, [])}.

%%--------------------------------------------------------------------
%% submission
%%--------------------------------------------------------------------

submit(Game, Pid, Uid, Mode, Target) ->
    case Game#r_game.phase =:= <<"select">> andalso not Game#r_game.over of
        false ->
            {error, <<"not in select phase">>};
        true ->
            case find_player(Game, Pid) of
                false ->
                    {error, <<"player not found">>};
                P ->
                    case P#r_player.submitted of
                        false -> do_submit(Game, P, Uid, Mode, Target);
                        _ -> {error, <<"already submitted">>}
                    end
            end
    end.

do_submit(Game, P, Uid, Mode, Target) ->
    case lists:keyfind(Uid, #r_card.uid, P#r_player.hand) of
        false ->
            {error, <<"card not in hand">>};
        Card ->
            case validate_play(Game, P, Card, Mode, Target) of
                ok ->
                    P2 = P#r_player{submitted = {Uid, Mode, Target}},
                    {ok, replace_player(Game, P2)};
                {error, R} ->
                    {error, R}
            end
    end.

auto_submit(Game, Pid) ->
    case find_player(Game, Pid) of
        false ->
            Game;
        P ->
            case P#r_player.submitted of
                false ->
                    Play = case P#r_player.hand of
                               [C | _] -> {C#r_card.uid, <<"tide">>, undefined};
                               [] -> {none, <<"tide">>, undefined}
                           end,
                    replace_player(Game, P#r_player{submitted = Play});
                _ ->
                    Game
            end
    end.

all_submitted(Game) ->
    lists:all(fun(P) ->
                      P#r_player.submitted =/= false orelse P#r_player.hand =:= []
              end, Game#r_game.players).

reveal(Game) ->
    [#{<<"player_id">> => P#r_player.id,
       <<"card_id">> => play_uid(P#r_player.submitted),
       <<"mode">> => play_mode(P#r_player.submitted)}
     || P <- Game#r_game.players].

play_uid({U, _, _}) -> U;
play_uid(_) -> null.

play_mode({_, M, _}) -> M;
play_mode(_) -> null.

%%--------------------------------------------------------------------
%% validation
%%--------------------------------------------------------------------

validate_play(_G, _P, _C, <<"tide">>, _T) ->
    ok;
validate_play(_G, _P, C, <<"cargo">>, T) ->
    case C#r_card.cargo of
        <<"wild">> ->
            case T of
                #{<<"good">> := Gd} when Gd =:= <<"salt">>; Gd =:= <<"lamp">>; Gd =:= <<"silk">> ->
                    ok;
                _ ->
                    {error, <<"wild cargo requires target.good">>}
            end;
        _ ->
            ok
    end;
validate_play(G, P, C, <<"action">>, T) when is_map(T) ->
    validate_action(G, P, C, T);
validate_play(_G, _P, _C, <<"action">>, _T) ->
    {error, <<"action requires target">>};
validate_play(_, _, _, _, _) ->
    {error, <<"invalid mode">>}.

validate_action(G, P, C, T) ->
    case C#r_card.action of
        <<"sail">> -> validate_sail(G, P, T);
        <<"trade">> -> validate_trade(G, P, T);
        <<"deliver">> -> validate_deliver(G, P, T);
        <<"post">> -> validate_post(G, P, T);
        <<"tidecraft">> -> validate_tidecraft(T);
        <<"tailwind">> ->
            case validate_sail(G, P, T) of
                ok -> validate_trade(G, P, T);
                Err -> Err
            end;
        _ ->
            {error, <<"unknown card action">>}
    end.

validate_sail(G, P, T) ->
    case g(<<"to_port">>, T, undefined) of
        To when is_binary(To) ->
            case adjacent(G, P#r_player.port, To) of
                true ->
                    Cost = sail_cost(G),
                    case P#r_player.coins >= Cost of
                        true -> ok;
                        false -> {error, <<"not enough coins to sail">>}
                    end;
                false ->
                    {error, <<"port not adjacent">>}
            end;
        _ ->
            {error, <<"sail requires target.to_port">>}
    end.

validate_trade(G, P, T) ->
    Kind = g(<<"kind">>, T, undefined),
    Good = g(<<"good">>, T, undefined),
    Count = g(<<"count">>, T, undefined),
    case is_good(Good) of
        false ->
            {error, <<"invalid good">>};
        true ->
            case Kind of
                <<"buy">> ->
                    case Count of
                        N when is_integer(N), N >= 1, N =< 2 ->
                            Cost = buy_total(G, Good, N),
                            case P#r_player.coins >= Cost of
                                true -> ok;
                                false -> {error, <<"not enough coins to buy">>}
                            end;
                        _ ->
                            {error, <<"buy count must be 1 or 2">>}
                    end;
                <<"sell">> ->
                    case Count =:= 1 of
                        false ->
                            {error, <<"sell count must be 1">>};
                        true ->
                            case has_sellable(P#r_player.cargo, Good) of
                                true -> ok;
                                false -> {error, <<"good not in cargo">>}
                            end
                    end;
                _ ->
                    {error, <<"invalid trade kind">>}
            end
    end.

validate_deliver(G, P, T) ->
    case g(<<"contract_id">>, T, undefined) of
        Cid when is_binary(Cid) ->
            case find_contract(G, P, Cid) of
                {ok, _Src, C} ->
                    case contract_port_ok(P, C) of
                        false ->
                            {error, <<"wrong port for contract">>};
                        true ->
                            case has_goods(P#r_player.cargo, C#r_contract.requires) of
                                true -> ok;
                                false -> {error, <<"cargo does not meet contract requirements">>}
                            end
                    end;
                error ->
                    {error, <<"contract not available">>}
            end;
        _ ->
            {error, <<"deliver requires target.contract_id">>}
    end.

validate_post(G, P, T) ->
    case g(<<"port">>, T, undefined) of
        PortId when is_binary(PortId) ->
            case PortId =:= P#r_player.port of
                false ->
                    {error, <<"must be at port to post">>};
                true ->
                    Port = find_port(G, PortId),
                    MaxPosts = 3,
                    case length(Port#r_port.posts) >= MaxPosts of
                        true ->
                            {error, <<"port is full of posts">>};
                        false ->
                            case lists:member(P#r_player.id, Port#r_port.posts) of
                                true ->
                                    {error, <<"already has post at port">>};
                                false ->
                                    Cost = cfg_int(G#r_game.cfg, <<"post_cost">>, 2),
                                    case P#r_player.coins >= Cost of
                                        true -> ok;
                                        false -> {error, <<"not enough coins to post">>}
                                    end
                            end
                    end
            end;
        _ ->
            {error, <<"post requires target.port">>}
    end.

validate_tidecraft(T) ->
    case g(<<"op">>, T, undefined) of
        <<"peek">> ->
            ok;
        <<"shift">> ->
            case g(<<"delta">>, T, 0) of
                1 -> ok;
                -1 -> ok;
                _ -> {error, <<"delta must be 1 or -1">>}
            end;
        _ ->
            {error, <<"invalid tidecraft op">>}
    end.

%%--------------------------------------------------------------------
%% resolution
%%--------------------------------------------------------------------

resolve(Game) ->
    Order = resolve_order(Game),
    {G1, Logs1, TideSum} =
        lists:foldl(
            fun(P0, {GAcc, LAcc, SAcc}) ->
                case find_player(GAcc, P0#r_player.id) of
                    false -> {GAcc, LAcc, SAcc};
                    Pc ->
                        {G2, L2, S2} = resolve_one(GAcc, Pc),
                        {G2, LAcc ++ L2, SAcc + S2}
                end
            end,
            {Game, [], 0},
            Order),
    {G2, Logs2} = advance_tide(G1, TideSum),
    G3 = draw_all(G2),
    end_turn(G3, Logs1 ++ Logs2).

resolve_order(Game) ->
    Ps = Game#r_game.players,
    N = length(Ps),
    K = Game#r_game.start_seat rem N,
    {A, B} = lists:split(K, Ps),
    B ++ A.

resolve_one(G, P) ->
    case P#r_player.submitted of
        false ->
            {G, [], 0};
        {none, _, _} ->
            G1 = set_submitted(G, P#r_player.id, false),
            {G1, [<<(P#r_player.id)/binary, " has no card to play">>], 0};
        {Uid, Mode, Target} ->
            case lists:keytake(Uid, #r_card.uid, P#r_player.hand) of
                false ->
                    {set_submitted(G, P#r_player.id, false), [], 0};
                {value, Card, Hand2} ->
                    P1 = P#r_player{hand = Hand2},
                    G1 = replace_player(G, P1),
                    {G2, Logs, Discard} = apply_play(G1, P1, Card, Mode, Target),
                    G3 = case Discard of
                             true -> G2#r_game{discard = [Card | G2#r_game.discard]};
                             false -> G2
                         end,
                    G4 = set_submitted(G3, P#r_player.id, false),
                    Sum = case Mode of
                              <<"tide">> -> Card#r_card.tide;
                              _ -> 0
                          end,
                    {G4, Logs, Sum}
            end
    end.

apply_play(G, P, Card, Mode, Target) ->
    case validate_play(G, P, Card, Mode, Target) of
        ok ->
            apply_mode(G, P, Card, Mode, Target);
        {error, R} ->
            Log = <<(P#r_player.id)/binary, " play fizzled: ", R/binary>>,
            {G, [Log], true}
    end.

apply_mode(G, P, Card, <<"cargo">>, Target) ->
    Good = case Card#r_card.cargo of
               <<"wild">> -> g(<<"good">>, Target, <<"salt">>);
               G0 -> G0
           end,
    G1 = upd_player(G, P#r_player.id, fun(X) -> X#r_player{cargo = X#r_player.cargo ++ [Good]} end),
    Log = <<(P#r_player.id)/binary, " keeps ", (Card#r_card.name)/binary, " as ", Good/binary>>,
    {G1, [Log], false};
apply_mode(G, P, Card, <<"tide">>, _Target) ->
    Log = <<(P#r_player.id)/binary, " tides ", (Card#r_card.name)/binary>>,
    {G, [Log], true};
apply_mode(G, P, Card, <<"action">>, Target) ->
    case Card#r_card.action of
        <<"sail">> ->
            {G1, L} = apply_sail(G, P, Target),
            {G1, L, true};
        <<"trade">> ->
            {G1, L} = apply_trade(G, P, Target),
            {G1, L, true};
        <<"deliver">> ->
            {G1, L} = apply_deliver(G, P, Target),
            {G1, L, true};
        <<"post">> ->
            {G1, L} = apply_post(G, P, Target),
            {G1, L, true};
        <<"tidecraft">> ->
            {G1, L} = apply_tidecraft(G, P, Target),
            {G1, L, true};
        <<"tailwind">> ->
            {G1, L1} = apply_sail(G, P, Target),
            P1 = find_player(G1, P#r_player.id),
            {G2, L2} = apply_trade(G1, P1, Target),
            {G2, L1 ++ L2, true};
        _ ->
            {G, [], true}
    end.

apply_sail(G, P, T) ->
    To = g(<<"to_port">>, T, P#r_player.port),
    Cost = sail_cost(G),
    G1 = upd_player(G, P#r_player.id,
                    fun(X) -> X#r_player{coins = X#r_player.coins - Cost, port = To} end),
    G2 = move_ship(G1, P#r_player.id, P#r_player.port, To),
    Log = <<(P#r_player.id)/binary, " sails to ", To/binary, " (cost ", (integer_to_binary(Cost))/binary, ")">>,
    {G2, [Log]}.

apply_trade(G, P, T) ->
    Kind = g(<<"kind">>, T, <<>>),
    Good = g(<<"good">>, T, <<>>),
    Count = g(<<"count">>, T, 1),
    case Kind of
        <<"buy">> ->
            Cost = buy_total(G, Good, Count),
            G1 = upd_player(G, P#r_player.id,
                            fun(X) -> X#r_player{coins = X#r_player.coins - Cost,
                                                 cargo = X#r_player.cargo ++ lists:duplicate(Count, Good)} end),
            Log = <<(P#r_player.id)/binary, " buys ", (integer_to_binary(Count))/binary, " ", Good/binary>>,
            {G1, [Log]};
        <<"sell">> ->
            Price = market_price(G, Good),
            Gain = case G#r_game.tide of
                       <<"full">> -> Price + 1;
                       _ -> Price
                   end,
            G1 = upd_player(G, P#r_player.id,
                            fun(X) -> X#r_player{coins = X#r_player.coins + Gain,
                                                 cargo = remove_good(X#r_player.cargo, Good)} end),
            G2 = market_move(G1, Good, -1),
            Log = <<(P#r_player.id)/binary, " sells ", Good/binary, " for ", (integer_to_binary(Gain))/binary>>,
            {G2, [Log]}
    end.

apply_deliver(G, P, T) ->
    Cid = g(<<"contract_id">>, T, <<>>),
    {ok, Src, C} = find_contract(G, P, Cid),
    BonusVp = case G#r_game.tide of
                  <<"rising">> -> 1;
                  _ -> 0
              end +
              case G#r_game.tide =:= <<"ebb">> andalso Src =:= hidden of
                  true -> 1;
                  false -> 0
              end,
    Vp = C#r_contract.reward_vp + BonusVp,
    Coins = C#r_contract.reward_coins,
    G1 = upd_player(G, P#r_player.id,
                    fun(X) -> X#r_player{vp = X#r_player.vp + Vp,
                                         coins = X#r_player.coins + Coins,
                                         cargo = consume_goods(X#r_player.cargo, C#r_contract.requires)} end),
    G2 = case Src of
             public ->
                 Pub = lists:keydelete(Cid, #r_contract.id, G1#r_game.public),
                 {NewPub, NewDeck} = case G1#r_game.contract_deck of
                                         [NC | Rest] -> {Pub ++ [NC], Rest};
                                         [] -> {Pub, []}
                                     end,
                 G1#r_game{public = NewPub, contract_deck = NewDeck};
             hidden ->
                 upd_player(G1, P#r_player.id,
                            fun(X) -> X#r_player{hidden = lists:keydelete(Cid, #r_contract.id, X#r_player.hidden),
                                                 done = X#r_player.done ++ [Cid]} end)
         end,
    Goods = lists:usort([g(<<"good">>, R, <<>>) || R <- C#r_contract.requires]),
    G3 = lists:foldl(fun(Gd, Acc) -> market_move(Acc, Gd, -1) end, G2, Goods),
    Log = <<(P#r_player.id)/binary, " delivers ", (C#r_contract.name)/binary,
            " (+", (integer_to_binary(Vp))/binary, "vp)">>,
    {G3, [Log]}.

apply_post(G, P, T) ->
    PortId = g(<<"port">>, T, P#r_player.port),
    Cost = cfg_int(G#r_game.cfg, <<"post_cost">>, 2),
    G1 = upd_player(G, P#r_player.id, fun(X) -> X#r_player{coins = X#r_player.coins - Cost} end),
    G2 = upd_port(G1, PortId, fun(Pt) -> Pt#r_port{posts = Pt#r_port.posts ++ [P#r_player.id]} end),
    Log = <<(P#r_player.id)/binary, " posts at ", PortId/binary>>,
    {G2, [Log]}.

apply_tidecraft(G, P, T) ->
    case g(<<"op">>, T, <<>>) of
        <<"peek">> ->
            Log = <<(P#r_player.id)/binary, " peeks the tide">>,
            {G, [Log]};
        <<"shift">> ->
            Delta = g(<<"delta">>, T, 0),
            {G1, EvLogs} = shift_tide(G, Delta),
            Log = <<(P#r_player.id)/binary, " shifts the tide">>,
            {G1, [Log | EvLogs]}
    end.

%%--------------------------------------------------------------------
%% tide / events
%%--------------------------------------------------------------------

advance_tide(G, Sum) when is_integer(Sum) ->
    shift_tide(G, Sum).

shift_tide(G, 0) ->
    {G, []};
shift_tide(G, Delta) when Delta > 0 ->
    {G1, L1} = tide_step(G, 1),
    {G2, L2} = shift_tide(G1, Delta - 1),
    {G2, L1 ++ L2};
shift_tide(G, Delta) when Delta < 0 ->
    {G1, L1} = tide_step(G, -1),
    {G2, L2} = shift_tide(G1, Delta + 1),
    {G2, L1 ++ L2}.

tide_step(G, Dir) ->
    Order = tide_order(G),
    NT = step_tide(Order, G#r_game.tide, Dir),
    G1 = G#r_game{tide = NT},
    Pile = maps:get(NT, G1#r_game.event_piles, []),
    case Pile of
        [] ->
            {G1, []};
        [Ev | Rest] ->
            G2 = G1#r_game{event_piles = maps:put(NT, Rest ++ [Ev], G1#r_game.event_piles)},
            {G3, Logs} = apply_event(G2, Ev),
            {G3, Logs}
    end.

step_tide(Order, Tide, Dir) ->
    N = length(Order),
    Idx = index_of(Tide, Order, 0),
    NI = ((Idx + Dir) rem N + N) rem N,
    lists:nth(NI + 1, Order).

index_of(X, [X | _], I) -> I;
index_of(X, [_ | T], I) -> index_of(X, T, I + 1);
index_of(_, [], _) -> 0.

apply_event(G, Ev) ->
    Eff = g(<<"effect">>, Ev, #{}),
    Type = g(<<"type">>, Eff, <<"none">>),
    Text = g(<<"text">>, Ev, <<"event">>),
    G2 = case Type of
             <<"lose_coin">> ->
                 N = g(<<"count">>, Eff, 1),
                 upd_players(G, fun(X) -> X#r_player{coins = max(0, X#r_player.coins - N)} end);
             <<"gain_coin">> ->
                 N = g(<<"count">>, Eff, 1),
                 upd_players(G, fun(X) -> X#r_player{coins = X#r_player.coins + N} end);
             <<"market_up">> ->
                 Good = g(<<"good">>, Eff, <<"salt">>),
                 market_move(G, Good, 1);
             <<"market_up_highest">> ->
                 market_move(G, highest_good(G), 1);
             _ ->
                 G
         end,
    {G2, [Text]}.

%%--------------------------------------------------------------------
%% turn management
%%--------------------------------------------------------------------

draw_all(G) ->
    N = cfg_int(G#r_game.cfg, <<"draw_per_turn">>, 1),
    HS = cfg_int(G#r_game.cfg, <<"hand_size">>, 5),
    lists:foldl(
        fun(P, GAcc) ->
            case length(P#r_player.hand) < HS of
                false -> GAcc;
                true -> draw_n(GAcc, P#r_player.id, N)
            end
        end,
        G, G#r_game.players).

draw_n(G, _Pid, 0) -> G;
draw_n(G, Pid, N) ->
    case G#r_game.deck of
        [] -> G;
        [C | Rest] ->
            G1 = G#r_game{deck = Rest},
            G2 = upd_player(G1, Pid, fun(X) -> X#r_player{hand = X#r_player.hand ++ [C]} end),
            draw_n(G2, Pid, N - 1)
    end.

end_turn(G, Logs) ->
    TPR = cfg_int(G#r_game.cfg, <<"turns_per_round">>, 3),
    Rounds = cfg_int(G#r_game.cfg, <<"rounds">>, 4),
    {R2, T2} = case G#r_game.turn >= TPR of
                   true -> {G#r_game.round + 1, 1};
                   false -> {G#r_game.round, G#r_game.turn + 1}
               end,
    N = length(G#r_game.players),
    G1 = G#r_game{round = R2, turn = T2, start_seat = (G#r_game.start_seat + 1) rem N},
    case R2 > Rounds of
        true ->
            Sc = compute_scores(G1),
            {G1#r_game{over = true, phase = <<"game_over">>, scores = Sc}, Logs};
        false ->
            {G1, Logs}
    end.

%%--------------------------------------------------------------------
%% scoring
%%--------------------------------------------------------------------

compute_scores(G) ->
    ScoresList = cfg_val(G#r_game.cfg, <<"post_scores">>, [4, 2, 1]),
    CargoMax = cfg_int(G#r_game.cfg, <<"cargo_score_max">>, 5),
    Rate = cfg_int(G#r_game.cfg, <<"coin_score_rate">>, 3),
    CoinMax = cfg_int(G#r_game.cfg, <<"coin_score_max">>, 4),
    PostPts = post_points(G, ScoresList),
    [#{<<"player_id">> => P#r_player.id,
       <<"total">> => P#r_player.vp
                      + maps:get(P#r_player.id, PostPts, 0)
                      + min(length(P#r_player.cargo), CargoMax)
                      + min(P#r_player.coins div max(1, Rate), CoinMax),
       <<"breakdown">> => #{<<"orders">> => P#r_player.vp,
                            <<"posts">> => maps:get(P#r_player.id, PostPts, 0),
                            <<"cargo">> => min(length(P#r_player.cargo), CargoMax),
                            <<"coins">> => min(P#r_player.coins div max(1, Rate), CoinMax)}}
     || P <- G#r_game.players].

post_points(G, ScoresList) ->
    lists:foldl(
        fun(Port, Acc) ->
            Counts = count_posts(Port#r_port.posts),
            Distinct = lists:reverse(lists:usort([N || {_, N} <- Counts])),
            lists:foldl(
                fun({Pid, N}, A2) ->
                    Rank = rank_of(N, Distinct, 1),
                    Share = length([1 || {_, N2} <- Counts, N2 =:= N]),
                    Pts = case length(ScoresList) >= Rank of
                              true -> lists:nth(Rank, ScoresList) div Share;
                              false -> 0
                          end,
                    maps:put(Pid, maps:get(Pid, A2, 0) + Pts, A2)
                end,
                Acc, Counts)
        end,
        #{}, G#r_game.ports).

count_posts(Posts) ->
    M = lists:foldl(
        fun(Pid, Acc) -> maps:put(Pid, maps:get(Pid, Acc, 0) + 1, Acc) end,
        #{}, Posts),
    maps:to_list(M).

rank_of(N, [N | _], R) -> R;
rank_of(N, [_ | T], R) -> rank_of(N, T, R + 1);
rank_of(_, [], R) -> R.

%%--------------------------------------------------------------------
%% prices / costs
%%--------------------------------------------------------------------

sail_cost(G) ->
    Base = cfg_int(G#r_game.cfg, <<"sail_base_cost">>, 1),
    Min = cfg_int(G#r_game.cfg, <<"sail_cost_min">>, 0),
    Mod = case G#r_game.tide of
              <<"low">> -> 1;
              <<"ebb">> -> 1;
              <<"full">> -> -1;
              _ -> 0
          end,
    max(Min, Base + Mod).

buy_total(G, Good, Count) ->
    Unit = market_price(G, Good),
    Total = Unit * Count,
    case G#r_game.tide of
        <<"low">> -> max(0, Total - 1);
        _ -> Total
    end.

market_price(G, Good) ->
    maps:get(Good, G#r_game.market, 0).

market_move(G, Good, Delta) ->
    Min = cfg_int(G#r_game.cfg, <<"market_min">>, 1),
    Max = cfg_int(G#r_game.cfg, <<"market_max">>, 6),
    P0 = market_price(G, Good),
    P1 = min(Max, max(Min, P0 + Delta)),
    G#r_game{market = maps:put(Good, P1, G#r_game.market)}.

highest_good(G) ->
    lists:foldl(
        fun(Gd, Best) ->
            case market_price(G, Gd) > market_price(G, Best) of
                true -> Gd;
                false -> Best
            end
        end,
        hd(?GOODS), tl(?GOODS)).

%%--------------------------------------------------------------------
%% misc helpers
%%--------------------------------------------------------------------

is_over(G) -> G#r_game.over.

set_auto_pilot(G, Pid, Val) ->
    upd_player(G, Pid, fun(X) -> X#r_player{auto_pilot = Val} end).

scores(G) -> G#r_game.scores.

%% 主动退出等导致的提前终局：按当前局面立即计分（无需等待回合结束）
current_scores(G) -> compute_scores(G).

players(G) -> G#r_game.players.

phase(G) -> G#r_game.phase.

tide_order(G) ->
    case cfg_val(G#r_game.cfg, <<"tide_order">>, [<<"low">>, <<"rising">>, <<"full">>, <<"ebb">>]) of
        [] -> [<<"low">>, <<"rising">>, <<"full">>, <<"ebb">>];
        L -> L
    end.

adjacent(G, From, To) ->
    case find_port(G, From) of
        false -> false;
        Port -> lists:member(To, Port#r_port.adj)
    end.

find_port(G, PortId) ->
    lists:keyfind(PortId, #r_port.id, G#r_game.ports).

upd_port(G, PortId, Fun) ->
    Ports = [case Pt#r_port.id of
                 PortId -> Fun(Pt);
                 _ -> Pt
             end || Pt <- G#r_game.ports],
    G#r_game{ports = Ports}.

move_ship(G, Pid, From, To) ->
    G1 = upd_port(G, From, fun(Pt) -> Pt#r_port{ships = lists:delete(Pid, Pt#r_port.ships)} end),
    upd_port(G1, To, fun(Pt) -> Pt#r_port{ships = Pt#r_port.ships ++ [Pid]} end).

find_player(G, Pid) ->
    lists:keyfind(Pid, #r_player.id, G#r_game.players).

replace_player(G, P) ->
    G#r_game{players = lists:keyreplace(P#r_player.id, #r_player.id, G#r_game.players, P)}.

upd_player(G, Pid, Fun) ->
    case find_player(G, Pid) of
        false -> G;
        P -> replace_player(G, Fun(P))
    end.

upd_players(G, Fun) ->
    G#r_game{players = [Fun(P) || P <- G#r_game.players]}.

set_submitted(G, Pid, Val) ->
    upd_player(G, Pid, fun(X) -> X#r_player{submitted = Val} end).

find_contract(G, P, Cid) ->
    case lists:keyfind(Cid, #r_contract.id, G#r_game.public) of
        false ->
            case lists:keyfind(Cid, #r_contract.id, P#r_player.hidden) of
                false -> error;
                C -> {ok, hidden, C}
            end;
        C ->
            {ok, public, C}
    end.

contract_port_ok(P, C) ->
    C#r_contract.port =:= <<"any">> orelse C#r_contract.port =:= P#r_player.port.

is_good(Gd) ->
    lists:member(Gd, ?GOODS).

has_sellable(Cargo, Good) ->
    lists:member(Good, Cargo) orelse lists:member(<<"wild">>, Cargo).

remove_good(Cargo, Good) ->
    case lists:member(Good, Cargo) of
        true -> lists:delete(Good, Cargo);
        false -> lists:delete(<<"wild">>, Cargo)
    end.

has_goods(Cargo, Requires) ->
    lists:all(
        fun(R) ->
            Good = g(<<"good">>, R, <<>>),
            Count = g(<<"count">>, R, 1),
            length([1 || C <- Cargo, C =:= Good]) >= Count
        end,
        Requires).

consume_goods(Cargo, Requires) ->
    lists:foldl(
        fun(R, Acc) ->
            Good = g(<<"good">>, R, <<>>),
            Count = g(<<"count">>, R, 1),
            remove_n(Acc, Good, Count)
        end,
        Cargo, Requires).

remove_n(Cargo, _Good, 0) -> Cargo;
remove_n(Cargo, Good, N) -> remove_n(lists:delete(Good, Cargo), Good, N - 1).

cfg_int(Cfg, K, D) ->
    case maps:find(K, Cfg) of
        {ok, V} when is_integer(V) -> V;
        _ -> D
    end.

cfg_val(Cfg, K, D) ->
    case maps:find(K, Cfg) of
        {ok, V} -> V;
        _ -> D
    end.

g(K, M, D) when is_map(M) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error -> D
    end;
g(_, _, D) ->
    D.

split_take(L, N) ->
    K = min(N, length(L)),
    {lists:sublist(L, K), lists:nthtail(K, L)}.

%%--------------------------------------------------------------------
%% deterministic rng (xorshift64*)
%%--------------------------------------------------------------------

rng_seed(N) when is_integer(N) ->
    case N band ?MASK of
        0 -> 16#9E3779B97F4A7C15;
        V -> V
    end;
rng_seed({A, B, C}) ->
    rng_seed(A * 1000003 + B * 1009 + C + 1).

rng_next(S) ->
    S1 = (S bxor (S bsr 12)) band ?MASK,
    S2 = (S1 bxor ((S1 bsl 25) band ?MASK)) band ?MASK,
    S3 = (S2 bxor (S2 bsr 27)) band ?MASK,
    {S3, (S3 * 2685821657736338717) band ?MASK}.

shuffle(L, Rng) ->
    {Keyed, Rng2} = lists:mapfoldl(
        fun(E, R) ->
            {R2, V} = rng_next(R),
            {{V, E}, R2}
        end,
        Rng, L),
    {Rng2, [E || {_, E} <- lists:keysort(1, Keyed)]}.

%%--------------------------------------------------------------------
%% state export
%%--------------------------------------------------------------------

public_state(G) ->
    public_state(G, #{}).

public_state(G, ConnMap) ->
    #{<<"round">> => G#r_game.round,
      <<"turn">> => G#r_game.turn,
      <<"phase">> => G#r_game.phase,
      <<"tide">> => G#r_game.tide,
      <<"market">> => G#r_game.market,
      <<"ports">> => [#{<<"id">> => Pt#r_port.id,
                        <<"ships">> => [id_json(X) || X <- Pt#r_port.ships],
                        <<"posts">> => [#{<<"player_id">> => id_json(X)} || X <- Pt#r_port.posts]}
                      || Pt <- G#r_game.ports],
      <<"public_contracts">> => [contract_json(C) || C <- G#r_game.public],
      <<"players">> => [#{<<"id">> => id_json(P#r_player.id),
                          <<"name">> => P#r_player.name,
                          <<"coins">> => P#r_player.coins,
                          <<"vp">> => P#r_player.vp,
                          <<"cargo_count">> => length(P#r_player.cargo),
                          <<"submitted">> => P#r_player.submitted =/= false,
                           <<"connected">> => maps:get(P#r_player.id, ConnMap, true),
                           <<"is_bot">> => P#r_player.is_bot,
                           <<"difficulty">> => diff_json(P#r_player.difficulty),
                           <<"auto_pilot">> => P#r_player.auto_pilot}
                        || P <- G#r_game.players]}.

diff_json(undefined) -> null;
diff_json(D) -> D.

%% Tutorial players are keyed by the websocket connection pid, which is not
%% JSON-encodable; room player ids are already integers/binaries.
id_json(Id) when is_pid(Id) -> list_to_binary(pid_to_list(Id));
id_json(Id) -> Id.

private_state(G, Pid) ->
    case find_player(G, Pid) of
        false ->
            #{<<"hand">> => [], <<"cargo">> => [], <<"hidden_contracts">> => []};
        P ->
            #{<<"hand">> => [card_json(C) || C <- P#r_player.hand],
              <<"cargo">> => P#r_player.cargo,
              <<"hidden_contracts">> => [contract_json(C) || C <- P#r_player.hidden]}
    end.

card_json(C) ->
    #{<<"uid">> => C#r_card.uid,
      <<"name">> => C#r_card.name,
      <<"action">> => C#r_card.action,
      <<"cargo">> => C#r_card.cargo,
      <<"tide">> => C#r_card.tide}.

contract_json(C) ->
    #{<<"id">> => C#r_contract.id,
      <<"name">> => C#r_contract.name,
      <<"requires">> => C#r_contract.requires,
      <<"port">> => C#r_contract.port,
      <<"reward_vp">> => C#r_contract.reward_vp,
      <<"reward_coins">> => C#r_contract.reward_coins,
      <<"hidden">> => C#r_contract.hidden}.
