-record(r_card, {uid, name, action, cargo, tide}).
-record(r_contract, {id, name, requires = [], port = <<"any">>, reward_vp = 0, reward_coins = 0, hidden = false}).
-record(r_player, {id, name, seat = 0, port, hand = [], cargo = [], coins = 0, vp = 0, hidden = [], done = [], submitted = false, is_bot = false, difficulty = undefined, auto_pilot = false}).
-record(r_port, {id, name, adj = [], ships = [], posts = []}).
-record(r_game, {cfg = #{}, players = [], deck = [], discard = [], market = #{},
                 tide = <<"rising">>, round = 1, turn = 1, start_seat = 0,
                 phase = <<"select">>, ports = [], public = [], contract_deck = [],
                  event_piles = #{}, rng = 1, over = false, scores = undefined}).
