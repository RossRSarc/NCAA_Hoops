#############################  Read CSVs #######################################
library(dplyr) 
library(readr)
library(lubridate)
library(purrr)
library(furrr)
plan(multiprocess)
options(future.fork.enable = T)

x <- read_csv(paste("3.0_Files/Results/2020-21/NCAA_Hoops_Results",
                     month(Sys.Date()), day(Sys.Date()), "2020.csv", sep = "_"))
train <- read_csv("3.0_Files/Results/2017-18/training.csv")
confs <- read_csv("3.0_Files/Info/conferences.csv")
deadlines <- read_csv("3.0_Files/Info/deadlines.csv") %>%
  mutate(deadline = as.Date(deadline, "%m/%d/%y") %m+% years(1))
priors <- read_csv("3.0_Files/Info/prior.csv") %>% 
  arrange(team)
source("3.0_Files/powerrankings.R")
source("3.0_Files/Ivy_Sims.R")
source("3.0_Files/rpi.R")
source("3.0_Files/record_evaluator.R")
source("3.0_Files/bracketology.R")
source("3.0_Files/helpers.R")
source("3.0_Files/tourney_sim.R")
source("3.0_Files/ncaa_sims.R")
########################  Data Cleaning ########################################
x <- 
  x %>%
  rename(team_score = teamscore, opp_score = oppscore) %>%
  mutate(date = as.Date(paste(year, month, day, sep = "-")),
         score_diff = team_score - opp_score,
         total_score = team_score + opp_score,
         season_id = "2020-21", game_id = NA, opp_game_id = NA, 
         team_conf = NA, opp_conf = NA, conf_game = NA) %>%
  select(date, team, opponent, location, team_score, opp_score,
         score_diff, total_score, game_id, opp_game_id, team_conf, opp_conf,
         year, month, day, season_id, D1, OT, postponed, canceled) %>% 
  filter(D1 == 2)

teams <- sort(unique(confs$team))

### Game IDs
x <- 
  x %>% 
  group_by(team) %>% 
  mutate('game_id' = 1:n()) %>% 
  ungroup() 

### Opp Game IDs
x <- 
  inner_join(x, select(x, date, team, opponent, game_id), 
             by = c("team" = "opponent",
                    "opponent" = "team", 
                    "date" = "date")) %>%
  filter(!duplicated(paste(team, game_id.x))) %>%
  mutate(opp_game_id = game_id.y) %>%
  rename(game_id = game_id.x) %>%
  select(-game_id.y)

### Confs
x <- 
  mutate(x, team_conf = sapply(x$team, get_conf),
            opp_conf = sapply(x$opponent, get_conf),
            conf_game = team_conf == opp_conf)

### Reg Season
x <- 
  inner_join(x, deadlines, by = c("team_conf" = "conf")) %>%
  mutate(reg_season = date < deadline) %>%
  select(-deadline)

### Eliminate Teams from Auto Bid contention
confs <- eliminate(filter(x, score_diff < 0, !reg_season) %>% pull(team), confs)

################################# Set Weights ##################################
x$weights <- 0
for(i in 1:nrow(x)) {
  w_team <- 1 - (max(c(0, x$game_id[x$team == x$team[i] & !is.na(x$score_diff)])) - x$game_id[i])/
    max(c(0, x$game_id[x$team == x$team[i] & !is.na(x$score_diff)]))
  w_opponent <- 1 - (max(c(0, x$game_id[x$team == x$opponent[i] & !is.na(x$score_diff)])) - x$opp_game_id[i])/
    max(c(1, x$game_id[x$team == x$opponent[i] & !is.na(x$score_diff)]))
  rr <- mean(c(w_team, w_opponent))
  x$weights[i] <- 1/(1 + (0.5^(5 * rr)) * exp(-rr))
}   

############################### Create Models ##################################
### Current Season
pad <- tibble('team' = teams,
              'opponent' = teams, 
              'location' = sample(c('H', 'V', 'N'), length(teams), replace = T),
              'weights' = 0.000001,
              'score_diff' = 0,
              'team_score' = 0,
              'opp_score' = 0)

lm.hoops <- lm(score_diff ~ team + opponent + location, weights = weights, data = bind_rows(pad, x)) 
lm.off <- lm(team_score ~ team + opponent + location, weights = weights, data = bind_rows(pad, x)) 
lm.def <- lm(opp_score ~ team + opponent + location, weights = weights, data = bind_rows(pad, x)) 

### Update With Pre-Season Priors
priors <- mutate(priors, 
                 rel_yusag_coeff = yusag_coeff - yusag_coeff[1],
                 rel_off_coeff = off_coeff - off_coeff[1],
                 rel_def_coeff = def_coeff - def_coeff[1]) %>%
  arrange(team)

w <- sapply(teams, prior_weight)

lm.hoops$coefficients[is.na(lm.hoops$coefficients)] <- 0
lm.off$coefficients[is.na(lm.off$coefficients)] <- 0
lm.def$coefficients[is.na(lm.def$coefficients)] <- 0

lm.hoops$coefficients[2:357] <- 
  lm.hoops$coefficients[2:357] * w[-1] + priors$rel_yusag_coeff[-1] * (1-w[-1])
lm.hoops$coefficients[358:713] <- 
  lm.hoops$coefficients[358:713] * w[-1] - priors$rel_yusag_coeff[-1] * (1-w[-1])
lm.off$coefficients[2:357] <- 
  lm.off$coefficients[2:357] * w[-1] + priors$rel_off_coeff[-1] * (1-w[-1])
lm.off$coefficients[358:713] <- 
  lm.off$coefficients[358:713] * w[-1] - priors$rel_off_coeff[-1] * (1-w[-1])
lm.def$coefficients[2:357] <- 
  lm.def$coefficients[2:357] * w[-1] - priors$rel_def_coeff[-1] * (1-w[-1])
lm.def$coefficients[358:713] <- 
  lm.def$coefficients[358:713] * w[-1] + priors$rel_def_coeff[-1] * (1-w[-1])

lm.hoops$coefficients[c(1, 714:715)] <- 
  w[1] * lm.hoops$coefficients[c(1, 714:715)] + 
  (1-w[1]) * c(3.34957772, -3.34957772, -6.69915544)
lm.off$coefficients[c(1, 714:715)] <- 
  w[1] * lm.off$coefficients[c(1, 714:715)] + 
  (1-w[1]) * c(68.19705698, -2.93450334,  -3.34957772)
lm.def$coefficients[c(1, 714:715)] <- 
  w[1] * lm.def$coefficients[c(1, 714:715)] + 
  (1-w[1]) * c(64.84747926, 0.41507438,  3.34957772)

################################ Power Rankings ################################
power_rankings <- pr_compute(by_conf = F)
history <- read.csv("3.0_Files/History/history.csv", as.is = T)
x <- 
  mutate(x, pr_date = sapply(x$date, max_date, hist_dates = unique(history$date))) %>%
  inner_join(select(history, team, yusag_coeff, rank, date, off_coeff, def_coeff), 
             by = c("team" = "team","pr_date" = "date")) %>%
  inner_join(select(history, team, yusag_coeff, rank, date, off_coeff, def_coeff), 
             by = c("opponent" = "team","pr_date" = "date")) %>% 
  rename(rank = rank.x, opp_rank = rank.y, 
         yusag_coeff = yusag_coeff.x, opp_yusag_coeff = yusag_coeff.y,
         off_coeff = off_coeff.x, opp_off_coeff = off_coeff.y,
         def_coeff = def_coeff.x, opp_def_coeff = def_coeff.y) %>%
  select(-pr_date)

############################### Predictions ####################################
x <- 
  mutate(x, "hca" = case_when(location == "H" ~ lm.hoops$coefficients[1],
                              location == "V" ~ lm.hoops$coefficients[714],
                              location == "N" ~ 0),
         "hca_off" = case_when(location == "H" ~ abs(lm.off$coefficients[714]),
                               location == "V" ~ lm.off$coefficients[715] - lm.off$coefficients[714],
                               location == "N" ~ 0),
         "hca_def" = case_when(location == "H" ~ -lm.def$coefficients[714],
                               location == "V" ~ lm.def$coefficients[715] - lm.def$coefficients[714],
                               location == "N" ~ 0)) %>%
  mutate("pred_score_diff" = round(yusag_coeff - opp_yusag_coeff + hca, 1),
         "pred_team_score" = round(70 + off_coeff - opp_def_coeff + hca_off, 1),
         "pred_opp_score" = round(70 -def_coeff + opp_off_coeff + hca_def, 1),
         "pred_total_score" = pred_team_score + pred_opp_score) %>%
  select(-hca, -hca_off, -hca_def)

######################## Point Spread to Win Percentage Model #################
x$wins[x$score_diff > 0] <- 1
x$wins[x$score_diff < 0] <- 0
glm.pointspread <- glm(wins ~ pred_score_diff, 
                       data = bind_rows(select(train, wins, pred_score_diff),
                                        select(x, wins, pred_score_diff)), 
                       family=binomial) 
saveRDS(glm.pointspread, file = "glm_pointspread.rds")
x$wins[is.na(x$wins)] <- 
  round(predict(glm.pointspread, newdata = x[is.na(x$wins),], type = "response"), 3)
by_conf <- pr_compute(by_conf = T)
write_csv(x, "3.0_Files/Predictions/predictions.csv")
########################### Bracketology #######################################
resumes <- get_resumes(new = T)
bracket <- make_bracket(tourney = T)
bracket_math <- make_bracket(tourney = F)

# ############################# Conference Sims (No Tie-Breaks) ##################
for(conf in unique(confs$conference)) {
  print(conf)
  sims <- conf_fast_sim(conf, 10000)
  write_csv(sims, paste0("3.0_Files/Predictions/conf_sims/", conf, ".csv"))
}
############################ System Evaluation #################################
min_date <- as.Date("2020-11-25")
max_date <- Sys.Date()
y <- filter(x, date >= min_date, date <= max_date)
cat(paste("System Evaluation:", min_date, "Through", max_date),
    "\n-------------------------------------------------------------\n",
    "Predictive Accuracy: ",
    round(100 * mean(sign(y$pred_score_diff) == sign(y$score_diff), na.rm = T), 1), "%\n", 
    "Mean Absolute Error in Predicted Score Differential: ",
    round(mean(abs(y$pred_score_diff - y$score_diff), na.rm = T), 2), "\n",
    "Games w/in 2 Points of Observed Score Differential: ",
    round(100 * mean(abs(y$pred_score_diff - y$score_diff) <= 2, na.rm = T), 2), "%\n",
    "Games w/in 5 Points of Observed Score Differential: ",
    round(100 * mean(abs(y$pred_score_diff - y$score_diff) <= 5, na.rm = T), 2), "%\n",
    "Predicted Totals Score <= Total Score: ",
    round(100 * mean(y$pred_total_score <= y$total_score, na.rm = T), 1), "%\n",
    "Predicted Totals Score > Total Score: ",
    round(100 * mean(y$pred_total_score > y$total_score, na.rm = T), 1), "%\n",
    "Mean Absolute Error in Total Score Predictions: ",
    round(mean(abs(y$pred_total_score - y$total_score), na.rm = T),  2), "\n",
    "Games w/in 2 Points of Observed Total Score: ",
    round(100 * mean(abs(y$pred_total_score - y$total_score) <= 2, na.rm = T), 2), "%\n",
    "Games w/in 5 Points of Observed Total Score: ",
    round(100 * mean(abs(y$pred_total_score - y$total_score) <= 5, na.rm = T), 2), "%\n",
    sep = "")
nrow(filter(x, round(pred_team_score) == team_score))
filter(x, round(pred_team_score) == team_score, round(pred_opp_score) == opp_score)


devtools::install_github("lbenz730/ncaahoopR")
rsconnect::deployApp(forceUpdate = T)


