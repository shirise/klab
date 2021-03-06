$sg_games = $mongo.collection('sg_games')
$sg = $sampling_game = $mongo.collection('sampling_game')
$sg_moves = $mongo.collection('sg_moves')

SG_EXCHANGE_RATE = 0.2

def get_num_players 
  $prod ? 3 : 1
end

def get_box_val(round_num,opt_num,phase)
  $sg_values ||= SimpleSpreadsheet::Workbook.read("sg_values.xlsx") 
  table = $sg_values
  
  col_offset_from_excel_start = 3
  ev_offset_from_opt_start= 5
  ev_col = col_offset_from_excel_start + (ev_offset_from_opt_start * opt_num)

  plow_offset_from_ev   = -1
  low_offset_from_ev    = -2
  phigh_offset_from_ev  = -3
  high_offset_from_ev   = -4
  
  row_offset_from_excel_start = 3
  row = round_num + row_offset_from_excel_start

  if phase == 'sample' 
    phigh  = table.cell(row,ev_col+phigh_offset_from_ev)
    vhigh  = table.cell(row,ev_col+high_offset_from_ev)
    vlow   = table.cell(row,ev_col+low_offset_from_ev)
    x      = rand
    if x < phigh
      res = vhigh
    else 
      res = vlow
    end
  else  # phase == 'choose'      
    res = table.cell(row,ev_col)
  end

  ev1 = table.cell(row,col_offset_from_excel_start+(ev_offset_from_opt_start*1)).to_f.round(2)
  ev2 = table.cell(row,col_offset_from_excel_start+(ev_offset_from_opt_start*2)).to_f.round(2)
  ev3 = table.cell(row,col_offset_from_excel_start+(ev_offset_from_opt_start*3)).to_f.round(2)
  ev4 = table.cell(row,col_offset_from_excel_start+(ev_offset_from_opt_start*4)).to_f.round(2)

  environment = table.cell(row,2) 
  ev_type = table.cell(row,3) 
  res = res.to_f.round(2)
  return res, ev_type, environment, ev1, ev2, ev3, ev4, row
rescue 
  -1 
end

def get_btns_order
  [1,2,3,4].shuffle
end

def get_random_roles(round_num = 0)
  all = [1,2,3,4]
  lca = all.sample(2)
  lcb = all - lca
  [all,lca,lcb].rotate(round_num)
end

get '/sg_admin' do
  erb :'/sg/sg_admin', default_layout 
end

get '/sg/clear' do  
  $sg_games.delete_many
  {msg: 'ok'}
end

get '/sg' do
  erb :'/sg/home', default_layout  
end

get '/sg/intro' do
  #$sg_games.delete_many
  sesh.clear  
  erb :'sg/intro', default_layout
end

get '/sg/instructions' do
  [:user_id, :age, :gender, :game_id].each {|field| sesh[field] = pr[field] }
  erb :'sg/instructions', default_layout
end

get '/sg/game' do
  #[:user_id, :age, :gender, :game_id].each {|field| sesh[field] ||= pr[field] }
  sesh[:is_practice] = true
  game_id = sesh[:game_id] || pr[:game_id]
  
  game = $sg_games.update_id(game_id, {}, {upsert: true})
  user_ids = (game['user_ids'] || []).push(sesh[:user_id]).uniq.compact.sort
  rounds_order = (0..89).to_a.shuffle
  if !game['round'] 
    $sg_games.update_id(game_id, {cur_turn: user_ids[0], round: 0, turn: 1, chosen_buttons: [], users_chosen: [], roles: get_random_roles(0), btns_order: get_btns_order, rounds_order: rounds_order, practice_over: false})
  end
  
  $sg_games.update_id(game_id, {user_ids: user_ids})

  erb :'/sg/sg_game', default_layout
end

#game has user_ids, turn_id, round_num.
get '/sg/state' do
  game = $sg_games.get(sesh[:game_id])
  game['game_id'] = game['_id']
  game['round'] ||= 0 
  game['game_over'] = game['round'] > get_setting(:sampling_game_nrounds).to_i - 1

  data = game
  data['my_chosen_btn'] = sesh[:my_chosen_btn]

  data
end

get '/sg/skip_round/:game_id' do
  game = $sg_games.get(pr[:game_id])
  round          = game[:round].to_i
  next_round     = round+1
  flash.message = "Opened blocked round #{(round+1).to_s}. New round is #{next_round+1}"
  turn           = 1
  chosen_buttons = []
  users_chosen   = []
  btns_order     = get_btns_order
  user_ids       = game['user_ids']
  cur_turn       = user_ids[0]
  roles          = get_random_roles(round) 
  users_sampled  = []
  awaiting_oks   = 0

  $sg_games.update_id(pr[:game_id], {turn: turn, round: next_round, chosen_buttons: chosen_buttons,cur_turn: cur_turn, users_chosen: users_chosen, users_sampled: users_sampled, roles: roles, btns_order: btns_order, awaiting_oks: awaiting_oks})  

   $sg_moves.update_many({game_id: game['_id'], round: round},{'$set' => {mode: 99}}) rescue nil
  redirect '/sg/results/'+pr[:game_id]
end

get '/sg/move' do
  
  game  = $sg_games.get(pr[:game_id])
  turn  = game[:turn]
  round = game[:round]
  #params[:phase] = 'sample'
  phase = pr[:phase] == 'choose' ? 'choose' : 'sample' 

  chosen_buttons = game['chosen_buttons']
  user_ids = game['user_ids']
  round_time = 'missing-round-time'
  
  users_sampled = game['users_sampled'].to_a 
  users_chosen = game['users_chosen']
  if pr[:phase] == 'choose'
    chosen_buttons.push(pr[:box]) 
    sesh[:my_chosen_btn] = pr[:box]
    users_chosen += [sesh[:user_id]]    
  else 
    users_sampled += [sesh[:user_id]]
    sesh[:my_chosen_btn] = nil
  end

  chosen_buttons  = chosen_buttons.uniq
  users_chosen    = users_chosen.uniq
  users_sampled   = users_sampled.uniq
  remaining_users = user_ids - users_chosen

  opt_num = game[:btns_order][pr[:box].to_i-1]
  row_num = game[:rounds_order][round]
  
  val, ev_type, e, ev1, ev2, ev3, ev4, excel_row_num = get_box_val(row_num,opt_num,phase)

  evs = [ev1, ev2, ev3, ev4]
  viewed_evs = []
  viewed_evs[0] = evs[game[:btns_order][0]-1]
  viewed_evs[1] = evs[game[:btns_order][1]-1]
  viewed_evs[2] = evs[game[:btns_order][2]-1]
  viewed_evs[3] = evs[game[:btns_order][3]-1]  

  available_choices = game['roles'][game['user_ids'].index(sesh[:user_id])]
  option_choice = pr[:box].to_i 
  mode = pr[:phase] == 'sample' ? 1 : 2

  fopt = (game['round'].to_i >= get_setting(:sampling_game_nrounds).to_i - 1) ? 1 : 0
  
  sesh[:searches] = sesh[:searches] || 0 
  sesh[:searches]+=1 if pr[:phase] == 'sample' 
  
  if !game[:practice_over]
    round_to_record = -3 + round
  else 
    round_to_record = round
  end
  
  record_sg_move(game, sesh[:user_id], sesh[:age], sesh[:gender], turn, round_to_record, sesh[:searches], round_time, e, ev_type, ev1, ev2, ev3, ev4, available_choices, option_choice, val, mode, fopt, viewed_evs, excel_row_num) 

  practice_over = false
  awaiting_oks  = 0
  if remaining_users.size == 0    
    round          = round+1       
    turn           = 1
    sesh[:searches]= 0
    if round == 3 && !game[:practice_over]
      round = 0 
      practice_over = true
    end 
    chosen_buttons = []
    users_chosen   = []
    btns_order     = get_btns_order
    cur_turn       = user_ids[0]
    roles          = get_random_roles(round) 
    users_sampled = [] 
    awaiting_oks  = get_num_players 
  else 
    if user_ids.size == users_chosen.uniq.size + users_sampled.uniq.size      
      users_chosen.each { |user_id| 
        #record_sg_move(game, user_id, 'get_last', 'get_last', turn, round, 'get_last', 'n/a', e, ev_type, ev1, ev2, ev3, ev4, [], 'n/a', 'get_last', 0, 'n/a') #if game[:practice_over]
      }      
      turn = turn+1 
    end
    btns_order = game[:btns_order]
    cur_turn = remaining_users[turn % remaining_users.size]  
    roles    = game['roles']
  end

  users_sampled = [] if (users_sampled + users_chosen).size == user_ids.size 

  game = $sg_games.update_id(pr[:game_id], {turn: turn, round: round, chosen_buttons: chosen_buttons,cur_turn: cur_turn, users_chosen: users_chosen.uniq, users_sampled: users_sampled.uniq, roles: roles, btns_order: btns_order, awaiting_oks: awaiting_oks})  

  if (practice_over) 
    $sg_games.update_id(pr[:game_id],practice_over: practice_over)  
  end

  

  {val: val.to_s, game: game}
end

def record_sg_move(game, user_id, age, gender, turn, round, searches, round_time, e, ev_type, ev1, ev2, ev3, ev4, available_choices, option_choice, outcome, mode, fopt, viewed_evs = [], excel_row_num)

  ev_l  = viewed_evs[0]
  ev_lm = viewed_evs[1]
  ev_rm = viewed_evs[2]
  ev_r  = viewed_evs[3]
  rd = {}

  rd['_id'] = nice_id

  if searches == 'get_last'
    last_move = $sg_moves.get(game_id: game['_id'], user_id: user_id, round: round)
    age      = last_move[:age]
    gender   = last_move[:gender]
    option_choice = last_move[:option_choice]
    searches = last_move[:searches]
  end

  rd = {
    game_id: game['_id'],
    user_id: user_id,
    age: age,
    gender: gender,
    turn: turn,
    round: round,
    searches: searches,
    round_time: round_time,
    e: e,
    ev_type: ev_type,
    ev1: ev1,
    ev2: ev2,
    ev3: ev3,
    ev4: ev4,
    n_choice: available_choices.size == 4 ? 1 : 0,
    o1: available_choices.include?(1),
    o2: available_choices.include?(2),
    o3: available_choices.include?(3),
    o4: available_choices.include?(4),
    oc: option_choice,
    ou: outcome,
    mode: mode,
    fopt: fopt,
    ev_l: ev_l,
    ev_lm: ev_lm,
    ev_rm: ev_rm,
    ev_r: ev_r,
    excel_row_num: excel_row_num
  }
  
  #prevent recording double choices
  if $sg_moves.count(game_id: game['_id'], round: round, mode: 2, user_id: user_id) == 0
    $sg_moves.add(rd)
  end
end

get '/sg/results/:id' do
  erb :'sg/results', default_layout
end

get '/sg/game_over' do
  game    = $sg_games.get(sesh[:game_id])
  user_id = sesh[:user_id]  
  
  high_values_rand_payoff = $sg_moves.get_many(game_id: game['_id'], user_id: user_id, mode: 2).select {|move| move['ev_type'] == 'HighValues'}.sample['ou'] rescue 1
  low_values_rand_payoff  = $sg_moves.get_many(game_id: game['_id'], user_id: user_id, mode: 2).select {|move| move['ev_type'] == 'LowValues'}.sample['ou'] rescue 1
  total_payoff = (high_values_rand_payoff + low_values_rand_payoff) * SG_EXCHANGE_RATE
  total_payoff = total_payoff.round(2)
  $sg_games.update_id(game['_id'], {low_values_rand_payoff: low_values_rand_payoff, high_values_rand_payoff: high_values_rand_payoff, total_payoff: total_payoff})  
  game['low_values_rand_payoff']  = low_values_rand_payoff
  game['high_values_rand_payoff'] = high_values_rand_payoff
  
  erb :'sg/game_over', locals: {game: game, total_payoff: total_payoff}, layout: :layout
end

get '/sg/delete/:game_id' do
  $sg_moves.delete_many({game_id: pr[:game_id]})
  redirect '/sg_admin'
end

post '/sg/clicked_ok' do
  game = $sg_games.get(sesh[:game_id])
  awaiting_oks = game[:awaiting_oks].to_i
  if awaiting_oks >= 1
    $sg_games.update_one({_id: sesh[:game_id]},{'$inc': {awaiting_oks: -1}})
  else 
    $sg_games.update_one({_id: sesh[:game_id]},{'$inc': {awaiting_oks: 0}})
  end
  {msg: 'ok'}
end