make_bracket <- function(tourney) {
  bracket <- data.frame("team" = teams,
                        "conf" = rep(NA, 357),
                        "yusag_coeff" = rep(NA, 357),
                        "sor" = rep(NA, 357),
                        "wab" = rep(NA, 357),
                        "qual_bonus" = rep(NA, 357),
                        "yusag_rank" = rep(NA, 357),
                        "sor_rank" = rep(NA, 357),
                        "resume_rank" = rep(NA, 357),
                        "wab_rank" = rep(NA, 357),
                        "mid_major" = rep(NA, 357),
                        "loss_bonus" = rep(NA, 357),
                        stringsAsFactors = F)
  
  ### Get Advanced Metric Ranks
  resumes <- 
    arrange(resumes, desc(sor)) %>%
    mutate(sor_rank = 1:357) %>%
    arrange(desc(wab)) %>%
    mutate(wab_rank = 1:357) %>%
    arrange(desc(qual_bonus)) %>%
    mutate(resume_rank = 1:357)
  
  
  for(i in 1:length(teams)) {
    bracket$yusag_coeff[i] <- power_rankings$yusag_coeff[power_rankings$team == teams[i]]
    bracket$conf[i] <- get_conf(teams[i])
    bracket$sor[i] <- resumes$sor[resumes$team == teams[i]]
    bracket$wab[i] <- resumes$wab[resumes$team == teams[i]]
    bracket$qual_bonus[i] <- resumes$qual_bonus[resumes$team == teams[i]]
    bracket$yusag_rank[i] <- power_rankings$rank[power_rankings$team == teams[i]]
    bracket$sor_rank[i] <- resumes$sor_rank[resumes$team == teams[i]]
    bracket$wab_rank[i] <- resumes$wab_rank[resumes$team == teams[i]]  
    bracket$resume_rank[i] <- resumes$resume_rank[resumes$team == teams[i]]
    bracket$mid_major[i] <- confs$mid_major[confs$team == teams[i]]
    bracket$wins[i] <- resumes$wins[resumes$team == teams[i]]
    bracket$losses[i] <- resumes$losses[resumes$team == teams[i]]
    bracket$loss_bonus[i] <- resumes$losses[resumes$team == teams[i]] <= 4
    bracket$conf[i] %in% c("Big 10", "Big 12", "Big East", "ACC", "Pac 12", "Big 12")
  }
  
  bracket$blend <-  0.125 * bracket$wab_rank + 
    0.15 * bracket$sor_rank + 0.25 * bracket$yusag_rank + 0.475 * bracket$resume_rank
  
  bracket$avg <-  0.25 * bracket$wab_rank + 
    0.25 * bracket$sor_rank + 0.25 * bracket$yusag_rank + 0.25 * bracket$resume_rank 
  
  bracket <- arrange(bracket, desc(yusag_coeff))
  
  autobid_calc <- function(conf) {
    tmp <- bracket$team[bracket$conf == conf]
    for(i in 1:length(tmp)) {
      if(confs$eligible[confs$team == tmp[i]] & !confs$eliminated[confs$team == tmp[i]]) {
        return(tmp[i])
      }
    }
  }
  
  bracket_math <- 
    read.csv("3.0_Files/Bracketology/historical/bracket_math_2016.csv", as.is = T) %>%
    bind_rows(read.csv("3.0_Files/Bracketology/historical/bracket_math_2017.csv", as.is = T)) %>%
    bind_rows(read.csv("3.0_Files/Bracketology/historical/bracket_math_2018.csv", as.is = T)) 
  
  bracket_math$avg <- 
    0.25 * bracket_math$wab_rank +  0.25 * bracket_math$sor_rank + 
    0.25 * bracket_math$yusag_rank + 0.25 * bracket_math$resume_rank 
  
  bracket_math$bid <- bracket_math$seed <= 10
  glm.madness <- suppressWarnings(glm(bid ~ blend +
                                        + (mid_major & yusag_rank > 50) 
                                      + (mid_major & yusag_rank > 25) 
                                      + (loss_bonus & yusag_rank <= 10), 
                                      data = bracket_math, family = "binomial"))
  lm.seed <- lm(seed ~ blend 
                  + (mid_major & yusag_rank > 50) 
                + (mid_major & yusag_rank > 25) 
                + (loss_bonus & yusag_rank <= 10) 
                + (losses <= 3), 
                data = bracket_math)
  bracket$odds <- 
    round(predict(glm.madness, newdata = bracket, type = "response"), 4) * 100
  bracket$odds <- ifelse(bracket$odds > 99.9, 99.99, bracket$odds)
  bracket$odds[which(bracket$wins - bracket$losses <= 2)] <- 
    bracket$odds[which(bracket$wins - bracket$losses <= 2)]/4
  bracket$seed <- 
    predict(lm.seed, newdata = bracket, type = "response")
  
  # correct <- c("Texas Tech", "Saint Mary's (CA)", "Duke", "Baylor")
  # correct2 <- c("Purdue", "UCLA")
  # correct3 <- c("Gonzaga")
  # correct4 <- c("San Diego St.", "Maryland")
  # bracket$odds[bracket$team %in% correct] <- bracket$odds[bracket$team %in% correct] + 0.5 * (100 - bracket$odds[bracket$team %in% correct])
  # bracket$odds[bracket$team %in% correct2] <- bracket$odds[bracket$team %in% correct2] + 0.25 * (100 - bracket$odds[bracket$team %in% correct2])
  # bracket$avg[bracket$team %in% correct3] <- 0.8 * bracket$avg[bracket$team %in% correct3]
  # bracket$avg[bracket$team %in% correct4] <- 3 * bracket$avg[bracket$team %in% correct4]
  bracket <- arrange(bracket, desc(round(odds, 1)), avg)
  
  if(tourney == T) {
    ### Get Autobids
    autobids <- vector()
    con <- setdiff(unique(confs$conference), 'Ivy')
    for(j in 1:length(con)){

      autobids[j] <- autobid_calc(con[j])
    }
    bracket$autobid <- is.element(bracket$team, autobids)
    tmp <- bracket[!bracket$autobid, ]
    j <- 1
    z <- 1
    
    ### Get At-Large bids
    atlarge <- vector()
    while(j <= 37) {
      for(k in z:length(teams)){
        z <- z + 1
        if(confs$eligible[confs$team == tmp$team[k]]) {
          atlarge[j] <- as.character(tmp$team)[k]
          j <- j + 1
          break
        }
      }
    }
    
    ### Write Bracket    
    bracket$atlarge <- is.element(bracket$team, atlarge)
    bracket <- rbind(bracket[bracket$autobid,], bracket[bracket$atlarge,])
    bracket <- arrange(bracket, desc(round(odds, 1)), avg)
    bracket <- select(bracket, -mid_major, -wins, -losses, -loss_bonus, -seed)
    bracket$seed_overall <- 1:68
    bracket$seed_line <- c(rep(1,4), rep(2,4), rep(3,4), rep(4,4), rep(5,4),
                           rep(6,4), rep(7,4), rep(8,4), rep(9,4), rep(10,4),
                           rep(11,6), rep(12,4), rep(13,4), rep(14,4), rep(15,4),
                           rep(16,6))
    f4 <- bracket$seed_overall[!bracket$autobid][33:36]
    bracket$first4 <- is.element(bracket$seed_overall, f4) | is.element(bracket$seed_overall, c(65:68))
    ### Not 3 1 seeds from 1 conference
    if(sum(bracket$conf[4] == bracket$conf[1:3]) == 2) {
      bracket[4:5,] <- rbind(bracket[5,], bracket[4,])
    }
    write.csv(bracket, "3.0_Files/Bracketology/bracket.csv", row.names = F)
    
    ### First teams out
    j <- 37
    z <- 37
    bubble <- vector()
    while(j <= 52) {
      for(k in z:length(teams)){
        z <- z + 1
        if(confs$eligible[confs$team == tmp$team[k]]) {
          bubble[j - 36] <- as.character(tmp$team)[k]
          j <- j + 1
          break
        }
      }
    }
    bubble <- tmp[is.element(tmp$team, bubble),]
    write.csv(bubble, "3.0_Files/Bracketology/bubble.csv", row.names = F)
    
    ### Bid Summary by Conference
    bids <- group_by(bracket, conf) %>%
      summarise("n_bid" = n()) %>%
      arrange(desc(n_bid))
    write.csv(bids, "3.0_Files/Bracketology/bids.csv", row.names = F)
    return(bracket)
  }
  else{
    bracket <- select(bracket, -mid_major, -wins, -losses, -loss_bonus, -seed)
    write.csv(bracket, "3.0_Files/Bracketology/bracket_math.csv", row.names = F)
    return(bracket)
  }
}